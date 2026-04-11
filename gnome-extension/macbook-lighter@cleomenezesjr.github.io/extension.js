// SPDX-License-Identifier: GPL-3.0-or-later
// Syncs the GNOME brightness slider with macbook-lighter sysfs writes.
//
// Why this extension exists:
//   Mutter silently updates its internal state when it detects external sysfs
//   writes via udev (to avoid feedback loops), so notify::brightness is never
//   emitted and the Quick Settings slider never moves.
//
//   The fix: macbook-lighter scripts call SetScreenBrightness after writing to
//   hardware.  The extension then calls syncWithBacklight() on each
//   MonitorBrightnessScale, which re-reads the brightness from Mutter
//   (already up-to-date via udev) and updates the slider — with no hardware
//   write and no OSD.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

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
            this._syncScreenSlider();
        else if (method === 'SetKeyboardBrightness')
            this._setKeyboardBrightness(value);

        invocation.return_value(null);
    }

    // ── Screen ───────────────────────────────────────────────────────────────

    // Called after the script writes brightness to hardware (via logind/sysfs).
    // Mutter has already silently updated its internal backlight state via udev.
    // syncWithBacklight() reads Mutter's current value and updates the Quick
    // Settings slider — without writing to hardware or showing an OSD.
    _syncScreenSlider() {
        if (!Main.brightnessManager)
            return;

        // In 45-46 it was .scales (array), in 47+ it is often ._scales (Set).
        // Using a more resilient way to iterate over the collection.
        const scales = Main.brightnessManager.scales ?? Main.brightnessManager._scales ?? [];
        for (const scale of scales)
            scale.syncWithBacklight?.();

        // Fallback: search directly in Quick Settings if the manager structure changed.
        try {
            const qs = Main.panel.statusArea.quickSettings;
            if (qs && qs._brightness?._slider)
                qs._brightness._slider.syncWithBacklight?.();
        } catch (e) {
            // Path not found, ignore
        }
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
