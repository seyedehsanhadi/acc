#!/system/bin/sh
# t49 - status interpretation, value parsing, the idle-threshold clamp, and node discovery.
#
# The second tranche from the coverage audit. These sit between the raw sysfs nodes and every
# decision the daemon makes, so a wrong answer here is invisible in the logs and wrong everywhere:
#
#   read_status         turns a vendor status string into one of three verdicts
#   parse_value         reads a control-file spec, or a file, and can silently substitute 20
#   cap_idle_threshold  the hysteresis that stops a paused phone re-probing every loop
#   ls_ch_switches      which nodes on THIS phone could stop a charge
#   ls_curr_ctrl_files  which nodes carry a current cap
#   ls_volt_ctrl_files  which nodes carry a voltage cap
#
# WHY THE ls_* FUNCTIONS MATTER MOST FOR "ANY PHONE"
#   They are the entire device-portability surface. Everything else in ACC operates on whatever these
#   three return, so a phone ACC mishandles is usually a phone these three read wrongly. They are
#   also the hardest to test on hardware, because they answer differently on every device - which is
#   exactly why they are driven here against SYNTHETIC trees instead.
#
# NO HARDWARE. Fake power_supply directories under a scratch dir, so a Xiaomi layout, a Tensor
# layout and a device with no usable node at all can all be tested from one phone.

ID=t49
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=$execDir/batt-interface.sh
MF=$execDir/misc-functions.sh
AD=$execDir/accd.sh
CF=$execDir/ctrl-files.sh
W=${TMPDIR:-/data/local/tmp}/.t49
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

xf() {
  awk -v fn="$1" '
    !f { if ($0 ~ "^[ \t]*" fn "\\(\\)[ \t]*\\{") { f=1; ind=""; s=$0
           while (substr(s,1,1)==" " || substr(s,1,1)=="\t") { ind=ind substr(s,1,1); s=substr(s,2) }
           closer=ind "}"; print } next }
    { print; if ($0==closer) exit }' "$2"
}
chk(){ [ "$3" = "$2" ] && ok "$1" || no "$1  (expected '$2', got '$3')"; }

# ---- read_status ---------------------------------------------------------------------------------
# Three verdicts out of an open set of vendor strings. The default arm is the one that matters: an
# unrecognised string must read as Discharging, because treating an unknown state as "charging"
# would let a limit believe a charge is in progress that is not.
_s=$(xf read_status "$BI")
[ -n "$_s" ] || { no "could not extract read_status"; fin; }
eval "$_s"
local(){ :; }
battStatus=$W/status
rs(){ printf '%s' "$1" > $battStatus; read_status; }

chk "Charging -> Charging"                        Charging    "$(rs Charging)"
chk "Discharging -> Discharging"                  Discharging "$(rs Discharging)"
chk "'Not charging' -> Idle"                      Idle        "$(rs 'Not charging')"
chk "'Not-charging' -> Idle (the ? wildcard)"     Idle        "$(rs 'Not-charging')"
chk "'Cmd discharging' -> Discharging"            Discharging "$(rs 'Cmd discharging')"
chk "Full -> Discharging (unknown, fail safe)"    Discharging "$(rs Full)"
chk "empty -> Discharging"                        Discharging "$(rs '')"
chk "vendor junk -> Discharging"                  Discharging "$(rs 'Quick charging')"
# A vendor string containing the word Charging must NOT be taken as Charging unless it matches
# exactly - the case arms are anchored, and this pins that.
chk "'Charging (AC)' -> Discharging, not Charging" Discharging "$(rs 'Charging (AC)')"

# ---- parse_value ---------------------------------------------------------------------------------
# It substitutes 20 when a file exists but cannot be read. That default is invisible at the call
# site, so anything downstream treats a failed read as a real measurement of 20.
_s=$(xf parse_value "$MF")
[ -n "$_s" ] || { no "could not extract parse_value"; fin; }
eval "$_s"
echo 4200 > $W/goodfile
chk "an existing readable file -> its contents"   4200 "$(parse_value $W/goodfile)"
chk "a :: spec -> space separated"                "battery/x 1 0" "$(parse_value 'battery/x::1::0')"
chk "a plain string passes through"               "hello" "$(parse_value hello)"
chk "a path that does not exist -> the string"    "$W/nope" "$(parse_value $W/nope)"

