// SPDX-License-Identifier: GPL-3.0-or-later
// Syncs the GNOME brightness slider with macbook-lighter sysfs writes.
//
// Why this extension exists:
//   Mutter silently updates its internal state when it detects external sysfs
//   writes via udev (to avoid feedback loops), so notify::brightness is never
//   emitted and the Quick Settings slider never moves.  The only reliable fix
//   is to run code inside gnome-shell's process that can either poke the
//   Meta.Backlight GObject directly (GNOME 48+) or call SetBacklight via D-Bus
//   and then emit BrightnessChanged so the slider re-reads the new value.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
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
        // Primary path (GNOME 48+): set brightness directly on the Meta.Backlight
        // GObject.  This triggers notify::brightness inside gnome-shell's process
        // so the Quick Settings slider updates immediately.
        // Meta.Backlight GI API (get_backlights) is not available in this build;
        // fall through directly to the D-Bus fallback path.

        // Fallback path: call org.gnome.Mutter.DisplayConfig.SetBacklight (which
        // updates the Backlight D-Bus property) then emit BrightnessChanged so
        // the brightness item calls _sync() and re-reads the new value.
        this._fetchBacklightInfo((serial, connector) => {
            this._callSetBacklight(serial, connector, rawValue, () => {
                // Emit BrightnessChanged on Shell's own connection so that the
                // brightness item's signal subscription (sender='org.gnome.Shell')
                // matches and _sync() is called.
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
                    //   u  = serial
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
