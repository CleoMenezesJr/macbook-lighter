// SPDX-License-Identifier: GPL-3.0-or-later
/**
 * macbook-lighter GNOME Shell Extension
 * 
 * Provides a D-Bus interface for the macbook-lighter daemon to synchronize
 * hardware backlight levels with the GNOME Shell Quick Settings brightness slider.
 * 
 * Implements a "Silent Sync" mechanism that updates the UI visuals without
 * triggering the system On-Screen Display (OSD), ensuring background adjustments
 * are non-intrusive for the user.
 */

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
        try {
            // Register D-Bus object to listen for brightness change signals from the daemon
            const ifaceInfo = Gio.DBusNodeInfo.new_for_xml(IFACE_XML).interfaces[0];
            this._regId = Gio.DBus.session.register_object(
                '/org/gnome/Shell/Extensions/MacbookLighter',
                ifaceInfo, this._handleMethodCall.bind(this), null, null
            );
            this._ownerId = Gio.DBus.session.own_name(
                'org.gnome.Shell.Extensions.MacbookLighter',
                Gio.BusNameOwnerFlags.NONE, null, null
            );
        } catch (e) {
            logError(e, '[macbook-lighter] Registration failed');
        }
    }

    disable() {
        if (this._ownerId) Gio.DBus.session.unown_name(this._ownerId);
        if (this._regId) Gio.DBus.session.unregister_object(this._regId);
    }

    _handleMethodCall(_conn, _sender, _path, _iface, method, params, invocation) {
        const [value] = params.deepUnpack();
        if (method === 'SetScreenBrightness') this._syncScreenSlider(value);
        else if (method === 'SetKeyboardBrightness') this._setKeyboardBrightness(value);
        invocation.return_value(null);
    }

    /**
     * Helper to read hardware state from sysfs
     */
    _readSysfs(path) {
        try {
            const file = Gio.File.new_for_path(path);
            const [success, contents] = file.load_contents(null);
            if (success) return parseInt(new TextDecoder().decode(contents).trim());
        } catch (e) {}
        return null;
    }

    /**
     * Orchestrates the synchronization of the screen brightness slider
     */
    _syncScreenSlider(passedValue) {
        // Prefer direct sysfs read for maximum accuracy during hardware-triggered sync
        const brightness = this._readSysfs('/sys/class/backlight/intel_backlight/brightness') ?? passedValue;
        const max = this._readSysfs('/sys/class/backlight/intel_backlight/max_brightness') ?? 100;
        const percent = brightness / max;

        // Brief delay to allow hardware stabilization before UI update
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 100, () => {
             this._applySilentSync(percent);
             return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * Multi-layered "Silent Sync" implementation.
     * 1. Temporarily hijacks the OSD window manager to suppress pop-ups.
     * 2. Updates the slider's Adjustment object to ensure visual movement.
     * 3. Disconnects OSD suppression after a small safety margin.
     */
    _applySilentSync(percent) {
        try {
            const osd = Main.osdWindowManager;
            let originalShow = null;
            
            // Suppress OSD by temporarily overriding the show method
            if (osd) {
                const methods = ['show', '_show', 'showNow'];
                for (let m of methods) {
                    if (typeof osd[m] === 'function') {
                        originalShow = { name: m, func: osd[m] };
                        osd[m] = () => {}; // Mute
                        break;
                    }
                }
            }

            // Target the Quick Settings brightness slider
            const qs = Main.panel.statusArea.quickSettings;
            if (qs && qs.menu?._grid) {
                qs.menu._grid.get_children().forEach(child => {
                    const name = child.constructor.name;
                    if (name === 'BrightnessItem') {
                        const slider = child.slider || child._slider;
                        if (slider) {
                            // Update adjustment directly to force visual synchronization
                            const adj = slider.adjustment || slider._adjustment;
                            if (adj) adj.value = percent;
                            else slider.value = percent;
                        }
                    }
                });
            }

            // Restore OSD functionality
            if (originalShow) {
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, () => {
                    osd[originalShow.name] = originalShow.func;
                    return GLib.SOURCE_REMOVE;
                });
            }

        } catch (e) {
             console.error(`[macbook-lighter] Sync Error: ${e.message}`);
        }
    }

    /**
     * Forwards keyboard brightness updates to GNOME Settings Daemon
     */
    _setKeyboardBrightness(percent) {
        Gio.DBus.session.call(
            'org.gnome.SettingsDaemon.Power', '/org/gnome/SettingsDaemon/Power',
            'org.freedesktop.DBus.Properties', 'Set',
            new GLib.Variant('(ssv)', ['org.gnome.SettingsDaemon.Power.Keyboard', 'Brightness', new GLib.Variant('i', percent)]),
            null, Gio.DBusCallFlags.NONE, -1, null, () => {}
        );
    }
}