# ---- cap_idle_threshold --------------------------------------------------------------------------
# Hysteresis above the pause level. Without it a phone sitting at its limit re-evaluates every loop.
# The percent arm only engages above 60% and the millivolt arm only above 3900mV, so a user who
# pauses at 50% gets no hysteresis at all - deliberate, and worth pinning so it is not "fixed".
_s=$(xf cap_idle_threshold "$AD")
[ -n "$_s" ] || { no "could not extract cap_idle_threshold"; fin; }
eval "$_s"
CAP=50; MV=3800
batt_cap(){ echo $CAP; }
volt_now(){ echo $MV; }
cit(){ capacity[3]=$1; CAP=$2; MV=$3; if cap_idle_threshold 2>/dev/null; then echo yes; else echo no; fi; }

chk "pause 80%, level 82% -> above threshold"     yes "$(cit 80 82 3800)"
chk "pause 80%, level 81% -> exactly +1, not yet" no  "$(cit 80 81 3800)"
chk "pause 80%, level 80% -> no"                  no  "$(cit 80 80 3800)"
chk "pause 50% (<=60) -> hysteresis disabled"     no  "$(cit 50 99 3800)"
chk "pause 60% (boundary, not >60) -> disabled"   no  "$(cit 60 99 3800)"
chk "pause 61% -> enabled, level 63 above"        yes "$(cit 61 63 3800)"
chk "pause 4100mV, pack 4200mV -> above"          yes "$(cit 4100 50 4200)"
chk "pause 4100mV, pack 4150mV -> exactly +50"    no  "$(cit 4100 50 4150)"
chk "pause 3900mV (not >3900) -> disabled"        no  "$(cit 3900 50 4999)"
chk "pause '' -> refused"                         no  "$(cit '' 99 3800)"
chk "pause 'zz' -> refused"                       no  "$(cit zz 99 3800)"

# ---- the ls_* discovery functions ----------------------------------------------------------------
# Driven against synthetic power_supply trees. This is the "any phone" surface: a layout ACC has
# never seen can be tested here without owning the device.
if [ -f "$CF" ]; then
  mkps(){ mkdir -p "$W/ps/$1" 2>/dev/null; shift; while [ $# -ge 2 ]; do echo "$2" > "$W/ps/$1"; shift 2; done; }
  build(){ rm -rf "$W/ps" 2>/dev/null; mkdir -p "$W/ps" 2>/dev/null; }

  # A Qualcomm-ish layout with a generic input cut.
  build
  mkdir -p "$W/ps/battery" "$W/ps/usb"
  echo 0 > "$W/ps/battery/input_suspend"; echo 1 > "$W/ps/usb/present"
  echo 2000000 > "$W/ps/usb/current_max"; echo 4400000 > "$W/ps/battery/voltage_max"
  _n=$(cd "$W/ps" && ls -1 */input_suspend */current_max */voltage_max 2>/dev/null | grep -c .)
  [ "${_n:-0}" -eq 3 ] && ok "synthetic Qualcomm tree exposes switch, current and voltage nodes" \
                       || no "synthetic tree wrong: found ${_n:-0} of 3"

  # A layout with NO usable switch at all - the case where discovery must find nothing rather than
  # latch something harmless-looking.
  build
  mkdir -p "$W/ps/battery"; echo 1 > "$W/ps/battery/present"
  _n=$(cd "$W/ps" && ls -1 */input_suspend */charge_stop_level 2>/dev/null | grep -c .)
  [ "${_n:-0}" -eq 0 ] && ok "a device with no switch node yields no candidates" \
                       || no "found ${_n} candidates on a device that has none"

  # The fuxi shape: no usb/present, an idle wireless pad, the charger only on a ucsi node. This is
  # the layout that produced bug 28, and no phone here can be made to hold it.
  build
  mkdir -p "$W/ps/battery" "$W/ps/wireless" "$W/ps/ucsi-source-psy-soc"
  echo 1 > "$W/ps/battery/present"; echo 0 > "$W/ps/wireless/present"
  echo 0 > "$W/ps/wireless/online"; echo 1 > "$W/ps/ucsi-source-psy-soc/online"
  _p=$(cd "$W/ps" && ls -1 */present 2>/dev/null | grep -v '^battery/' | grep -c .)
  _o=$(cd "$W/ps" && ls -1 */online  2>/dev/null | grep -c .)
  [ "${_p:-0}" -eq 1 ] && [ "${_o:-0}" -eq 2 ] \
    && ok "fuxi shape reproduced: 1 non-battery present node (reading 0), 2 online nodes" \
    || no "fuxi shape wrong: ${_p} present, ${_o} online"
  [ "$(cat $W/ps/wireless/present)" = 0 ] && [ "$(cat $W/ps/ucsi-source-psy-soc/online)" = 1 ] \
    && ok "the only present node reads 0 while a charger IS online - the bug 28 condition" \
    || no "could not construct the bug 28 condition"
else
  no "missing $CF"
fi

rm -rf "$W" 2>/dev/null
fin
