#!/system/bin/sh
# Execute the production writer against fake sysfs; no hardware writes.
execDir=${execDir:-/data/adb/vr25/acc}
AMPS=${AMPS:-$execDir/amps.sh}
AWKF=${AWKF:-${0%/*}/../xf.awk}
W=${W:-/data/local/tmp/supply-quirks-$$}
mkdir -p "$W/usb" "$W/mtk-master-charger" "$W/bk" "$W/acc"
PSY=$W; BK=$W/bk; SNAP=$BK/snap; SNLIST=$BK/list; HAVE_TO=0
: > "$SNAP"; : > "$SNLIST"
eval "$(sed "s@/dev/.vr25/acc/@$W/acc/@g;s@/data/adb/vr25/acc-data/@$W/acc/@g" "$execDir/supply-quirks.sh")"
ex(){ [ -e "$1" ]; }; rd(){ cat "$1"; }; bl_has(){ return 1; }
eval "$(awk -v fn=kernel_owned_probe -f "$AWKF" "$AMPS" | sed "s@/sys/kernel/debug@$W/debug@g")"
for fn in wr snap_add emit_known on_sane; do eval "$(awk -v fn="$fn" -f "$AWKF" "$AMPS")"; done
jrn_begin(){ return 0; }; jrn_end(){ :; }; log(){ echo "$*"; }
getprop(){ echo "${VENDOR:-motorola}"; }
cat(){ if [ "$1" = "$W/mtk-master-charger/current_max" ] && [ "${WRITE_ONLY:-1}" = 1 ]; then return 1; fi; command cat "$@"; }
P=0; F=0
check(){ if "$@"; then P=$((P+1)); echo "PASS $*"; else F=$((F+1)); echo "FAIL $*"; fi; }
refuses(){ "$@"; [ $? != 0 ]; }
echo 3000000 > "$W/mtk-master-charger/current_max"
check mtk_current_flag "$W/mtk-master-charger/current_max"
check refuses wr "$W/mtk-master-charger/current_max" 3000000
check wr "$W/mtk-master-charger/current_max" 0
check test "$(command cat "$W/mtk-master-charger/current_max")" = 0
check wr "$W/mtk-master-charger/current_max" 1
check test "$(command cat "$W/mtk-master-charger/current_max")" = 1
check test "$(emit_known | tail -1)" = "$W/mtk-master-charger/current_max|0|1"
WRITE_ONLY=0
check refuses mtk_current_flag "$W/mtk-master-charger/current_max"
check wr "$W/mtk-master-charger/current_max" 3000000
WRITE_ONLY=1; VENDOR=other
check refuses mtk_current_flag "$W/mtk-master-charger/current_max"
VENDOR=motorola
rd1(){ echo 3000000; }
check on_sane "$W/mtk-master-charger/current_max 0 1"
WRITE_ONLY=0
check refuses on_sane "$W/mtk-master-charger/current_max 0 1"
WRITE_ONLY=1
eval "$(awk -v fn=filter_sw -f "$AWKF" "$execDir/accd.sh")"
check test "$(filter_sw "$W/mtk-master-charger/current_max" 3000000 0)" = "$W/mtk-master-charger/current_max 0 1"
for fn in write flip_sw; do eval "$(awk -v fn="$fn" -f "$AWKF" "$execDir/misc-functions.sh")"; done
parse_value(){ echo "$1"; }; _wlog(){ :; }
TMPDIR=$W; dataDir=$W; currFile=$W/current_now; curThen=$W/curThen
echo 250000 > "$currFile"; mkdir -p "$W/logs"
chargingSwitch=("$W/mtk-master-charger/current_max" 3000000 0 --)
check flip_sw off
check test "$(command cat "$W/mtk-master-charger/current_max")" = 1
check flip_sw on
check test "$(command cat "$W/mtk-master-charger/current_max")" = 0
check refuses write 3000000 "$W/mtk-master-charger/current_max"
eval "$(awk -v fn=_write -f "$AWKF" "$execDir/acc-switch-scan.sh")"
_sw_blacklisted(){ return 1; }
check _write off "$W/mtk-master-charger/current_max 3000000 0"
check test "$(command cat "$W/mtk-master-charger/current_max")" = 1
check _write on "$W/mtk-master-charger/current_max 3000000 0"
check test "$(command cat "$W/mtk-master-charger/current_max")" = 0
echo 1 > "$W/usb/present"; echo 7710000 > "$W/usb/voltage_now"
echo USB_HVDCP_3 > "$W/usb/real_type"; echo 1993000 > "$W/usb/current_now"
echo untouched > "$W/usb/apsd_rerun"
check refuses wr "$W/usb/apsd_rerun" 1
check test "$(command cat "$W/usb/apsd_rerun")" = untouched
_RESTORING=1
check refuses wr "$W/usb/apsd_rerun" 0
check snap_add "$W/usb/apsd_rerun"
check test ! -s "$SNAP"
echo 5000000 > "$W/usb/voltage_now"; echo 0 > "$W/usb/current_now"
check refuses charge_redetect_safe "$W"
echo USB_DCP > "$W/usb/real_type"
check charge_redetect_safe "$W"
echo 800000 > "$W/usb/current_now"
check refuses charge_redetect_safe "$W"
echo 0 > "$W/usb/current_now"
rm -f "$BK"/redetect-*
check wr "$W/usb/apsd_rerun" 1
check refuses wr "$W/usb/apsd_rerun" 1
echo 0 > "$W/usb/present"
check refuses charge_redetect_safe "$W"

mkdir -p "$W/qcom-battery"
echo 1 > "$W/usb/present"; echo 5000000 > "$W/usb/voltage_now"
echo USB_DCP > "$W/usb/real_type"; echo 0 > "$W/usb/current_now"
echo untouched > "$W/usb/apsd_rerun"; echo untouched > "$W/qcom-battery/apsd_rerun"
rm -f "$BK"/redetect-*
check wr "$W/usb/apsd_rerun" 1
check wr "$W/qcom-battery/apsd_rerun" 1
check test "$(command cat "$W/qcom-battery/apsd_rerun")" = 1
check refuses wr "$W/qcom-battery/apsd_rerun" 1
check refuses wr "$W/usb/apsd_rerun" 1

mkdir -p "$W/battery" "$W/main" "$W/debug/pmic-votable/FCC_MAIN"
echo 4 > "$W/battery/charge_control_limit"; echo 6 > "$W/battery/charge_control_limit_max"
check refuses wr "$W/battery/charge_control_limit" 0
check test "$(cat "$W/battery/charge_control_limit")" = 4
check snap_add "$W/battery/charge_control_limit"
check refuses grep -qF "$W/battery/charge_control_limit" "$SNAP"
echo 100 > "$W/battery/charge_control_limit_max"
check wr "$W/battery/charge_control_limit" 80
echo 3000000 > "$W/battery/constant_charge_current_max"
echo 500000 > "$W/main/constant_charge_current_max"
: > "$W/debug/pmic-votable/FCC_MAIN/status"
check refuses wr "$W/main/constant_charge_current_max" 0
check snap_add "$W/main/constant_charge_current_max"
check refuses grep -qF "$W/main/constant_charge_current_max" "$SNAP"
check wr "$W/battery/constant_charge_current_max" 0
rm "$W/debug/pmic-votable/FCC_MAIN/status"
check wr "$W/main/constant_charge_current_max" 1000000
echo "$P passed, $F failed"
[ "$F" = 0 ]
