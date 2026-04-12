#!/usr/bin/env bash

intel_dir=/sys/class/backlight/intel_backlight
kbd_dir=/sys/class/leds/smc::kbd_backlight

power_file=/sys/class/power_supply/ADP1/online
screen_file=$intel_dir/brightness
kbd_file=$kbd_dir/brightness
lid_file=/proc/acpi/button/lid/LID0/state
light_file="/sys/devices/platform/applesmc.768/light"

#####################################################
# Settings
[ -f /etc/macbook-lighter.conf ] && source /etc/macbook-lighter.conf
ML_DURATION=${ML_DURATION:-1.5}
ML_FRAME=${ML_FRAME:-0.017}
ML_INTERVAL=${ML_INTERVAL:-5}
ML_BRIGHT_ENOUGH=${ML_BRIGHT_ENOUGH:-40}
ML_SCREEN_MIN_BRIGHT=${ML_SCREEN_MIN_BRIGHT:-15}
ML_KBD_BRIGHT=${ML_KBD_BRIGHT:-128}
ML_BATTERY_DIM=${ML_BATTERY_DIM:-0.2}
ML_KBD_TIMEOUT=${ML_KBD_TIMEOUT:-30}
ML_AUTO_KBD=${ML_AUTO_KBD:-true}
ML_AUTO_SCREEN=${ML_AUTO_SCREEN:-true}
ML_DEBUG=${ML_DEBUG:-false}
ML_SENSOR_SAMPLES=${ML_SENSOR_SAMPLES:-3}
ML_SENSOR_SAMPLE_DELAY=${ML_SENSOR_SAMPLE_DELAY:-0.3}
ML_EWMA_ALPHA=${ML_EWMA_ALPHA:-0.2}
ML_HYSTERESIS_PCT=${ML_HYSTERESIS_PCT:-15}
ML_BRIGHTEN_CONFIRMS=${ML_BRIGHTEN_CONFIRMS:-1}
ML_DIM_CONFIRMS=${ML_DIM_CONFIRMS:-3}

#####################################################
# wait drivers loaded

$ML_DEBUG && echo checking $intel_dir and $kbd_dir...
wait_timeout=30
waited=0
while [ ! -d $intel_dir -o ! -d $kbd_dir ]; do
    if (( waited >= wait_timeout )); then
        echo "error: backlight drivers not found after ${wait_timeout}s, aborting" >&2
        exit 1
    fi
    sleep 1
    (( waited++ ))
done
screen_max=$(cat $intel_dir/max_brightness)
active_session=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
active_uid=$(loginctl show-session "$active_session" -p UID --value 2>/dev/null)
# Fallback to current user when running interactively
[ -z "$active_uid" ] && active_uid="$(id -u)"

#####################################################
# Private States
prev_smoothed=""              # EWMA state — empty means uninitialized
screen_user_offset_dark=0     # per-bin user offsets
screen_user_offset_indoor=0
screen_user_offset_bright=0
screen_last_set=0             # last brightness value written by this script
last_trigger_light=0          # smoothed light that last triggered a change
brighten_count=0              # asymmetric confirmation counters
dim_count=0
kbd_adjusted_at=0
kbd_off_for_idle=false

function is_idle_for {
    local timeout_sec=$1
    (( timeout_sec <= 0 )) && return 1
    [ -z "$active_session" ] && return 1

    local idle_hint idle_since_us current_us idle_sec
    idle_hint=$(loginctl show-session "$active_session" -p IdleHint --value 2>/dev/null) || return 1
    [ "$idle_hint" = "yes" ] || return 1

    idle_since_us=$(loginctl show-session "$active_session" -p IdleSinceHint --value 2>/dev/null) || return 1
    current_us=$(date +%s%6N)
    idle_sec=$(( (current_us - idle_since_us) / 1000000 ))
    (( idle_sec >= timeout_sec ))
}

function read_sensor_raw {
    local val
    val=$(cat $light_file)    # eg. (41,0)
    val=${val:1:-3}           # eg. 41
    echo $val
}

function get_smoothed_light {
    # Stage 1: Median filter — take ML_SENSOR_SAMPLES readings, pick the middle
    local samples=() i raw
    for (( i=0; i<ML_SENSOR_SAMPLES; i++ )); do
        raw=$(read_sensor_raw)
        samples+=($raw)
        (( i < ML_SENSOR_SAMPLES - 1 )) && sleep $ML_SENSOR_SAMPLE_DELAY
    done
    IFS=$'\n' sorted=($(printf '%s\n' "${samples[@]}" | sort -n)); unset IFS
    local median=${sorted[$(( ML_SENSOR_SAMPLES / 2 ))]}

    # Stage 2: EWMA smoothing
    local smoothed
    if [ -z "$prev_smoothed" ]; then
        smoothed=$median
    else
        smoothed=$(echo "scale=0; $ML_EWMA_ALPHA * $median + (1 - $ML_EWMA_ALPHA) * $prev_smoothed" | bc -l)
    fi

    # Stage 3: Clamp to [1, ML_BRIGHT_ENOUGH]
    (( smoothed > ML_BRIGHT_ENOUGH )) && smoothed=$ML_BRIGHT_ENOUGH
    (( smoothed < 1 )) && smoothed=1
    prev_smoothed=$smoothed

    echo $smoothed
}

