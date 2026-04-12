#!/usr/bin/env bash
set -e

device='/sys/class/leds/smc::kbd_backlight/brightness'
current=$(cat $device)
max=$(cat /sys/class/leds/smc::kbd_backlight/max_brightness)

kbd_help () {
    echo 'Usage: macbook-lighter-kbd <OPTION> [NUM]'
    echo 'Increase or decrease keyboard backlight for MacBook'
    echo ''
    echo 'Exactly one of the following options should be specified.'
    echo '  -i [NUM], --inc [NUM]   increase backlight by NUM'
    echo '  -d [NUM], --dec [NUM]   decrease backlight by NUM'
    echo '  -m, --min               close backlight'
    echo '  -M, --max               set backlight to max'
    echo '  -h, --help              print this message'
    echo ''
    echo 'Examples:'
    echo '  # Increase keyboard backlight by 50'
    echo '  macbook-lighter-kbd --inc 50'
    echo ''
    echo '  # Set keyboard backlight to max'
    echo '  macbook-lighter-kbd --max'
}

get_active_user_info() {
    local session
    session=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
    if [ -n "$session" ]; then
        local uid
        uid=$(loginctl show-session "$session" -p UID --value 2>/dev/null)
        if [ -n "$uid" ]; then
            echo "$uid $session"
            return 0
        fi
    fi
    return 1
}

notify_brightness() {
    local value="$1"
    read -r current_uid current_session <<< "$(get_active_user_info)"

    [ -n "$current_session" ] && busctl call org.freedesktop.login1 \
        "/org/freedesktop/login1/session/$current_session" \
        org.freedesktop.login1.Session SetBrightness "ssu" \
        "leds" "smc::kbd_backlight" "$value" 2>/dev/null || true

    if [ -n "$current_uid" ]; then
        local percent
        percent=$(( value * 100 / max ))
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${current_uid}/bus" \
        sudo -u "#${current_uid}" /usr/bin/gdbus call --session \
            --dest org.gnome.Shell.Extensions.MacbookLighter \
            --object-path /org/gnome/Shell/Extensions/MacbookLighter \
            --method org.gnome.Shell.Extensions.MacbookLighter.SetKeyboardBrightness \
            "uint32 $percent" 2>/dev/null || true
    fi
}

kbd_set() {
    notify_brightness "$1"
    echo set to $1
}

case $1 in
    -i|--inc)
        [[ -z "$2" || ! "$2" =~ ^[0-9]+$ ]] && { echo "error: --inc requires a numeric argument"; kbd_help; exit 1; }
        kbd_set $((current+$2 > max ? max : current + $2))
    ;;
    -d|--dec)
        [[ -z "$2" || ! "$2" =~ ^[0-9]+$ ]] && { echo "error: --dec requires a numeric argument"; kbd_help; exit 1; }
        kbd_set $((current < $2 ? 0 : current - $2))
    ;;
    -m|--min)
        kbd_set 0
    ;;
    -M|--max)
        kbd_set $max
    ;;
    -h|--help)
        kbd_help
        exit 0
    ;;
    *)
        echo invalid options
        kbd_help
        exit 1
    ;;
esac
