#!/usr/bin/env bash
#
# macbook-lighter-ambient: follows the ambient light sensor with the screen and
# keyboard backlights.
#
# Every level is an absolute percentage. The sensor reading is normalized
# between two fixed endpoints (darkness = 0 %, ML_BRIGHT_ENOUGH = 100 %), and
# the screen/keyboard targets are derived from that, so a target can never fall
# outside 0-100 % and a backlight that is already at an edge is left alone.
#
# On GNOME the screen level is handed to the macbook-lighter extension, which
# moves the Quick Settings slider (and through it the backlight) and owns the
# automatic/manual toggle. Without GNOME Shell the daemon writes sysfs itself.

screen_dir=/sys/class/backlight/intel_backlight
kbd_dir=/sys/class/leds/smc::kbd_backlight
light_file=/sys/devices/platform/applesmc.768/light
lid_file=/proc/acpi/button/lid/LID0/state
power_file=/sys/class/power_supply/ADP1/online

EXT_NAME=org.gnome.Shell.Extensions.MacbookLighter
EXT_PATH=/org/gnome/Shell/Extensions/MacbookLighter

#####################################################
# Settings
[ -f /etc/macbook-lighter.conf ] && source /etc/macbook-lighter.conf
ML_INTERVAL=${ML_INTERVAL:-5}
ML_DURATION=${ML_DURATION:-1.5}
ML_FRAME=${ML_FRAME:-0.017}
ML_SENSOR_SAMPLES=${ML_SENSOR_SAMPLES:-3}
ML_SENSOR_SAMPLE_DELAY=${ML_SENSOR_SAMPLE_DELAY:-0.3}
ML_EWMA_ALPHA=${ML_EWMA_ALPHA:-0.5}
ML_BRIGHT_ENOUGH=${ML_BRIGHT_ENOUGH:-8}
ML_SCREEN_MIN=${ML_SCREEN_MIN:-2}
ML_SCREEN_MAX=${ML_SCREEN_MAX:-100}
ML_BATTERY_DIM=${ML_BATTERY_DIM:-20}
ML_HYSTERESIS=${ML_HYSTERESIS:-5}
ML_BRIGHTEN_CONFIRMS=${ML_BRIGHTEN_CONFIRMS:-1}
ML_DIM_CONFIRMS=${ML_DIM_CONFIRMS:-3}
ML_KBD_BRIGHT=${ML_KBD_BRIGHT:-50}
ML_KBD_TIMEOUT=${ML_KBD_TIMEOUT:-30}
ML_AUTO_SCREEN=${ML_AUTO_SCREEN:-true}
ML_AUTO_KBD=${ML_AUTO_KBD:-true}
ML_DEBUG=${ML_DEBUG:-false}

#####################################################
# State
smoothed=""         # EWMA of the sensor, empty until the first poll
ambient=-1          # committed ambient level (0-100), -1 until the first poll
brighten_count=0
dim_count=0
screen_written=-1   # last level written to sysfs (non-GNOME fallback only)
kbd_level=-1        # last keyboard level applied

function log {
    if $ML_DEBUG; then echo "$*"; fi
}

function clamp {
    local value=$1 min=$2 max=$3
    (( value < min )) && value=$min
    (( value > max )) && value=$max
    echo "$value"
}

function read_sensor {
    # applesmc reports "(left,right)", e.g. "(41,0)"
    local left
    IFS='(,)' read -r _ left _ < "$light_file"
    echo "$left"
}

function sample_light {
    # Median of a few quick readings drops single spikes, then the EWMA
    # (kept as a float, so small sensor values still move it) smooths the rest.
    local samples=() median i
    for (( i = 0; i < ML_SENSOR_SAMPLES; i++ )); do
        samples+=("$(read_sensor)")
        (( i < ML_SENSOR_SAMPLES - 1 )) && sleep "$ML_SENSOR_SAMPLE_DELAY"
    done
    median=$(printf '%s\n' "${samples[@]}" | sort -n | sed -n "$(( ML_SENSOR_SAMPLES / 2 + 1 ))p")

    if [ -z "$smoothed" ]; then
        smoothed=$median
    else
        # Snap once within half a sensor step, so a steady reading is reached
        # exactly instead of only approached (and the 0/100 ends stay reachable)
        smoothed=$(awk -v a="$ML_EWMA_ALPHA" -v m="$median" -v p="$smoothed" 'BEGIN {
            s = a * m + (1 - a) * p
            if (s - m < 0.5 && m - s < 0.5) s = m
            printf "%.3f", s
        }')
    fi
}

function ambient_level {
    # Logarithmic, like brightness perception: 0 (dark) .. 100 (ML_BRIGHT_ENOUGH or more)
    awk -v l="$smoothed" -v top="$ML_BRIGHT_ENOUGH" 'BEGIN {
        if (l > top) l = top
        if (l < 0) l = 0
        printf "%d", 100 * log(1 + l) / log(1 + top) + 0.5
    }'
}