function should_update_brightness {
    local smoothed=$1

    # Proportional hysteresis dead-band
    if (( last_trigger_light > 0 )); then
        local diff=$(( smoothed - last_trigger_light ))
        (( diff < 0 )) && diff=$(( -diff ))
        local change_pct=$(( diff * 100 / last_trigger_light ))
        if (( change_pct < ML_HYSTERESIS_PCT )); then
            brighten_count=0
            dim_count=0
            $ML_DEBUG && echo "hysteresis: change ${change_pct}% < ${ML_HYSTERESIS_PCT}%, skip"
            return 1
        fi
    fi

    # Asymmetric confirmation
    if (( smoothed > last_trigger_light )); then
        dim_count=0
        (( brighten_count++ ))
        if (( brighten_count < ML_BRIGHTEN_CONFIRMS )); then
            $ML_DEBUG && echo "brighten: confirming ($brighten_count/$ML_BRIGHTEN_CONFIRMS)"
            return 1
        fi
    else
        brighten_count=0
        (( dim_count++ ))
        if (( dim_count < ML_DIM_CONFIRMS )); then
            $ML_DEBUG && echo "dim: confirming ($dim_count/$ML_DIM_CONFIRMS)"
            return 1
        fi
    fi

    # Confirmed — reset counters and update trigger
    last_trigger_light=$smoothed
    brighten_count=0
    dim_count=0
    return 0
}

function notify_brightness {
    local dev=$1
    local value=$2

    if [ "$dev" = "$screen_file" ]; then
        [ -n "$active_session" ] && busctl call org.freedesktop.login1 \
            "/org/freedesktop/login1/session/$active_session" \
            org.freedesktop.login1.Session SetBrightness "ssu" \
            "backlight" "intel_backlight" "$value" 2>/dev/null || true
        [ -n "$active_uid" ] && DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${active_uid}/bus" \
            /usr/bin/gdbus call --session \
            --dest org.gnome.Shell.Extensions.MacbookLighter \
            --object-path /org/gnome/Shell/Extensions.MacbookLighter \
            --method org.gnome.Shell.Extensions.MacbookLighter.SetScreenBrightness \
            "uint32 $value" 2>/dev/null || true
    else
        [ -n "$active_session" ] && busctl call org.freedesktop.login1 \
            "/org/freedesktop/login1/session/$active_session" \
            org.freedesktop.login1.Session SetBrightness "ssu" \
            "leds" "smc::kbd_backlight" "$value" 2>/dev/null || true
        if [ -n "$active_uid" ]; then
            local kbd_max percent
            kbd_max=$(cat $kbd_dir/max_brightness)
            percent=$(( value * 100 / kbd_max ))
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${active_uid}/bus" \
                /usr/bin/gdbus call --session \
                --dest org.gnome.Shell.Extensions.MacbookLighter \
                --object-path /org/gnome/Shell/Extensions.MacbookLighter \
                --method org.gnome.Shell.Extensions.MacbookLighter.SetKeyboardBrightness \
                "uint32 $percent" 2>/dev/null || true
        fi
    fi
}

function transition {
    from=$1
    to=$2
    dev=$3
    $ML_DEBUG && echo "transition $dev from $from to $to"
    steps=$(echo "$ML_DURATION / $ML_FRAME" | bc)
    for ((step=1; step<=$steps; step++)); do
        result=$(echo "($to - $from) * $step / $steps + $from" | bc)
        echo "$result" > "$dev"
    done
    notify_brightness "$dev" "$to"
}

function screen_range {
    screen_to=$1
    if (( screen_to < ML_SCREEN_MIN_BRIGHT )); then
        echo $ML_SCREEN_MIN_BRIGHT
    elif (( screen_to > screen_max )); then
        echo $screen_max
    else
        echo $screen_to
    fi
}

