#!/system/bin/sh
execDir=${execDir:-/data/adb/vr25/acc}
. "$execDir/state-export.sh"
eval "$(sed -n '/^_iin_ma() {/,/^}/p' "$execDir/misc-functions.sh")"
W=$(mktemp -d "${TMPDIR:-/data/local/tmp}/t115.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
TMPDIR=$W
mkdir -p "$W/usb"
cd "$W" || exit 1
P=0
check(){ value=$(_iin_ma) || value=unknown; [ "$value" = "$1" ] || { echo "FAIL $2: $value != $1"; exit 1; }; P=$((P+1)); }
printf '2696040\n' > usb/input_current_now
check 2696 charging
printf '5353\n' > usb/input_current_now
check 5 taper
printf '0\n' > usb/input_current_now
check 0 zero
rm usb/input_current_now
printf '1800\n' > usb/current_now
check unknown independent-node
inputAmpFactor=1000
check 1800 explicit-milliamps
printf '%s\n' -1800 > usb/current_now
check 1800 negative-current
inputAmpFactor=1000000
check 1 explicit-microamps
printf 'garbage\n' > usb/current_now
check unknown faulty-sensor
echo "t115: $P passed, 0 failed"
