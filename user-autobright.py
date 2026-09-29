#!/usr/bin/env python3
"""
user-autobright — User-level automatic screen brightness control.
Reads ambient light sensor and adjusts screen brightness via brightnessctl.
"""

import configparser
import glob
import json
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

DEFAULTS = {
    "dark": 10,
    "light": 100,
    "min_brightness": 5,
    "max_brightness": 100,
    "interval": 2,
    "debounce": 3,
    "sensor": "",
    "backlight_device": "amdgpu_bl1",
}

CONFIG_PATH = os.path.expanduser("~/.config/user-autobright/user-autobright.conf")
SENSOR_GLOB = "/sys/bus/iio/devices/iio:device*/in_illuminance_raw"

running = True


def handle_signal(signum, frame):
    global running
    running = False


def load_config():
    config = configparser.ConfigParser()

    if os.path.isfile(CONFIG_PATH):
        config.read(CONFIG_PATH)
        logging.info("Loaded config from %s", CONFIG_PATH)
    else:
        logging.info("No config file found at %s, using defaults", CONFIG_PATH)

    dark = config.getint("thresholds", "dark", fallback=DEFAULTS["dark"])
    light = config.getint("thresholds", "light", fallback=DEFAULTS["light"])
    min_bri = config.getint("brightness", "min", fallback=DEFAULTS["min_brightness"])
    max_bri = config.getint("brightness", "max", fallback=DEFAULTS["max_brightness"])
    interval = config.getint("polling", "interval", fallback=DEFAULTS["interval"])
    debounce = config.getint("polling", "debounce", fallback=DEFAULTS["debounce"])
    sensor = config.get("sensor", "device", fallback=DEFAULTS["sensor"]).strip()
    backlight_device = config.get("backlight", "device", fallback=DEFAULTS["backlight_device"]).strip()

    if dark >= light:
        logging.error("Invalid config: dark threshold (%d) must be less than light threshold (%d)", dark, light)
        sys.exit(1)

    if not 0 <= min_bri <= 100 or not 0 <= max_bri <= 100:
        logging.error("Invalid config: brightness must be between 0 and 100")
        sys.exit(1)

    if min_bri >= max_bri:
        logging.error("Invalid config: min brightness (%d) must be less than max brightness (%d)", min_bri, max_bri)
        sys.exit(1)

    if interval < 1:
        logging.error("Invalid config: poll interval (%d) must be at least 1 second", interval)
        sys.exit(1)

    if debounce < 1:
        logging.error("Invalid config: debounce (%d) must be at least 1", debounce)
        sys.exit(1)

    return dark, light, min_bri, max_bri, interval, debounce, sensor, backlight_device


def find_sensor(device_override):
    if device_override:
        if os.path.isfile(device_override):
            logging.info("Using configured sensor: %s", device_override)
            return device_override
        else:
            logging.error("Configured sensor path does not exist: %s", device_override)
            sys.exit(1)

    matches = sorted(glob.glob(SENSOR_GLOB))
    if not matches:
        logging.error("No ambient light sensor found at %s.", SENSOR_GLOB)
        sys.exit(1)

    sensor = matches[0]
    logging.info("Auto-detected sensor: %s", sensor)
    if len(matches) > 1:
        logging.info("Multiple sensors found (%d total). Using first.", len(matches))
    return sensor


def set_brightness(device, percent):
    try:
        subprocess.run(["brightnessctl", "-d", device, "set", f"{percent}%"], check=True, capture_output=True, timeout=5)
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        logging.error("Failed to set brightness: %s", e)
        return False


