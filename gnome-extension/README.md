# macbook-lighter GNOME Extension

Adds automatic brightness to the GNOME Quick Settings brightness slider, driven by the
`macbook-lighter` ambient light daemon.

- The slider icon becomes a flat toggle, like the volume mute button: the regular brightness icon
  means manual, the sun with an "A" means automatic.
- In automatic mode the slider moves in real time together with the screen brightness, because the
  extension drives GNOME's own brightness scale instead of writing sysfs behind Mutter's back.
- Moving the slider (or pressing the brightness keys) while automatic is on keeps automatic on and
  stores the difference to the ambient level as a bias. Turning automatic on again resets it.

## D-Bus interface

`org.gnome.Shell.Extensions.MacbookLighter` at `/org/gnome/Shell/Extensions/MacbookLighter`:

| Method | Arguments | Used by |
|--------|-----------|---------|
| `SetAmbientBrightness` | `d level` (0.0-1.0), `u duration_ms` | `macbook-lighter-ambient`, every poll |
| `SetBrightness` | `d level` (0.0-1.0) | `macbook-lighter-screen` |

## Requirements

- GNOME Shell 50 or 51
- `macbook-lighter` daemon running (`systemctl --user status macbook-lighter`)

## Install

`make install` (from the repository root) copies the extension and compiles its settings schema.
For a per-user install:

```bash
cp -r macbook-lighter@cleomenezesjr.github.io ~/.local/share/gnome-shell/extensions/
glib-compile-schemas ~/.local/share/gnome-shell/extensions/macbook-lighter@cleomenezesjr.github.io/schemas
gnome-extensions enable macbook-lighter@cleomenezesjr.github.io
```

## Uninstall

```bash
gnome-extensions disable macbook-lighter@cleomenezesjr.github.io
rm -rf ~/.local/share/gnome-shell/extensions/macbook-lighter@cleomenezesjr.github.io
```
