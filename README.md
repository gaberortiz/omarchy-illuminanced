# omarchy-illuminanced

Ambient-light auto-brightness for Omarchy, as a bar widget plus a user daemon.

## Layout

| Path | Installed to |
| --- | --- |
| `plugin/illuminanced/manifest.json` | `~/.config/omarchy/plugins/illuminanced/` |
| `plugin/illuminanced/Panel.qml` | `~/.config/omarchy/plugins/illuminanced/` |
| `user-autobright.py` | `~/.local/bin/user-autobright.py` |
| `user-autobright.conf` | `~/.config/user-autobright/user-autobright.conf` |

## Install

```sh
./install.sh
```

Then restart the shell so it picks up the QML:

```sh
omarchy-restart-shell
```

`QS_DISABLE_FILE_WATCHER=1` is set by `omarchy-launch-shell`, so editing
`Panel.qml` does **not** hot-reload. A restart is required.

## IPC

```sh
Q="qs ipc -p /usr/share/omarchy/shell call"
$Q user.illuminanced state            # JSON snapshot
$Q user.illuminanced brightness 70    # set percent
$Q user.illuminanced auto true        # resume auto
$Q user.illuminanced auto false       # pause auto
```

## How it works

`user-autobright.py` is the only thing that touches the backlight. It polls
`in_illuminance_raw` every `interval` seconds, maps it to a target percent, and
writes the backlight once the target has been stable for `debounce` consecutive
reads. The daemon publishes its state to `$XDG_RUNTIME_DIR/user-autobright-status.json`
and the widget watches that file, so the panel spawns no processes of its own.

Pausing is a flag file at `/tmp/user-autobright-manual`. The widget creates or
removes it; the daemon also creates it when it notices a brightness change it
did not make, so the toggle always reflects what is actually happening.

### Calibration

`[thresholds] dark` and `light` are raw sensor counts, and the mapping is
monotonic: `dark` or below maps to `[brightness] min`, `light` or above maps to
`max`. Watch the raw value and set the thresholds to match your room:

```sh
watch -n1 cat /sys/bus/iio/devices/iio:device0/in_illuminance_raw
```

## Troubleshooting

The daemon holds brightness steady when the sensor stops reporting. A raw value
stuck near zero means no data, not a dark room, so treating it as darkness
would black out the screen in a lit room. Check:

```sh
journalctl --user -u user-autobright.service -f
cat "${XDG_RUNTIME_DIR}/user-autobright-status.json"
```

If the widget is missing from the bar, the panel needs an `implicitWidth` and
`implicitHeight` — the bar sizes each slot from the widget's implicit size and
a zero-size widget is laid out but never painted.
