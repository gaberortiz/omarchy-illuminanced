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

`[thresholds] dark` and `light` are raw sensor counts. The mapping is monotonic:
`dark` or below gives `[brightness] min`, `light` or above gives `max`, and
`gamma` bends the curve in between.

This machine's ALS was measured as:

| Condition | Raw |
| --- | --- |
| dark room | 1–2 |
| normal room light | 15 |
| flashlight | 47–48 |

That is a narrow, strongly non-linear range, so the shipped values are
`dark = 3`, `light = 48`, `gamma = 0.5` — with a straight line, ordinary indoor
light at raw 15 lands near 29% and the top half of the brightness range is
unreachable. With the gamma curve, normal room light gives 54% and a flashlight
reaches 100%.

Re-measure for your own room before trusting these:

```sh
watch -n1 cat /sys/bus/iio/devices/iio:device0/in_illuminance_raw
```

`gamma` below 1 lifts the mid-range, above 1 pushes it down. If normal room
light feels too dim, lower gamma toward 0.4; if it is too bright, raise it
toward 0.7.

### Curve editor

The bar panel has a collapsible **RESPONSE CURVE** section with sliders for
`dark`, `light` and `gamma`, and a live plot of raw counts against target
percent with the current reading marked. Dragging a slider updates the plot
immediately; releasing it writes the config.

Edits go through the daemon's own `--set` mode, which validates the whole file
before writing and refuses anything that would leave an unusable curve, so a bad
drag cannot wedge the daemon. The daemon notices the changed file on its next
poll and applies it with no restart:

```sh
user-autobright.py --set gamma=0.5
user-autobright.py --set dark=3 light=48 gamma=0.5
user-autobright.py --set dark=999   # error: dark (999) must be less than light (48)
```

A rejected edit leaves both the file and the running daemon untouched.

### Slew rate

`slew` is the largest brightness change the daemon will make per poll, in
percent. The default of 3 means a jump from 5% to 100% is walked up over about
32 seconds instead of being written in one step, which is most of the difference
between auto-brightness feeling smooth and feeling like the screen suddenly went
dark or blinding.

```sh
user-autobright.py --set slew=1    # slow and gentle
user-autobright.py --set slew=10   # quick
```

Lower it if you notice brightness creeping, raise it if you would rather it
react fast (for example a room light switched on). The SLEW slider in the panel
sets the same value.

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
