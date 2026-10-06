# macbook-lighter

Automatically adjusts MacBook keyboard and screen backlight based on ambient light.

Tested on:
- MacBook Air A1466
- MacBook Pro Late 2013 (11,1)
- MacBook Air 2012
- MacBook Air 2017

## How it works

`macbook-lighter-ambient` runs as a systemd **user daemon** and reads the ambient light sensor to
adjust screen and keyboard brightness automatically.

Everything works on absolute percentages. The sensor reading is normalized between fixed endpoints
(darkness = 0 %, `ML_BRIGHT_ENOUGH` = 100 %) and the screen and keyboard follow it between their
configured limits, so brightness never goes past 0 % or 100 % and nothing is written when a
backlight is already where it should be.

On GNOME the screen level goes to the bundled [extension](gnome-extension/), which moves GNOME's own
brightness slider (and the backlight with it) in real time. Its icon becomes a toggle between manual
and automatic brightness, like the volume mute button. Moving the slider while automatic is on sets
an offset on top of the ambient level. Without GNOME Shell the daemon writes sysfs directly.

The keyboard backlight is set through UPower, falling back to sysfs, and turns off after
`ML_KBD_TIMEOUT` seconds of inactivity.

## Dependencies

- `systemd` — user service management
- `gdbus` (glib2) — talks to the GNOME extension, Mutter's idle monitor and UPower
- `awk` — floating point math for the sensor smoothing
- GNOME Shell 50+ for the Quick Settings integration (optional)

## Installation

### Standard Installation

The easiest way to install `macbook-lighter` is using the provided `Makefile`:

```bash
git clone https://github.com/CleoMenezesJr/macbook-lighter.git
cd macbook-lighter
sudo make install
```

Then enable and start the daemon as a **user service**:

```bash
systemctl --user enable --now macbook-lighter
```

### Immutable / Bootc Systems Integration

For systems like Fedora Silverblue or `bootc` based images, you can bake `macbook-lighter` directly into your image. In your `Containerfile`/`Dockerfile`, add:

```dockerfile
# Build-time installation
RUN git clone --depth 1 https://github.com/CleoMenezesJr/macbook-lighter.git /tmp/macbook-lighter && \
    cd /tmp/macbook-lighter && \
    make install DESTDIR=/ && \
    cd / && rm -rf /tmp/macbook-lighter

# Enable the service globally for all users
RUN systemctl --global enable macbook-lighter.service
```

## Setup

### Hardware Access (Udev Rules)

To allow a user service to modify brightness without root, you must install the following udev rules and add your user to the `video` group.

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

Add your user to the group:
```bash
sudo usermod -aG video $USER
```

## Configuration

The daemon reads `/etc/macbook-lighter.conf` on startup. Edit it to tune behavior (all levels are percentages):

```bash
# Raw sensor reading considered full daylight (ambient 100 %)
ML_BRIGHT_ENOUGH=8

# Screen brightness in complete darkness / in full light
ML_SCREEN_MIN=2
ML_SCREEN_MAX=100

# Ambient change (percentage points) needed before the screen follows
ML_HYSTERESIS=5

# Keyboard brightness in complete darkness; it fades to 0 in full light
ML_KBD_BRIGHT=50
```

On GNOME, automatic screen brightness is toggled from Quick Settings; the state is also available as
`gsettings set org.gnome.shell.extensions.macbook-lighter auto-brightness false`.

## Usage

```bash
# Increase keyboard backlight by 20 %
macbook-lighter-kbd --inc 20

# Set screen backlight to 40 %
macbook-lighter-screen --set 40

# Check daemon logs
journalctl --user -u macbook-lighter -f
```