function commit_ambient {
    # Accept a new level only once it moved by ML_HYSTERESIS points for enough
    # consecutive polls (brightening reacts faster than dimming). Reaching an
    # endpoint (0 or 100) always counts, so the edges are never left short.
    local target=$1 diff

    if (( ambient < 0 )); then
        ambient=$target
        return 0
    fi

    diff=$(( target - ambient ))
    if (( diff == 0 )) || (( ${diff#-} < ML_HYSTERESIS && target != 0 && target != 100 )); then
        brighten_count=0
        dim_count=0
        return 1
    fi

    if (( diff > 0 )); then
        dim_count=0
        if (( ++brighten_count < ML_BRIGHTEN_CONFIRMS )); then
            log "brighten: confirming ($brighten_count/$ML_BRIGHTEN_CONFIRMS)"
            return 1
        fi
    else
        brighten_count=0
        if (( ++dim_count < ML_DIM_CONFIRMS )); then
            log "dim: confirming ($dim_count/$ML_DIM_CONFIRMS)"
            return 1
        fi
    fi

    brighten_count=0
    dim_count=0
    ambient=$target
    return 0
}

function on_battery {
    [ -f "$power_file" ] && [ "$(< "$power_file")" = 0 ]
}

function screen_level {
    local max=$ML_SCREEN_MAX
    on_battery && max=$(( ML_SCREEN_MAX * (100 - ML_BATTERY_DIM) / 100 ))
    (( max < ML_SCREEN_MIN )) && max=$ML_SCREEN_MIN
    clamp $(( ML_SCREEN_MIN + (max - ML_SCREEN_MIN) * ambient / 100 )) 0 100
}

function kbd_level_for_ambient {
    clamp $(( ML_KBD_BRIGHT * (100 - ambient) / 100 )) 0 100
}

function gnome_shell_running {
    gdbus call --session --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner org.gnome.Shell 2>/dev/null |
        grep -q true
}

function fade {
    local file=$1 from=$2 to=$3 steps value
    steps=$(awk -v d="$ML_DURATION" -v f="$ML_FRAME" 'BEGIN { n = int(d / f); print (n < 1 ? 1 : n) }')
    awk -v a="$from" -v b="$to" -v n="$steps" \
        'BEGIN { for (i = 1; i <= n; i++) printf "%d\n", a + (b - a) * i / n }' |
        while read -r value; do
            echo "$value" > "$file"
            sleep "$ML_FRAME"
        done
}

function apply_screen {
    local level=$1 max from to

    # Sent every poll: the extension skips levels it is already at, and a
    # restarted GNOME Shell picks the current level up again.
    if gdbus call --session --dest "$EXT_NAME" --object-path "$EXT_PATH" \
        --method "$EXT_NAME.SetAmbientBrightness" \
        "$(printf '%d.%02d' $(( level / 100 )) $(( level % 100 )))" \
        "uint32 $(awk -v d="$ML_DURATION" 'BEGIN { printf "%d", d * 1000 }')" \
        >/dev/null 2>&1; then
        return
    fi

    # GNOME Shell owns the backlight: writing sysfs behind its back would
    # desync the slider, so wait for the extension instead.
    if gnome_shell_running; then
        log "screen: extension not reachable, waiting"
        return
    fi

    (( level == screen_written )) && return
    max=$(< "$screen_dir/max_brightness")
    from=$(< "$screen_dir/brightness")
    to=$(( max * level / 100 ))
    screen_written=$level
    (( to == from )) && return
    log "screen: sysfs $from -> $to ($level%)"
    fade "$screen_dir/brightness" "$from" "$to"
}

function apply_kbd {
    local level=$1 max raw
    (( level == kbd_level )) && return
    max=$(< "$kbd_dir/max_brightness")
    raw=$(( max * level / 100 ))
    log "kbd: $level% ($raw/$max)"
    gdbus call --system --dest org.freedesktop.UPower \
        --object-path /org/freedesktop/UPower/KbdBacklight \
        --method org.freedesktop.UPower.KbdBacklight.SetBrightness "$raw" \
        >/dev/null 2>&1 || echo "$raw" > "$kbd_dir/brightness"
    kbd_level=$level
}

function idle_seconds {
    local out
    out=$(gdbus call --session --dest org.gnome.Mutter.IdleMonitor \
        --object-path /org/gnome/Mutter/IdleMonitor/Core \
        --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null) || { echo 0; return; }
    out=${out##* }         # "(uint64 12345,)" -> "12345,)"
    out=${out//[!0-9]/}
    echo $(( ${out:-0} / 1000 ))
}

function update {
    if [ -f "$lid_file" ] && [[ $(< "$lid_file") == *closed ]]; then
        log "lid closed, skip"
        return
    fi

    sample_light
    commit_ambient "$(ambient_level)" && log "ambient: $ambient% (sensor $smoothed)"

    $ML_AUTO_SCREEN && apply_screen "$(screen_level)"

    if $ML_AUTO_KBD; then
        if (( ML_KBD_TIMEOUT > 0 )) && (( $(idle_seconds) >= ML_KBD_TIMEOUT )); then
            apply_kbd 0
        else
            apply_kbd "$(kbd_level_for_ambient)"
        fi
    fi
}

function wait_for_drivers {
    local waited=0
    while [ ! -r "$light_file" ] || [ ! -d "$screen_dir" ] || { $ML_AUTO_KBD && [ ! -d "$kbd_dir" ]; }; do
        if (( waited++ >= 30 )); then
            echo "error: light sensor or backlight drivers not found after 30s" >&2
            exit 1
        fi
        sleep 1
    done
}

function main {
    wait_for_drivers
    log "watching ambient light every ${ML_INTERVAL}s"
    while true; do
        update
        sleep "$ML_INTERVAL"
    done
}

# Run only when executed, so tests can source the functions.
[[ ${BASH_SOURCE[0]} == "$0" ]] && main
