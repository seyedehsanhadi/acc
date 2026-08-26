#!/system/bin/sh
# rc24-limits-hardcore.sh - the charging limits, end to end, on a live plug.
#
#   su -c 'sh /data/local/tmp/rc24-limits-hardcore.sh'
#
# START IT PLUGGED AND CHARGING. Every case needs current actually flowing.
#
# WHY THE TEST VALUES LOOK ODD
#   A Mi A3 vendor thermal driver steps charge current through 3A / 2A / 1.5A / 0.5A as the pack
#   warms, writing charge_control_limit itself. A test that caps at 500mA is therefore INDISTIN-
#   GUISHABLE from the vendor throttling to its own 0.5A step, and half an evening went to exactly
#   that ambiguity. Every value below sits off the vendor ladder on purpose:
#
#       current cap   1260 mA     (no vendor step is 1.26A)
#       voltage cap   4150 mV     (the defaults here are 4400 / 4450)
#
#   If a node reads 1260000, ACC put it there. Nothing else on either phone produces that number.
#
# WHAT IT COVERS
#   The two fixes made after rc24 was cut:
#     - the firmware-limit branch continued before is_charging(), so maxChargingCurrent and
#       maxChargingVoltage never ran on a Pixel at all
#     - clearing either limit left its derived node entries in the config, and they were re-applied
#       on every loop, so a cap could not be released
#   plus the edge cases the two of them create between them.

ID=rc24-limits-hardcore
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
sec(){ echo; echo "===== $* ====="; }

PS=/sys/class/power_supply
TD=/dev/.vr25/acc
CFG=/data/adb/vr25/acc-data/config.txt
MA=1260
MV=4150

cap(){ cat $PS/battery/capacity 2>/dev/null; }
st(){ cat $PS/battery/status 2>/dev/null; }
tmp(){ cat $PS/battery/temp 2>/dev/null; }
cfg(){ sed -n "s/^$1=//p" $CFG 2>/dev/null; }
plugged(){ [ "$(cat $PS/usb/present 2>/dev/null)" = 1 ]; }

