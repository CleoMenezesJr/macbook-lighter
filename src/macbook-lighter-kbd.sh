#!/usr/bin/env bash
set -e

dir='/sys/class/leds/smc::kbd_backlight'
max=$(< "$dir/max_brightness")
current=$(( $(< "$dir/brightness") * 100 / max ))

kbd_help () {
    echo 'Usage: macbook-lighter-kbd <OPTION> [PCT]'
    echo 'Increase or decrease keyboard backlight for MacBook, in percent'
    echo ''
    echo 'Exactly one of the following options should be specified.'
    echo '  -i [PCT], --inc [PCT]   increase backlight by PCT points'
    echo '  -d [PCT], --dec [PCT]   decrease backlight by PCT points'
    echo '  -s [PCT], --set [PCT]   set backlight to PCT'
    echo '  -m, --min               close backlight'
    echo '  -M, --max               set backlight to max'
    echo '  -h, --help              print this message'
    echo ''
    echo 'Examples:'
    echo '  # Increase keyboard backlight by 20 %'
    echo '  macbook-lighter-kbd --inc 20'
    echo ''
    echo '  # Set keyboard backlight to max'
    echo '  macbook-lighter-kbd --max'
}

kbd_set() {
    local pct=$(( $1 < 0 ? 0 : $1 > 100 ? 100 : $1 ))
    local raw=$(( max * pct / 100 ))

    if (( pct == current )); then
        echo "already at $pct%"
        return
    fi

    # Through UPower, so GNOME's keyboard brightness stays in sync
    /usr/bin/gdbus call --system --dest org.freedesktop.UPower \
        --object-path /org/freedesktop/UPower/KbdBacklight \
        --method org.freedesktop.UPower.KbdBacklight.SetBrightness "$raw" \
        >/dev/null 2>&1 || echo "$raw" > "$dir/brightness"
    echo "set to $pct%"
}

need_number() {
    [[ "$1" =~ ^[0-9]+$ ]] || { echo "error: a numeric percentage is required"; kbd_help; exit 1; }
}

case $1 in
    -i|--inc) need_number "$2"; kbd_set $(( current + $2 )) ;;
    -d|--dec) need_number "$2"; kbd_set $(( current - $2 )) ;;
    -s|--set) need_number "$2"; kbd_set "$2" ;;
    -m|--min) kbd_set 0 ;;
    -M|--max) kbd_set 100 ;;
    -h|--help) kbd_help ;;
    *)
        echo "invalid options"
        kbd_help
        exit 1
    ;;
esac
