#!/system/bin/sh
# requires: plugged
# t154 - drive the real limits on a real charger and watch what the daemon actually does.
#
# Everything else in this campaign grades source text, lifted functions or forced cycles. None of it
# answers the plain question: move the limit under the pack and does charging stop, move it back and
# does charging start, do the same with the temperature band and does the thermal hold engage and
# release. That is the whole product, and until now it was inferred.
#
# THE OBSERVABLE is ACC's own flight.log row, because it is what the daemon believes rather than
# what a node happens to read:
#   epoch,level,current,status,present,online,chDisabledByAcc,reason,vbus,mcc,chargerType,temp
# Field 7 is the pause flag and field 12 is the temperature in deci-C. The current sign is NOT used:
# laurus reports a negative current while charging, so a sign test would grade it backwards.
#
# SAFETY
#   shutdown_temp is never written. That is the campaign's standing rule and it is checked below
#   rather than left to reviewer discipline: a low cutoff powers the phone off at room temperature.
#   Every arm restores the original capacity and temperature lines through a trap armed on all
#   signals, and the restore is verified against the values captured at entry.
#
# NEEDS THE CABLE IN.

ID=t154
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed${S:+, $S skipped}"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
dataDir=${dataDir:-/data/adb/vr25/acc-data}
CFG=$dataDir/config.txt
FL=$dataDir/logs/flight.log
ACC=$(command -v acc 2>/dev/null); [ -n "$ACC" ] || ACC=$execDir/acc.sh
BATT=/sys/class/power_supply/battery

[ 1 = 2 ] && no "harness: 1 equals 2" || ok "harness: the assertions discriminate"
[ -f "$CFG" ] || { no "no config at $CFG"; fin; }
[ -f "$FL" ] || { sk "no flight.log - the daemon has not logged a loop"; fin; }

fl(){ tail -1 "$FL" 2>/dev/null | awk -F, -v n="$1" '{ gsub(/^[ \t]+|[ \t]+$/,"",$n); print $n }'; }
lvl(){ cat $BATT/capacity 2>/dev/null; }
plugged_now(){ [ "$(cat $BATT/present 2>/dev/null)" = 1 ]; }

GCSL=/sys/devices/platform/google,charger/charge_stop_level
[ -f "$GCSL" ] || GCSL=/sys/devices/platform/soc/soc:google,charger/charge_stop_level

# IS ACC HOLDING CHARGING OFF RIGHT NOW?
#
# chDisabledByAcc is the SWITCH path's ownership flag. A firmware-limit phone never sets it: there
# is no switch to own, the limit is handed to the firmware as charge_stop_level and the daemon's
# flag stays false the whole time. Grading a Pixel on field 7 alone reports "never paused" while
# the pack is demonstrably held - and worse, the release arms then pass for the wrong reason,
# because the flag was false before the arm started too.
#
# So: paused means EITHER the switch flag is set, OR a level node sits at or under the pack.
paused_now(){
  [ "$(fl 7)" = true ] && return 0
  [ "$(cat $BATT/input_suspend 2>/dev/null)" = 1 ] && return 0
  _psl=$(cat "$GCSL" 2>/dev/null); _plv=$(lvl)
  case "${_psl:-x}${_plv:-x}" in *x*) return 1;; esac
  [ "$_psl" -le "$_plv" ] 2>/dev/null
}
# ...and the class, so the report says which mechanism was under test.
if [ -f "$GCSL" ]; then CLASS="firmware level ($GCSL)"; else CLASS="switch"; fi

_st=$(fl 4); _lv=$(lvl); _tp=$(fl 12)
echo "  -- $(getprop ro.product.device): level ${_lv}% status=${_st} temp=${_tp} paused=$(fl 7)"
case "${_lv:-x}" in ''|*[!0-9]*) no "cannot read the battery level"; fin;; esac
case "${_tp:-x}" in ''|*[!0-9]*) no "flight.log carries no temperature field"; fin;; esac
plugged_now || { sk "cable is OUT - this suite drives a live charger and needs it IN"; fin; }
[ "${_lv}" -ge 15 ] 2>/dev/null || { sk "level ${_lv}% is too low to rehearse a cut"; fin; }
[ "${_lv}" -le 90 ] 2>/dev/null || { sk "level ${_lv}% leaves no headroom above the limit"; fin; }

ORIG_C=$(grep -m1 '^capacity=' "$CFG")
ORIG_T=$(grep -m1 '^temperature=' "$CFG")
[ -n "$ORIG_C" ] && [ -n "$ORIG_T" ] || { no "could not capture the original capacity/temperature lines"; fin; }
echo "  -- original: $ORIG_C / $ORIG_T"
_oSd=$(echo "$ORIG_T" | sed 's/.*=(//;s/).*//' | cut -d' ' -f4)

