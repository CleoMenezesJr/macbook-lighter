// SPDX-License-Identifier: GPL-3.0-or-later
/**
 * macbook-lighter GNOME Shell Extension
 *
 * Turns the icon of the Quick Settings brightness slider into a flat toggle
 * (like the volume mute button) that switches between manual and automatic
 * brightness.
 *
 * In automatic mode the macbook-lighter daemon sends the ambient brightness
 * level over D-Bus and the extension moves GNOME's own brightness scale towards
 * it, so the slider and the backlight travel together in real time. Moving the
 * slider while automatic is on sets a bias on top of the ambient level instead
 * of turning automatic off.
 */

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BUS_NAME = 'org.gnome.Shell.Extensions.MacbookLighter';
const OBJECT_PATH = '/org/gnome/Shell/Extensions/MacbookLighter';

const IFACE_XML = `
  <node>
    <interface name="org.gnome.Shell.Extensions.MacbookLighter">
      <method name="SetAmbientBrightness">
        <arg type="d" direction="in" name="level"/>
        <arg type="u" direction="in" name="duration_ms"/>
      </method>
      <method name="SetBrightness">
        <arg type="d" direction="in" name="level"/>
      </method>
    </interface>
  </node>`;

const MANUAL_ICON = 'display-brightness-symbolic';
const AUTO_ICON = 'icons/display-brightness-auto-symbolic.svg';

// Never drive the panel fully dark in automatic mode
const MIN_LEVEL = 0.01;
// Levels closer than this are considered equal (the scale is 0.0-1.0)
const EPSILON = 0.005;
const FRAME_MS = 16;
const SAVE_BIAS_DELAY_S = 1;

export default class MacbookLighterExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._manager = Main.brightnessManager;
        this._item = Main.panel.statusArea.quickSettings._brightness?.quickSettingsItems[0];
        this._ambient = null;
        this._duration = 1500;
        this._bias = this._settings.get_double('brightness-bias');

        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE_XML, {
            SetAmbientBrightness: (level, durationMs) => this._setAmbient(level, durationMs),
            SetBrightness: level => this._setBrightness(level),
        });
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._ownerId = Gio.DBus.session.own_name(BUS_NAME,
            Gio.BusNameOwnerFlags.NONE, null, null);

        this._manager.connectObject('changed', () => this._watchScale(), this);
        this._watchScale();

        if (!this._item) {
            console.warn('[macbook-lighter] Quick Settings brightness slider not found');
            this._auto = this._settings.get_boolean('auto-brightness');
            return;
        }

        this._autoIcon = Gio.FileIcon.new(this.dir.resolve_relative_path(AUTO_ICON));
        this._manualIcon = Gio.ThemedIcon.new(MANUAL_ICON);

        this._item.set({iconReactive: true, iconLabel: 'Automatic Brightness'});
        this._item.connectObject('icon-clicked', () => {
            this._settings.set_boolean('auto-brightness', !this._auto);
        }, this);
        this._settings.connectObject('changed::auto-brightness',
            () => this._syncAuto(true), this);

        this._syncAuto(false);
    }

    disable() {
        this._stopAnimation();
        this._saveBias();

        this._dbus.unexport();
        Gio.DBus.session.unown_name(this._ownerId);

        if (this._item) {
            this._item.disconnectObject(this);
            this._item.set({iconReactive: false, iconLabel: '', gicon: this._manualIcon});
        }
        this._settings.disconnectObject(this);
        this._manager.disconnectObject(this);
        this._scale?.disconnectObject(this);

        this._dbus = null;
        this._item = null;
        this._scale = null;
        this._manager = null;
        this._settings = null;
    }

    _syncAuto(toggled) {
        this._auto = this._settings.get_boolean('auto-brightness');
        this._item.gicon = this._auto ? this._autoIcon : this._manualIcon;

        if (!this._auto) {
            this._stopAnimation();
            return;
        }

        // Switching automatic on starts from the plain ambient level
        if (toggled) {
            this._bias = 0;
            this._saveBias();
        }
        this._followAmbient();
    }

    // The global scale is recreated when all backlit monitors go away and back
    _watchScale() {
        const scale = this._manager.globalScale;
        if (scale === this._scale)
            return;

        this._stopAnimation();
        this._scale?.disconnectObject(this);
        this._scale = scale;
        this._scale?.connectObject('notify::value', () => this._onScaleChanged(), this);
    }

    _onScaleChanged() {
        if (this._updatingScale || !this._auto || this._ambient === null)
            return;

        // The user moved the slider (or pressed a brightness key): keep the
        // offset from the ambient level. It is absolute and bounded, so
        // repeated adjustments never pile up.
        this._stopAnimation();
        this._bias = Math.clamp(this._scale.value - this._ambient, -1.0, 1.0);
        this._queueSaveBias();
    }

    _setAmbient(level, durationMs) {
        this._ambient = Math.clamp(level, 0.0, 1.0);
        this._duration = durationMs;
        if (this._auto)
            this._followAmbient();
    }

    _setBrightness(level) {
        // Same path as dragging the slider, so automatic mode learns the bias
        if (this._scale)
            this._scale.value = Math.clamp(level, 0.0, 1.0);
    }

    _followAmbient() {
        if (this._ambient === null || !this._scale)
            return;

        const target = Math.clamp(this._ambient + this._bias, MIN_LEVEL, 1.0);
        const from = this._scale.value;

        if (this._animation && Math.abs(this._animation.target - target) < EPSILON)
            return;
        this._stopAnimation();

        // Already there, e.g. asked to go darker while at the minimum
        if (Math.abs(target - from) < EPSILON)
            return;

        const start = GLib.get_monotonic_time();
        const duration = Math.max(this._duration, 1) * 1000;

        this._animation = {target};
        this._animation.id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, FRAME_MS, () => {
            const t = Math.min((GLib.get_monotonic_time() - start) / duration, 1.0);
            const eased = t < 0.5 ? 2 * t * t : 1 - ((-2 * t + 2) ** 2) / 2;
            this._setScaleSilently(from + (target - from) * eased);

            if (t < 1.0)
                return GLib.SOURCE_CONTINUE;
            this._animation = null;
            return GLib.SOURCE_REMOVE;
        });
    }

    _stopAnimation() {
        if (this._animation)
            GLib.source_remove(this._animation.id);
        this._animation = null;
    }

    // Moves GNOME's brightness scale (slider and backlight together) without
    // popping up the brightness OSD on every animation frame.
    _setScaleSilently(value) {
        this._updatingScale = true;
        this._manager._showOSD = () => {};
        try {
            this._scale.value = value;
        } finally {
            delete this._manager._showOSD;
            this._updatingScale = false;
        }
    }

    _queueSaveBias() {
        if (this._saveBiasId)
            return;
        this._saveBiasId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, SAVE_BIAS_DELAY_S, () => {
            this._saveBiasId = 0;
            this._saveBias();
            return GLib.SOURCE_REMOVE;
        });
    }

    _saveBias() {
        if (this._saveBiasId) {
            GLib.source_remove(this._saveBiasId);
            this._saveBiasId = 0;
        }
        this._settings.set_double('brightness-bias', this._bias);
    }
}
