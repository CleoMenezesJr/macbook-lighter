// SPDX-License-Identifier: GPL-3.0-or-later
// Syncs the GNOME brightness slider with macbook-lighter sysfs writes.
//
// Why this extension exists:
//   Mutter silently updates its internal state when it detects external sysfs
//   writes via udev (to avoid feedback loops), so notify::brightness is never
//   emitted and the Quick Settings slider never moves.  The fix is to update
//   Main.brightnessManager.globalScale.value from inside gnome-shell's process,
//   which triggers notify::value and moves the slider.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const IFACE_XML = `
<node>
  <interface name="org.gnome.Shell.Extensions.MacbookLighter">
    <method name="SetScreenBrightness">
      <arg type="u" direction="in" name="raw_value"/>
    </method>
    <method name="SetKeyboardBrightness">
      <arg type="u" direction="in" name="percent"/>
    </method>
  </interface>
</node>`;

export default class MacbookLighterExtension extends Extension {
    enable() {
        const ifaceInfo = Gio.DBusNodeInfo.new_for_xml(IFACE_XML).interfaces[0];

        this._regId = Gio.DBus.session.register_object(
            '/org/gnome/Shell/Extensions/MacbookLighter',
            ifaceInfo,
            this._handleMethodCall.bind(this),
            null,
            null,
        );

        this._ownerId = Gio.DBus.session.own_name(
            'org.gnome.Shell.Extensions.MacbookLighter',
            Gio.BusNameOwnerFlags.NONE,
            null,
            null,
        );
    }

    disable() {
        if (this._ownerId) {
            Gio.DBus.session.unown_name(this._ownerId);
            this._ownerId = null;
        }
        if (this._regId) {
            Gio.DBus.session.unregister_object(this._regId);
            this._regId = null;
        }
    }

    _handleMethodCall(_conn, _sender, _path, _iface, method, params, invocation) {
        const [value] = params.deepUnpack();

        if (method === 'SetScreenBrightness')
            this._setScreenBrightness(value);
        else if (method === 'SetKeyboardBrightness')
            this._setKeyboardBrightness(value);

        invocation.return_value(null);
    }

    // ── Screen ───────────────────────────────────────────────────────────────

    _setScreenBrightness(rawValue) {
        // GNOME 50+: brightnessManager owns the globalScale that the Quick
        // Settings slider binds to.  Setting its value (0.0–1.0) moves the
        // slider and writes back to the hardware via setBacklight().
        if (Main.brightnessManager?.globalScale) {
            this._setViaManager(rawValue);
            return;
        }

        // Fallback for older GNOME builds (45–49): call SetBacklight then
        // emit BrightnessChanged so the brightness item refreshes.
        this._fetchBacklightInfo((serial, connector) => {
            this._callSetBacklight(serial, connector, rawValue, () => {
                Gio.DBus.session.emit_signal(
                    null,
                    '/org/gnome/Shell/Brightness',
                    'org.gnome.Shell.Brightness',
                    'BrightnessChanged',
                    null,
                );
            });
        });
    }

    // Normalize rawValue to 0.0–1.0 using the monitor's backlight range, then
    // set globalScale.value so the Quick Settings slider updates immediately.
    _setViaManager(rawValue) {
        try {
            const monitorManager = global.backend.get_monitor_manager();
            for (const lm of monitorManager.get_logical_monitors()) {
                for (const m of lm.get_monitors()) {
                    const bl = m.get_backlight();
                    if (!bl)
                        continue;
                    // is_active() may not exist on all builds; treat missing as active
                    if (m.is_active && !m.is_active())
                        continue;

                    const {brightnessMin: min, brightnessMax: max} = bl;
                    const normalized = (rawValue - min) / (max - min);
                    Main.brightnessManager.globalScale.value =
                        Math.max(0.0, Math.min(1.0, normalized));
                    return;
                }
            }
            console.warn('[macbook-lighter] No active backlight found via monitor manager');
        } catch (e) {
            console.error(`[macbook-lighter] _setViaManager error: ${e.message}`);
        }
    }

    _fetchBacklightInfo(callback) {
        Gio.DBus.session.call(
            'org.gnome.Mutter.DisplayConfig',
            '/org/gnome/Mutter/DisplayConfig',
            'org.freedesktop.DBus.Properties',
            'Get',
            new GLib.Variant('(ss)', ['org.gnome.Mutter.DisplayConfig', 'Backlight']),
            new GLib.VariantType('(v)'),
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (conn, res) => {
                try {
                    const result = conn.call_finish(res);
                    // Backlight property type is (uaa{sv}):
                    //   u      = serial
                    //   aa{sv} = array of monitor dicts {connector, active, min, max, value}
                    const innerVariant = result.get_child_value(0).get_variant();
                    const [serial, monitors] = innerVariant.recursiveUnpack();
                    const connector = monitors[0].connector;
                    callback(serial, connector);
                } catch (e) {
                    console.error(`[macbook-lighter] Failed to read Backlight property: ${e.message}`);
                }
            },
        );
    }

    _callSetBacklight(serial, connector, rawValue, onSuccess) {
        Gio.DBus.session.call(
            'org.gnome.Mutter.DisplayConfig',
            '/org/gnome/Mutter/DisplayConfig',
            'org.gnome.Mutter.DisplayConfig',
            'SetBacklight',
            new GLib.Variant('(usi)', [serial, connector, rawValue]),
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (conn, res) => {
                try {
                    conn.call_finish(res);
                    onSuccess();
                } catch (e) {
                    console.error(`[macbook-lighter] SetBacklight failed: ${e.message}`);
                }
            },
        );
    }

    // ── Keyboard ─────────────────────────────────────────────────────────────

    _setKeyboardBrightness(percent) {
        // gsd-power exposes Brightness as a readwrite property (0-100).
        // Setting it updates both the hardware and the Quick Settings slider.
        Gio.DBus.session.call(
            'org.gnome.SettingsDaemon.Power',
            '/org/gnome/SettingsDaemon/Power',
            'org.freedesktop.DBus.Properties',
            'Set',
            new GLib.Variant('(ssv)', [
                'org.gnome.SettingsDaemon.Power.Keyboard',
                'Brightness',
                new GLib.Variant('i', percent),
            ]),
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (conn, res) => {
                try {
                    conn.call_finish(res);
                } catch (e) {
                    console.error(`[macbook-lighter] SetKeyboardBrightness failed: ${e.message}`);
                }
            },
        );
    }
}