restored=0
restore(){
  [ "$restored" = 0 ] || return 0
  restored=1
  sed -i "s|^capacity=.*|$ORIG_C|" "$CFG" 2>/dev/null || :
  sed -i "s|^temperature=.*|$ORIG_T|" "$CFG" 2>/dev/null || :
  $ACC -D restart >/dev/null 2>&1 || :
  _i=0; while [ $_i -lt 20 ]; do sleep 2; paused_now || break; _i=$((_i+2)); done
  _c=$(grep -m1 '^capacity=' "$CFG"); _t=$(grep -m1 '^temperature=' "$CFG")
  if [ "$_c" = "$ORIG_C" ] && [ "$_t" = "$ORIG_T" ]; then
    echo "  -- restored and verified: $_c / $_t"
  else
    echo "  -- RESTORE MISMATCH: got $_c / $_t"
  fi
}
trap 'echo "  -- interrupted"; restore; exit 2' HUP INT TERM
trap 'restore' EXIT

# Wait for the hold to reach a state. $1 = paused|running, $2 = seconds.
wait_hold(){
  _w=0
  while [ $_w -lt "$2" ]; do
    if [ "$1" = paused ]; then paused_now && return 0
    else paused_now || return 0; fi
    sleep 3; _w=$((_w + 3))
  done
  return 1
}
why(){ printf 'flag=%s input_suspend=%s stop_level=%s level=%s status=%s'   "$(fl 7)" "$(cat $BATT/input_suspend 2>/dev/null || echo n/a)"   "$(cat "$GCSL" 2>/dev/null || echo n/a)" "$(lvl)" "$(fl 4)"; }
# THE DAEMON MUST BE LOOPING, but eight seconds is not how you establish that.
#
# The idle nap is ten minutes. A healthy daemon that is simply napping writes nothing to flight.log
# for far longer than any sample this suite can afford, so a short liveness gate fails on a working
# phone - measured on bluejay immediately after a campaign restored the module and restarted the
# daemon. Aborting there reported "the daemon is not looping" about a daemon that then ran every arm
# correctly on the very next attempt.
#
# Liveness is therefore an ATTRIBUTION, not a gate. Note the epoch before each arm, and when an arm
# times out ask whether the log moved during it: if it did, the timeout is the product's answer; if
# it did not, the daemon never got a pass in and the suite says so rather than blaming the product.
# Each arm writes config through `acc -s`, which kicks the daemon out of its nap, so a healthy phone
# logs inside the arm wherever the nap happened to be.
_e0=$(fl 1)
[ -n "$_e0" ] \
  && ok "flight.log is readable (epoch $_e0); liveness is attributed per arm, not gated on an 8s sample" \
  || { no "flight.log carries no epoch - the daemon has never logged a pass"; fin; }
# $1 = the epoch captured before the arm.
blame(){
  _eNow=$(fl 1)
  if [ "${_eNow:-0}" = "${1:-0}" ]; then
    echo "the daemon logged NOTHING during this arm, so this is not a product verdict"
  else
    echo "the daemon logged during this arm (epoch ${1} -> ${_eNow}), so this is the product's answer"
  fi
}

# ---- ARM 1: move the capacity limit UNDER the pack. Charging must stop. --------------------------
_lv=$(lvl)
_p1=$(( _lv - 2 )); _r1=$(( _lv - 5 ))
echo "  -- ARM 1: level ${_lv}%, setting pause=${_p1} resume=${_r1}"
$ACC -s "pause_capacity=$_p1" "resume_capacity=$_r1" >/dev/null 2>&1 || :
_eA=$(fl 1)
_a1=0
if wait_hold paused 90; then
  _a1=1
  ok "ARM 1: charging held within 90s of the limit moving under the pack [$(why)]"
else
  no "ARM 1: not held after 90s with pause_capacity=${_p1} under a ${_lv}% pack [$(why)] - $(blame "$_eA")"
fi
# and the pause has to be PHYSICAL, not just a flag.
_is=$(cat $BATT/input_suspend 2>/dev/null)
_csl=$(cat /sys/devices/platform/google,charger/charge_stop_level 2>/dev/null)
[ -n "$_csl" ] || _csl=$(cat /sys/devices/platform/soc/soc:google,charger/charge_stop_level 2>/dev/null)
if [ "${_is:-}" = 1 ]; then
  ok "ARM 1: the cut is physical - battery/input_suspend=1"
elif [ -n "${_csl:-}" ] && [ "${_csl}" -le "${_lv}" ] 2>/dev/null; then
  ok "ARM 1: the cut is physical - charge_stop_level=${_csl} at or under the ${_lv}% pack"