function screen_target {
    # Logarithmic mapping: sensor [1..ML_BRIGHT_ENOUGH] → brightness [ML_SCREEN_MIN_BRIGHT..screen_max]
    # log(1)=0 → min; log(ML_BRIGHT_ENOUGH)/log(ML_BRIGHT_ENOUGH)=1 → max.
    # Logarithmic feels natural because human brightness perception is also logarithmic.
    # Multiplied by battery coefficient when on battery.
    local light=$1
    local coef base
    coef=$(power_coef)
    base=$(echo "scale=0; ($screen_max - $ML_SCREEN_MIN_BRIGHT) * l($light) / l($ML_BRIGHT_ENOUGH) + $ML_SCREEN_MIN_BRIGHT" | bc -l)
    echo $(echo "scale=0; $base * $coef / 1" | bc -l)
}

function update_screen {
    light=$1
    screen_from=$(cat $screen_file)

    # Detect manual brightness adjustment (user moved the slider between our writes)
    if (( screen_last_set > 0 && screen_from != screen_last_set )); then
        local formula
        formula=$(screen_target $light)
        formula=$(screen_range $formula)
        screen_user_offset=$(( screen_from - formula ))
        $ML_DEBUG && echo "manual adjust detected, new offset: $screen_user_offset"
        screen_last_set=$screen_from
        return
    fi

    screen_to=$(( $(screen_target $light) + screen_user_offset ))
    screen_to=$(screen_range $screen_to)

    if (( screen_to - screen_from > -ML_SCREEN_THRESHOLD && screen_to - screen_from < ML_SCREEN_THRESHOLD )); then
        $ML_DEBUG && echo "screen threshold not reached($screen_from->$screen_to), skip update"
        return
    fi

    transition $screen_from $screen_to $screen_file
    screen_last_set=$screen_to
}

function update_kbd {
    light=$1
    kbd_from=$(cat $kbd_file)
    if (( kbd_from != 0 )); then
        ML_KBD_BRIGHT=$kbd_from
    fi

    $ML_DEBUG && echo light:$light, kbd_adjusted_at:$kbd_adjusted_at, ML_KBD_BRIGHT: $ML_KBD_BRIGHT

    if is_idle_for "$ML_KBD_TIMEOUT"; then
        $ML_DEBUG && echo "idle for ${ML_KBD_TIMEOUT}s, turning off kbd"
        kbd_to=0
        kbd_off_for_idle=true
    elif $kbd_off_for_idle; then
        # User returned from idle — restore if it's dark enough, otherwise reset flag
        kbd_off_for_idle=false
        if (( light < ML_BRIGHT_ENOUGH )); then
            kbd_to=$ML_KBD_BRIGHT
        else
            kbd_to=$kbd_from
        fi
    elif (( light >= ML_BRIGHT_ENOUGH && kbd_adjusted_at < ML_BRIGHT_ENOUGH )); then
        kbd_to=0
    elif (( light < ML_BRIGHT_ENOUGH && kbd_adjusted_at >= ML_BRIGHT_ENOUGH )); then
        kbd_to=$ML_KBD_BRIGHT
    else
        kbd_to=$kbd_from
    fi

    if (( kbd_to == kbd_from )); then
        $ML_DEBUG && echo "kbd no change($kbd_from->$kbd_to), skip update"
        return
    fi
    kbd_adjusted_at=$light
    transition $kbd_from $kbd_to $kbd_file
}

function update {
    $ML_DEBUG && echo updating
    lid=$(awk '{print $2}' $lid_file)
    if [ "$lid" == "closed" ]; then
        $ML_DEBUG && echo lid closed, skip update
        return
    fi

    light=$(get_light)
    $ML_AUTO_SCREEN && update_screen $light
    $ML_AUTO_KBD && update_kbd $light
}

function watch {
    $ML_DEBUG && echo watching light change...
    while true; do
        update
        sleep $ML_INTERVAL
    done
}

function power_coef {
    power=$(cat $power_file)
    if [ "$power" -eq 0 ]; then
        echo "1 - $ML_BATTERY_DIM" | bc
    else
        echo 1
    fi
}

function init {
    $ML_DEBUG && echo initializing backlights...

    light=$(get_light)
    kbd_adjusted_at=$light

    screen_from=$(cat $screen_file)
    kbd_from=$(cat $kbd_file)

    if $ML_AUTO_SCREEN; then
        local formula
        formula=$(screen_target $light)
        formula=$(screen_range $formula)
        screen_user_offset=$(( screen_from - formula ))
        screen_last_set=$screen_from
        $ML_DEBUG && echo "init: brightness=$screen_from, base=$formula, offset=$screen_user_offset"
    fi

    kbd_to=$(( light >= ML_BRIGHT_ENOUGH ? 0 : ML_KBD_BRIGHT ))
    $ML_AUTO_KBD && transition $kbd_from $kbd_to $kbd_file
}

init
watch