curnodes(){
  [ -f $TD/ch-curr-ctrl-files ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "$l" ] || continue
    n=${l%%::*}
    case "$n" in /*) p=$n ;; *) p=$PS/$n ;; esac
    [ -e "$p" ] && printf "%s=%s " "$n" "$(cat "$p" 2>/dev/null)"
  done < $TD/ch-curr-ctrl-files
  echo
}
holding(){ curnodes | tr " " "\n" | grep -c "=${1}000$"; }

fin(){ echo; echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
restore(){
  trap - EXIT INT TERM HUP
  acc -s maxChargingCurrent= >/dev/null 2>&1
  acc -s maxChargingVoltage= >/dev/null 2>&1
  sleep 5
  echo
  echo "  RESTORE: mcc=$(cfg maxChargingCurrent) mcv=$(cfg maxChargingVoltage)"
  echo "  nodes  : $(curnodes)"
  fin
}
trap restore EXIT INT TERM HUP

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)   build: $(sed -n s/version=//p /data/adb/modules/acc/module.prop)"
echo "level  : $(cap)%   temp: $(( $(tmp) / 10 ))C   status: $(st)"
echo "values : current ${MA}mA, voltage ${MV}mV - both off the vendor ladder"

sec "0  PREFLIGHT"
[ "$(id -u)" = 0 ] || { no "not root"; fin; }
plugged || { echo "  ABORT: start this PLUGGED."; exit 1; }
ok "cable attached"
[ "$(st)" = Charging ] && ok "charging" || { echo "  ABORT: status is $(st)."; exit 1; }
_pid=$(pgrep -f accd.sh | head -1)
[ -n "$_pid" ] && ok "daemon running (pid $_pid)" || { no "no daemon"; fin; }
_nat=no; [ -f /sys/devices/platform/google,charger/charge_stop_level ] && _nat=yes
echo "  firmware limit on this phone: $_nat"

sec "1  DISCOVERY while charging"
_w=0
while [ $_w -lt 90 ]; do
  [ -f $TD/ch-curr-ctrl-files ] && grep -q / $TD/ch-curr-ctrl-files 2>/dev/null && break
  sleep 10; _w=$((_w+10))
done
_n=$(grep -c / $TD/ch-curr-ctrl-files 2>/dev/null || :); _n=${_n:-0}
[ "$_n" -ge 1 ] && ok "resolved $_n current-control node(s) after ${_w}s" \
                || no "no current-control nodes resolved in ${_w}s - a cap has nothing to write"

sec "2  APPLY ${MA}mA"
acc -s maxChargingCurrent=$MA >/dev/null 2>&1
sleep 40
echo "  cfg   : $(cfg maxChargingCurrent | cut -c1-70)"
echo "  nodes : $(curnodes)"
_h=$(holding $MA)
[ "$_h" -ge 1 ] && ok "$_h node(s) hold exactly ${MA}000" || no "no node holds ${MA}000 - the cap did not land"
case "$(cfg maxChargingCurrent)" in
  "($MA "*) ok "the config expanded to node entries" ;;
  "($MA)")  no "the config kept the bare value - it never expanded" ;;
  *)        no "unexpected config: $(cfg maxChargingCurrent)" ;;
esac

sec "3  CLEAR, and the nodes must come back"
acc -s maxChargingCurrent= >/dev/null 2>&1
sleep 40
echo "  cfg   : $(cfg maxChargingCurrent)"
echo "  nodes : $(curnodes)"
[ "$(cfg maxChargingCurrent)" = "()" ] && ok "config cleared to ()" || no "config still holds: $(cfg maxChargingCurrent)"
_h=$(holding $MA)
[ "$_h" -eq 0 ] && ok "no node left at ${MA}000" || no "$_h node(s) still pinned at ${MA}000"

sec "4  VOLTAGE ${MV}mV"
_vn=0; [ -f $TD/ch-volt-ctrl-files ] && { _vn=$(grep -c / $TD/ch-volt-ctrl-files 2>/dev/null || :); _vn=${_vn:-0}; }
if [ "$_vn" -eq 0 ]; then
  sk "this phone exposes no battery voltage-limit node"
else
  acc -s maxChargingVoltage=$MV >/dev/null 2>&1; sleep 30
  _vh=$(while IFS= read -r l; do n=${l%%::*}; [ -e "$PS/$n" ] && cat "$PS/$n"; done < $TD/ch-volt-ctrl-files | grep -c "^${MV}000$")
  [ "$_vh" -ge 1 ] && ok "$_vh voltage node(s) hold ${MV}000" || no "the voltage cap did not land"
  acc -s maxChargingVoltage= >/dev/null 2>&1; sleep 30
  _vh=$(while IFS= read -r l; do n=${l%%::*}; [ -e "$PS/$n" ] && cat "$PS/$n"; done < $TD/ch-volt-ctrl-files | grep -c "^${MV}000$")
  [ "$_vh" -eq 0 ] && ok "the voltage cap released" || no "$_vh voltage node(s) still at ${MV}000"
  [ "$(cfg maxChargingVoltage)" = "()" ] && ok "voltage config cleared to ()" || no "voltage config: $(cfg maxChargingVoltage)"
fi

sec "5  A CAP SURVIVES A DAEMON RESTART"
acc -s maxChargingCurrent=$MA >/dev/null 2>&1; sleep 30
acc -D restart >/dev/null 2>&1; sleep 45
_h=$(holding $MA)
[ "$_h" -ge 1 ] && ok "still applied after a restart ($_h node(s))" || no "the cap was lost across a restart"

sec "6  A CLEARED CAP STAYS CLEARED ACROSS ONE"
acc -s maxChargingCurrent= >/dev/null 2>&1; sleep 30
acc -D restart >/dev/null 2>&1; sleep 45
echo "  nodes : $(curnodes)"
_h=$(holding $MA)
[ "$_h" -eq 0 ] && ok "still cleared after a restart" || no "$_h node(s) came back at ${MA}000"
[ "$(cfg maxChargingCurrent)" = "()" ] && ok "config still ()" || no "config drifted to: $(cfg maxChargingCurrent)"

sec "7  A CONFIG CORRUPTED BY AN OLDER BUILD MUST HEAL"
_first=$(head -1 $TD/ch-curr-ctrl-files 2>/dev/null)
if [ -n "$_first" ]; then
  _fn=${_first%%::*}
  sed -i "s|^maxChargingCurrent=.*|maxChargingCurrent=( ${_fn}::${MA}000::999999)|" $CFG
  echo "  planted: $(cfg maxChargingCurrent)"
  acc -s ui_refresh=60 >/dev/null 2>&1; sleep 20
  [ "$(cfg maxChargingCurrent)" = "()" ] && ok "the corrupted key healed on the next write" \
                                        || no "still corrupted: $(cfg maxChargingCurrent)"
else
  sk "no resolved node to build a corrupted entry from"
fi

sec "8  FINAL STATE"
echo "  level $(cap)%  temp $(( $(tmp) / 10 ))C  status $(st)"
echo "  nodes: $(curnodes)"
_h=$(holding $MA)
[ "$_h" -eq 0 ] && ok "no test value left anywhere" || no "$_h node(s) still hold ${MA}000"
[ -n "$(pgrep -f accd.sh)" ] && ok "daemon alive at exit" || no "daemon died"

restore
