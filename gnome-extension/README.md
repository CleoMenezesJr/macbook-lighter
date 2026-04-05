# macbook-lighter GNOME Extension

Syncs the GNOME Quick Settings brightness sliders when `macbook-lighter` scripts change brightness via sysfs.

## Why this exists

Mutter performs a "silent update" when it detects external sysfs writes — it updates its internal state without emitting `notify::brightness`, so the Quick Settings slider never moves. This extension runs inside gnome-shell's process and corrects that.

## Requirements

- GNOME Shell 45–50
- `macbook-lighter` scripts installed (they call this extension via D-Bus)

## Install

```bash
cp -r macbook-lighter@cleomenezesjr.github.io ~/.local/share/gnome-shell/extensions/
gnome-extensions enable macbook-lighter@cleomenezesjr.github.io
```

No shell restart required — the extension is loaded immediately.

## Uninstall

```bash
gnome-extensions disable macbook-lighter@cleomenezesjr.github.io
rm -rf ~/.local/share/gnome-shell/extensions/macbook-lighter@cleomenezesjr.github.io
```
