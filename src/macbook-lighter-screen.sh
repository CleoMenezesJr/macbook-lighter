#!/usr/bin/env bash
set -e

device='/sys/class/backlight/intel_backlight/brightness'
current=$(cat $device)
max=$(cat /sys/class/backlight/intel_backlight/max_brightness)

screen_help () {
    echo 'Usage: macbook-lighter-screen <OPTION> [NUM]'
    echo 'Increase or decrease screen backlight for MacBook'
    echo ''
    echo 'Exactly one of the following options should be specified.'
    echo '  -i [NUM], --inc [NUM]   increase backlight by NUM'
    echo '  -d [NUM], --dec [NUM]   decrease backlight by NUM'
    echo '  -m, --min               close backlight'
    echo '  -M, --max               set backlight to max'
    echo '  -h, --help              print this message'
    echo ''
    echo 'Examples:'
    echo '  # Increase screen backlight by 50'
    echo '  macbook-lighter-screen --inc 50'
    echo ''
    echo '  # Set screen backlight to max'
    echo '  macbook-lighter-screen --max'
}

notify_brightness() {
    local value="$1" session uid
    session=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null) || true
    uid=$(loginctl show-seat seat0 -p ActiveUser --value 2>/dev/null) || true

    [ -n "$session" ] && busctl call org.freedesktop.login1 \
        "/org/freedesktop/login1/session/$session" \
        org.freedesktop.login1.Session SetBrightness "ssu" \
        "backlight" "intel_backlight" "$value" 2>/dev/null || true

    [ -n "$uid" ] && DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        /usr/bin/gdbus call --session \
        --dest org.gnome.Shell.Extensions.MacbookLighter \
        --object-path /org/gnome/Shell/Extensions/MacbookLighter \
        --method org.gnome.Shell.Extensions.MacbookLighter.SetScreenBrightness \
        "uint32 $value" 2>/dev/null || true
}

screen_set() {
    echo $1 > $device
    notify_brightness "$1"
    echo set to $1
}

case $1 in
    -i|--inc)
        [[ -z "$2" || ! "$2" =~ ^[0-9]+$ ]] && { echo "error: --inc requires a numeric argument"; screen_help; exit 1; }
        screen_set $((current+$2 > max ? max : current + $2))
    ;;
    -d|--dec)
        [[ -z "$2" || ! "$2" =~ ^[0-9]+$ ]] && { echo "error: --dec requires a numeric argument"; screen_help; exit 1; }
        screen_set $((current < $2 ? 0 : current - $2))
    ;;
    -m|--min)
        screen_set 0
    ;;
    -M|--max)
        screen_set $max
    ;;
    -h|--help)
        screen_help
        exit 0
    ;;
    *)
        echo invalid options
        screen_help
        exit 1
    ;;
esac
