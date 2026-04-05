# macbook-lighter

Automatically adjusts MacBook keyboard and screen backlight based on ambient light.

Tested on:
- MacBook Air A1466
- MacBook Pro Late 2013 (11,1)
- MacBook Air 2012

## How it works

`macbook-lighter-ambient` runs as a systemd daemon and reads the ambient light sensor to
adjust screen and keyboard brightness automatically. It reads and writes the following files:

- `/sys/devices/platform/applesmc.768/light` — ambient light sensor
- `/sys/class/backlight/intel_backlight/brightness`
- `/sys/class/backlight/intel_backlight/max_brightness`
- `/sys/class/leds/smc::kbd_backlight/brightness`
- `/sys/class/leds/smc::kbd_backlight/max_brightness`

After each brightness transition, the daemon notifies the desktop session via
`systemd-logind` so that the brightness slider stays in sync.

## Dependencies

- `bc` — arithmetic in brightness transitions
- `systemd` — service management and `busctl` for desktop session sync

## Installation

```bash
sudo install -Dm644 macbook-lighter.conf /etc/macbook-lighter.conf
sudo install -Dm644 macbook-lighter.service /usr/lib/systemd/system/macbook-lighter.service
sudo install -Dm755 src/macbook-lighter-ambient.sh /usr/bin/macbook-lighter-ambient
sudo install -Dm755 src/macbook-lighter-screen.sh /usr/bin/macbook-lighter-screen
sudo install -Dm755 src/macbook-lighter-kbd.sh /usr/bin/macbook-lighter-kbd
```

Then enable and start the daemon:

```bash
sudo systemctl enable --now macbook-lighter
```

## Setup

### Allow non-root users to set brightness

To use `macbook-lighter-kbd` and `macbook-lighter-screen` without root, add your user to
the `video` group and create the following udev rules.

`/etc/udev/rules.d/90-backlight.rules`:

```
SUBSYSTEM=="backlight", ACTION=="add", \
  RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", \
  RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
```

`/etc/udev/rules.d/91-leds.rules`:

```
SUBSYSTEM=="leds", ACTION=="add", \
  RUN+="/bin/chgrp video /sys/class/leds/%k/brightness", \
  RUN+="/bin/chmod g+w /sys/class/leds/%k/brightness"
```

Then add yourself to the group and reboot:

```bash
sudo usermod -aG video $USER
```

### Keyboard shortcuts (GNOME)

Open **Settings → Keyboard → Custom Shortcuts** and add entries such as:

| Name                    | Command                          |
|-------------------------|----------------------------------|
| Increase screen brightness | `macbook-lighter-screen --inc 50` |
| Decrease screen brightness | `macbook-lighter-screen --dec 50` |
| Increase keyboard brightness | `macbook-lighter-kbd --inc 50` |
| Decrease keyboard brightness | `macbook-lighter-kbd --dec 50` |

This requires the udev rules above so the commands run without root.

## Usage

```bash
# Increase keyboard backlight by 50
macbook-lighter-kbd --inc 50

# Decrease screen backlight by 50
macbook-lighter-screen --dec 50

# Set screen backlight to max
macbook-lighter-screen --max

# Start the auto-adjust daemon
sudo systemctl start macbook-lighter

# Run the daemon interactively (requires root)
sudo macbook-lighter-ambient
```

## Configuration

The daemon reads `/etc/macbook-lighter.conf` on startup. Edit it to tune behavior:

```bash
# Duration of each brightness transition (seconds)
ML_DURATION=1.5

# Time per animation frame (seconds)
ML_FRAME=0.017

# Polling interval (seconds)
ML_INTERVAL=5

# Ambient light level considered "bright enough" to turn off keyboard backlight
ML_BRIGHT_ENOUGH=40

# Minimum change in light required to trigger a screen update
ML_SCREEN_THRESHOLD=10

# Minimum screen brightness in complete darkness
ML_SCREEN_MIN_BRIGHT=15

# Keyboard brightness level when dark
ML_KBD_BRIGHT=128

# Dim factor when on battery (0.0–1.0)
ML_BATTERY_DIM=0.2

# Enable automatic keyboard backlight adjustment
ML_AUTO_KBD=true

# Enable automatic screen backlight adjustment
ML_AUTO_SCREEN=true

# Print debug output to stdout
ML_DEBUG=false
```