def get_current_brightness(device):
    try:
        result = subprocess.run(["brightnessctl", "-d", device, "get"], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            return int(result.stdout.strip())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
        pass
    try:
        return int(Path(f"/sys/class/backlight/{device}/brightness").read_text().strip())
    except (OSError, ValueError):
        return None


def get_max_brightness(device):
    try:
        return int(Path(f"/sys/class/backlight/{device}/max_brightness").read_text().strip())
    except (OSError, ValueError):
        return None


def read_sensor(sensor_path):
    try:
        return int(Path(sensor_path).read_text().strip())
    except (OSError, ValueError) as e:
        logging.warning("Failed to read sensor: %s", e)
        return None


def status_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return Path(runtime) / "user-autobright-status.json"


def write_status(brightness_percent, sensor_raw, state, service_running):
    # The bar widget reads this instead of spawning its own sensor/service
    # probes, so the two never disagree and the panel costs no processes.
    payload = {
        "brightness": brightness_percent,
        "sensor": sensor_raw,
        "auto": state == "auto",
        "serviceRunning": service_running,
        "updated": time.time(),
    }
    try:
        status_path().write_text(json.dumps(payload))
    except OSError as e:
        logging.debug("Could not write status file: %s", e)


def interpolate_brightness(raw, dark, light, min_bri, max_bri):
    if raw <= dark:
        return min_bri
    elif raw >= light:
        return max_bri
    else:
        ratio = (raw - dark) / (light - dark)
        return round(min_bri + ratio * (max_bri - min_bri))


def main():
    global running

    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    dark, light, min_bri, max_bri, interval, debounce, sensor_override, backlight_device = load_config()
    sensor_path = find_sensor(sensor_override)

    max_raw_brightness = get_max_brightness(backlight_device)
    if not max_raw_brightness:
        logging.error("Could not read max brightness for device %s", backlight_device)
        sys.exit(1)

    logging.info(
        "Starting: dark=%d, light=%d, brightness=%d%%-%d%%, poll=%ds, debounce=%d, device=%s",
        dark, light, min_bri, max_bri, interval, debounce, backlight_device,
    )

    state = "auto"
    counter = 0
    last_written = None
    zero_reads = 0
    sensor_dead = False
    sensor_seen_nonzero = False
    sensor_dead_reads = max(3, int(round(10 / max(interval, 1))))
    noise_floor = 2
    pending_target = None
    change_threshold = 3
    last_raw = 0

    def publish():
        actual = get_current_brightness(backlight_device)
        write_status(
            round(actual * 100 / max_raw_brightness) if actual is not None else 0,
            last_raw,
            state,
            True,
        )

    # Check for manual override file
    manual_override_file = Path("/tmp/user-autobright-manual")

    while running:
        # Check if manual override is active
        if manual_override_file.exists():
            if state != "manual":
                logging.info("Manual override detected, pausing auto-brightness")
                state = "manual"
            publish()
            time.sleep(interval)
            continue
        elif state == "manual":
            logging.info("Manual override cleared, resuming auto-brightness")
            state = "auto"
            counter = 0
            last_written = None
            pending_target = None

        raw = read_sensor(sensor_path)
        if raw is None:
            publish()
            time.sleep(interval)
            continue
        last_raw = raw

        # A sensor stuck near zero is not "pitch dark", it is not reporting.
        # Drive the panel to min_bri on that reading and the screen goes black
        # in a lit room, so hold the current level instead of applying it.
        # This sensor is exposed in 0.1 lux units, so a couple of counts is
        # noise around a broken reading rather than a real dark room.
        if raw <= noise_floor:
            zero_reads += 1
            if not sensor_seen_nonzero:
                if zero_reads == 1:
                    logging.info("Sensor near 0, holding brightness until it reports light")
                publish()
                time.sleep(interval)
                continue
            if zero_reads >= sensor_dead_reads:
                if not sensor_dead:
                    logging.warning("Sensor stuck near 0 for %d reads, holding brightness", zero_reads)
                    sensor_dead = True
                publish()
                time.sleep(interval)
                continue
        else:
            zero_reads = 0
            if not sensor_seen_nonzero:
                sensor_seen_nonzero = True
                logging.info("Sensor reporting light (raw=%d), auto-brightness active", raw)
            if sensor_dead:
                logging.info("Sensor recovered, resuming auto-brightness")
                sensor_dead = False
                counter = 0
                last_written = None
                pending_target = None

        target_percent = interpolate_brightness(raw, dark, light, min_bri, max_bri)

        if state == "auto":
            actual = get_current_brightness(backlight_device)
            actual_percent = round(actual * 100 / max_raw_brightness) if actual is not None else 0
            write_status(actual_percent, raw, state, True)
            last_raw = raw

            if actual is not None and last_written is not None:
                if abs(actual_percent - last_written) > 5:
                    logging.info("Manual brightness change detected (%d%% -> %d%%), pausing auto", last_written, actual_percent)
                    state = "manual"
                    try:
                        manual_override_file.touch()
                    except OSError:
                        pass
                    counter = 0
                    pending_target = None
                    continue

            # Debounce the target, not the sensor position. Gating the write
            # on raw <= dark or raw >= light meant a reading anywhere in the
            # middle of the range reset the counter and never moved the
            # backlight, so the panel only ever tracked the two endpoints.
            if last_written is not None and abs(target_percent - last_written) < change_threshold:
                pending_target = None
                counter = 0
            elif pending_target == target_percent:
                counter += 1
            else:
                pending_target = target_percent
                counter = 1

            if counter >= debounce:
                if target_percent != last_written:
                    set_brightness(backlight_device, target_percent)
                    last_written = target_percent
                    logging.info("Auto brightness %d%% (raw=%d)", target_percent, raw)
                pending_target = None
                counter = 0

        time.sleep(interval)

    logging.info("Shutting down")


if __name__ == "__main__":
    main()