else
  no "ARM 1: ACC says paused but no node shows it (input_suspend=${_is:-n/a} charge_stop_level=${_csl:-n/a})"
fi

# ---- ARM 2: move the limit back ABOVE the pack. Charging must resume. ----------------------------
_lv=$(lvl)
_p2=$(( _lv + 10 )); [ "$_p2" -le 100 ] || _p2=100
_r2=$(( _lv + 5 ));  [ "$_r2" -lt "$_p2" ] || _r2=$(( _p2 - 1 ))
echo "  -- ARM 2: level ${_lv}%, setting pause=${_p2} resume=${_r2}"
$ACC -s "pause_capacity=$_p2" "resume_capacity=$_r2" >/dev/null 2>&1 || :
# A release arm only means something if the previous arm actually held. Without this, "not held"
# reads as a pass here for the same reason it read as a pass before the class fix.
if [ "$_a1" = 0 ]; then
  no "ARM 2: skipped as a verdict - ARM 1 never held, so there was nothing to release"
elif _eB=$(fl 1); wait_hold running 120; then
  ok "ARM 2: the hold released within 120s of the limit moving back above the pack [$(why)]"
else
  no "ARM 2: still held after 120s with pause_capacity=${_p2} above a ${_lv}% pack [$(why)] - $(blame "${_eB:-0}")"
fi
_is=$(cat $BATT/input_suspend 2>/dev/null)
[ "${_is:-0}" = 0 ] \
  && ok "ARM 2: the input cut is released (input_suspend=${_is:-n/a})" \
  || no "ARM 2: input_suspend is still ${_is} after the resume"

# ---- ARM 3: move max_temp UNDER the pack temperature. The thermal hold must engage. --------------
_tp=$(fl 12); _tc=$(( _tp / 10 ))
_mt=$(( _tc - 2 )); _rt=$(( _mt - 2 )); _ct=$(( _mt - 3 ))
if [ "$_rt" -lt 20 ] 2>/dev/null; then
  sk "ARM 3/4: pack at ${_tc}C leaves no room for a band under it"
else
  echo "  -- ARM 3: pack ${_tc}C, setting cooldown=${_ct} max=${_mt} resume=${_rt}, shutdown untouched"
  $ACC -s "cooldown_temp=$_ct" "max_temp=$_mt" "resume_temp=$_rt" >/dev/null 2>&1 || :
  _nowSd=$(grep -m1 '^temperature=' "$CFG" | sed 's/.*=(//;s/).*//' | cut -d' ' -f4)
  [ "$_nowSd" = "$_oSd" ] \
    && ok "ARM 3: shutdown_temp is untouched at ${_nowSd}, as the standing rule requires" \
    || no "ARM 3: shutdown_temp moved ${_oSd} -> ${_nowSd} - this suite must never write it"
  _eC=$(fl 1)
  _a3=0
  if wait_hold paused 150; then
    _a3=1
    ok "ARM 3: the thermal hold engaged within 150s with max_temp ${_mt}C under a ${_tc}C pack [$(why) temp=$(fl 12)]"
  else
    no "ARM 3: no thermal hold after 150s with max_temp ${_mt}C under a ${_tc}C pack [$(why) temp=$(fl 12)] - $(blame "$_eC")"
  fi

  # ---- ARM 4: put the band back. The hold must release. -----------------------------------------
  echo "  -- ARM 4: restoring the original band"
  sed -i "s|^temperature=.*|$ORIG_T|" "$CFG" 2>/dev/null || :
  $ACC -D restart >/dev/null 2>&1 || :
  if [ "$_a3" = 0 ]; then
    no "ARM 4: skipped as a verdict - ARM 3 never engaged, so there was nothing to release"
  elif _eD=$(fl 1); wait_hold running 150; then
    ok "ARM 4: the thermal hold released within 150s once the band was back above the pack [$(why) temp=$(fl 12)]"
  else
    no "ARM 4: still held after 150s with the original band restored [$(why) temp=$(fl 12)] - $(blame "${_eD:-0}")"
  fi
fi

restore
# The restore is part of the verdict, not housekeeping: a suite that leaves a phone cut is worse
# than one that fails.
_c=$(grep -m1 '^capacity=' "$CFG"); _t=$(grep -m1 '^temperature=' "$CFG")
{ [ "$_c" = "$ORIG_C" ] && [ "$_t" = "$ORIG_T" ]; } \
  && ok "config restored exactly" || no "config not restored ($_c / $_t)"
_is=$(cat $BATT/input_suspend 2>/dev/null)
[ "${_is:-0}" = 0 ] && ok "nothing left cut" || no "input_suspend left at ${_is}"
fin
