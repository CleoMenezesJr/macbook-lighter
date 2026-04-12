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

By running as a user service, the daemon has native access to the desktop's D-Bus bus, allowing for 
silent synchronization with the GNOME Quick Settings slider without requiring root privileges or complex session discovery.

## Dependencies

- `bc` — arithmetic in brightness transitions
- `systemd` — user service management and `gdbus` for desktop session sync

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

The daemon reads `/etc/macbook-lighter.conf` on startup. Edit it to tune behavior:

```bash
# Duration of each brightness transition (seconds)
ML_DURATION=1.5

# Polling interval (seconds)
ML_INTERVAL=5

# Proportional dead-band percentage to prevent oscillation
ML_HYSTERESIS_PCT=15

# Polls to confirm before dimming (slow response)
ML_DIM_CONFIRMS=3

# Enable automatic keyboard adjustment
ML_AUTO_KBD=true
```

## Usage

```bash
# Increase keyboard backlight by 50
macbook-lighter-kbd --inc 50

# Increase screen backlight by 50
macbook-lighter-screen --inc 50

# Check daemon logs
journalctl --user -u macbook-lighter -f
```
