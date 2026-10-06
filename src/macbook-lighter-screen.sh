#!/usr/bin/env bash
set -e

dir='/sys/class/backlight/intel_backlight'
max=$(< "$dir/max_brightness")
current=$(( $(< "$dir/brightness") * 100 / max ))

screen_help () {
    echo 'Usage: macbook-lighter-screen <OPTION> [PCT]'
    echo 'Increase or decrease screen backlight for MacBook, in percent'
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
    echo '  # Increase screen backlight by 10 %'
    echo '  macbook-lighter-screen --inc 10'
    echo ''
    echo '  # Set screen backlight to max'
    echo '  macbook-lighter-screen --max'
}

screen_set() {
    local pct=$(( $1 < 0 ? 0 : $1 > 100 ? 100 : $1 ))

    if (( pct == current )); then
        echo "already at $pct%"
        return
    fi

    # On GNOME, go through the shell (like the slider) so it stays in sync;
    # elsewhere write sysfs directly.
    if ! /usr/bin/gdbus call --session \
        --dest org.gnome.Shell.Extensions.MacbookLighter \
        --object-path /org/gnome/Shell/Extensions/MacbookLighter \
        --method org.gnome.Shell.Extensions.MacbookLighter.SetBrightness \
        "$(printf '%d.%02d' $(( pct / 100 )) $(( pct % 100 )))" >/dev/null 2>&1; then
        echo $(( max * pct / 100 )) > "$dir/brightness"
    fi
    echo "set to $pct%"
}

need_number() {
    [[ "$1" =~ ^[0-9]+$ ]] || { echo "error: a numeric percentage is required"; screen_help; exit 1; }
}

case $1 in
    -i|--inc) need_number "$2"; screen_set $(( current + $2 )) ;;
    -d|--dec) need_number "$2"; screen_set $(( current - $2 )) ;;
    -s|--set) need_number "$2"; screen_set "$2" ;;
    -m|--min) screen_set 0 ;;
    -M|--max) screen_set 100 ;;
    -h|--help) screen_help ;;
    *)
        echo "invalid options"
        screen_help
        exit 1
    ;;
esac
