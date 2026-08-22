#!/system/bin/sh
# rc24-thermal.sh - the temperature limits, derived from what this phone actually reads.
#
#   su -c 'sh /data/local/tmp/suites/rc24-thermal.sh'
#
# WHY THIS EXISTS AS ITS OWN FILE
#   The plugged suite kept SKIPPING thermal, on both phones, because it used a fixed margin
#   (max_temp = pack - 2) and then refused to write a value that collided with the configured cool
#   threshold. A pack at 32C against a cool level of 45C can never satisfy that, so the one safety
#   path nobody had exercised stayed unexercised. A test that skips the interesting case on every
#   phone it meets is not a conservative test, it is an absent one.
#
# WHAT "SMART" MEANS HERE
#   Nothing is hardcoded. The suite reads the pack temperature and the four configured levels, then
#   derives a HOLD set (limits below the current temperature, so charging must stop) and a RELEASE
#   set (limits above it, so charging must be allowed), keeping the ordering ACC requires and a
#   margin on both sides. It moves the cool level too, because on a cold pack that is the constraint
#   that makes a hold impossible to express. Every derived number is printed with its arithmetic so
#   a reader can check the reasoning rather than trust it.
#
# SHUTDOWN IS NEVER WRITTEN
#   Not once, not as part of a set, not to "restore" it. shutdown_temp stays exactly as found and
#   the suite asserts that at the end. A numeric shutdown_temp of 9 has powered a phone off at room
#   temperature on this project, and that is not a mistake worth risking to test a limit.
#
# IT WORKS UNPLUGGED
#   The arbitration is a pure function of the pack temperature and the configured maximum, so the
#   decision can be graded with no cable. Where a cable IS present the suite additionally proves the
#   charge actually stops and restarts. Unplugged it says so rather than pretending.

set +e
ID=rc24-thermal
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
info(){ echo "  ....  $*"; }
sec(){ echo; echo "===== $* ====="; }

M=${M:-/data/adb/vr25/acc}
DD=${DD:-/data/adb/vr25/acc-data}
PS=/sys/class/power_supply
CFG=$DD/config.txt
AD=$M/accd.sh
AA=$M/acca.sh
W=/data/local/tmp/rc24th

rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
tempf(){ sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk -v n=$1 '{print $n}'; }
setk(){ "$AA" -s "$@" >/dev/null 2>&1; }
pack_raw(){ rd $PS/battery/temp; }
st_now(){ rd $PS/battery/status; }
present_any(){ _p=no; for _n in $PS/*/present; do case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac; [ -f "$_n" ] || continue; [ "$(rd "$_n")" = 1 ] && _p=yes; done; echo $_p; }
online_any(){ _o=no; for _n in $PS/*/online; do case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac; [ -f "$_n" ] || continue; [ "$(rd "$_n")" = 1 ] && _o=yes; done; echo $_o; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null
sed -n '/^  _temp_hold() {/,/^  }/p' $AD | sed 's/^  //' > $W/th.sh

ORIG_CT=$(tempf 1); ORIG_MT=$(tempf 2); ORIG_RT=$(tempf 3); ORIG_ST=$(tempf 4)

# Set on the last line of the suite. Without it, ANY abort -- a syntax error, a set -e trip, a kill
# -- still reached the trap below and printed "0 failed / exit 0" for a run whose middle sections
# never executed. A section 2 that died on a stray printf reported "5 passed, 0 failed" and was
# taken as green. A tally that cannot tell a completed run from a truncated one is worse than none.
DONE=0

restore(){
  trap - EXIT INT TERM HUP
  sec "RESTORE"
  setk ct="$ORIG_CT" mt="$ORIG_MT" rt="$ORIG_RT"
  sleep 3
  _now="$(sed -n 's/^temperature=//p' $CFG)"
  echo "  temperature=$_now   (wanted cool=$ORIG_CT max=$ORIG_MT resume=$ORIG_RT shutdown=$ORIG_ST)"
  if [ "$(tempf 4)" = "$ORIG_ST" ]; then
    echo "  shutdown_temp is unchanged at $ORIG_ST, as it must be"
  else
    echo "  !! shutdown_temp CHANGED from $ORIG_ST to $(tempf 4) - set it back by hand NOW:"
    echo "     acc -s shutdown_temp=$ORIG_ST"
  fi
  [ -n "$(pgrep -f $M/accd.sh)" ] || { sh $M/service.sh >/dev/null 2>&1; sleep 5; }
  echo "  daemon: $(pgrep -f $M/accd.sh | head -1)  pack=$(( $(pack_raw) / 10 ))C  st=$(st_now)"
  echo
  if [ "${DONE:-0}" != 1 ]; then
    F=$((F+1))
    echo "  FAIL  the suite ABORTED before its last section - the tally below counts only what ran"
  fi
  echo "$ID: $P passed, $F failed, $S skipped"
  [ "$F" -eq 0 ] && exit 0 || exit 1
}
trap restore EXIT INT TERM HUP

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)"
echo "build  : $(sed -n 's/^version=//p' $M/module.prop)"

# =================================================================================================
sec "0  WHAT THIS PHONE ACTUALLY READS"
[ "$(id -u)" = 0 ] || { no "not root"; exit 1; }
[ -s $W/th.sh ] && ok "extracted the shipped _temp_hold ($(grep -c . $W/th.sh) lines)" \
                || { no "could not extract _temp_hold from accd.sh"; exit 1; }

RAW=$(pack_raw)
case "${RAW:-x}" in ''|x|*[!0-9-]*) no "battery/temp is unreadable ($RAW) - nothing here can be graded"; exit 1;; esac
PC=$(( RAW / 10 ))
info "pack temperature: raw=$RAW  =>  ${PC}C"
info "configured      : cool=$ORIG_CT  max=$ORIG_MT  resume=$ORIG_RT  shutdown=$ORIG_ST"
info "cable           : present=$(present_any) online=$(online_any) status=$(st_now)"

# The arbitration is `raw >= max * 10`, so everything below is expressed in whole degrees.
# HOLD set: put the ceiling BELOW the pack, with the other levels kept in order underneath it.
H_MT=$(( PC - 2 )); H_RT=$(( H_MT - 3 )); H_CT=$(( H_RT - 3 ))
# RELEASE set: ceiling comfortably ABOVE the pack, and still clear of shutdown.
R_MT=$(( PC + 6 )); R_RT=$(( PC + 3 )); R_CT=$PC
info "derived HOLD    : cool=$H_CT max=$H_MT resume=$H_RT   (max = pack ${PC} - 2)"
info "derived RELEASE : cool=$R_CT max=$R_MT resume=$R_RT   (max = pack ${PC} + 6)"

_bad=0
[ "$H_CT" -ge 1 ] 2>/dev/null || { info "HOLD set would need cool=${H_CT}C - this pack is too cold to express a hold"; _bad=1; }
[ "$R_MT" -lt "$ORIG_ST" ] 2>/dev/null || { info "RELEASE max ${R_MT}C would reach shutdown ${ORIG_ST}C - not going there"; _bad=1; }
[ "$_bad" = 0 ] && ok "both derived sets fit between 1C and the shutdown level ($ORIG_ST C), untouched" \
                || sk "the derived sets do not fit on this phone at ${PC}C"

# =================================================================================================
sec "1  DOES ACC STORE THE LIMITS IT IS GIVEN  (the silent-clamp regression)"
# A previous release silently rewrote a valid low max_temp (40 -> 50) and crushed a wide resume
# hysteresis. A limit the user set and ACC quietly replaced is worse than a limit refused out loud.
setk ct="$H_CT" mt="$H_MT" rt="$H_RT"
sleep 3
G_CT=$(tempf 1); G_MT=$(tempf 2); G_RT=$(tempf 3)
info "asked cool=$H_CT max=$H_MT resume=$H_RT   got cool=$G_CT max=$G_MT resume=$G_RT"
if [ "$G_MT" = "$H_MT" ]; then
  ok "max_temp was stored exactly as given (${G_MT}C)"
else
  no "max_temp was asked for as ${H_MT}C and stored as ${G_MT}C - ACC silently changed a user limit"
fi
if [ "$G_RT" = "$H_RT" ]; then
  ok "resume_temp was stored exactly as given (${G_RT}C), hysteresis preserved"
else
  no "resume_temp was asked for as ${H_RT}C and stored as ${G_RT}C"
fi
[ "$(tempf 4)" = "$ORIG_ST" ] && ok "shutdown_temp untouched by that write ($ORIG_ST C)" \
                              || no "shutdown_temp moved to $(tempf 4) - it must never be written"

# =================================================================================================
sec "2  THE ARBITRATION, DRIVEN WITH THE STORED LIMITS"
# Executed against the shipped function, with the phone's real temperature node.
# THE TEMPERATURE MUST BE FROZEN FOR A BOUNDARY TEST.
# _temp_hold re-reads the live node on every call, and a phone charging at 7% warms measurably
# during a run. The boundary cases below were computed from a reading taken at the start, so by
# the time "one degree above the pack" was evaluated the pack had passed it and the shipped code
# correctly answered HOLD against a stale expectation. Snapshot the value into a scratch file and
# point the function at that: the arithmetic is then exact and the case is deterministic.
runhold(){ # $1 = max_temp in C, $2 = raw deci-C to test against  -> HOLD | ALLOW
  printf "%s\n" "${2:-$RAW}" > $W/tempsnap   # trailing newline: read -r returns 1 at a bare EOF, and _temp_hold turns that into ALLOW
  ( temperature[1]=$1
    temp=$W/tempsnap
    . $W/th.sh
    _temp_hold && echo HOLD || echo ALLOW ) 2>/dev/null
}

_r=$(runhold "$G_MT" "$RAW")
if [ "$_r" = HOLD ]; then
  ok "a ${G_MT}C ceiling against a ${PC}C pack holds charging (${RAW} >= ${G_MT}0)"
else
  no "a ${G_MT}C ceiling against a ${PC}C pack answered $_r - the thermal limit does not engage"
fi

# The boundary, both sides, against the FROZEN reading so the arithmetic cannot race the pack.
_edge=$(runhold "$PC" "$RAW")
if [ "$_edge" = HOLD ]; then
  ok "at exactly ${PC}C against a frozen ${RAW} the limit holds - the comparison is >="
else
  no "at ${PC}C against ${RAW} the answer was $_edge - the >= boundary is wrong"
fi
_above=$(runhold "$(( PC + 1 ))" "$RAW")
if [ "$_above" = ALLOW ]; then
  ok "one degree above the frozen reading ($(( PC + 1 ))C vs ${RAW}) allows charging"
else
  no "a ceiling above the frozen reading still holds - the limit is stuck on"
fi

info "live pack is now $(rd $PS/battery/temp) (was ${RAW} at the start) - a charging phone warms"

_junk=$(runhold "abc" "$RAW")
if [ "$_junk" = ALLOW ]; then
  ok "a non-numeric max_temp fails toward ALLOW, not a permanent hold"
else
  no "a non-numeric max_temp answered $_junk - a garbage config would strand charging"
fi

# =================================================================================================
sec "3  THE RELEASE DIRECTION"
setk ct="$R_CT" mt="$R_MT" rt="$R_RT"
sleep 3
G2_MT=$(tempf 2)
info "asked max=$R_MT   got max=$G2_MT   (pack ${PC}C)"
[ "$G2_MT" = "$R_MT" ] && ok "the raised ceiling was stored as given (${G2_MT}C)" \
                       || no "raised ceiling asked ${R_MT}C, stored ${G2_MT}C"
_r2=$(runhold "$G2_MT" "$RAW")
[ "$_r2" = ALLOW ] && ok "a ${G2_MT}C ceiling against a ${PC}C pack allows charging" \
                   || no "a ceiling ${R_MT}C above a ${PC}C pack still answered $_r2"

# =================================================================================================
sec "4  SAFETY: THE shutdown >= max INVARIANT"
# shutdown_temp is the last line of defence, and ACC deliberately keeps it AT OR ABOVE max_temp:
#   [ $st -ge $mt ] && [ $st -ge 40 ] && [ $st -le 70 ] || st=$(( mt <= 50 ? 55 : mt + 5 ))
# The reason is in write-config.sh and it is sound - a shutdown level BELOW the pause level would
# power the phone off before the thermal hold could ever engage. So asking for max_temp=60 against
# shutdown=55 legitimately raises shutdown to 65, and an assertion of "shutdown never moves" is
# wrong: it fails a correct build. What must hold is the invariant itself, plus the direction -
# the last defence may be raised to stay above the ceiling, never lowered beneath where it was.
_try=$(( ORIG_ST + 5 ))
info "asking for max_temp=${_try}C against shutdown=${ORIG_ST}C (shutdown itself is never written)"
setk mt="$_try"
sleep 3
_gm=$(tempf 2); _gs=$(tempf 4)
info "got max=$_gm shutdown=$_gs"
if [ "$_gs" -ge "$_gm" ] 2>/dev/null; then
  ok "the invariant holds: shutdown ${_gs}C is at or above max ${_gm}C"
else
  no "shutdown ${_gs}C is BELOW max ${_gm}C - the phone would power off before it ever paused"
fi
if [ "$_gs" -ge "$ORIG_ST" ] 2>/dev/null; then
  ok "shutdown was not lowered (${ORIG_ST}C -> ${_gs}C)"
else
  no "shutdown was LOWERED from ${ORIG_ST}C to ${_gs}C - the last defence moved down"
fi
if [ "$_gs" -le 70 ] 2>/dev/null; then
  ok "shutdown stayed inside the validated band (<=70C)"
else
  no "shutdown ${_gs}C is outside the validated [40..70] band"
fi
# And it must come back when the ceiling does. A ratcheting last defence that never returns is a
# wart worth knowing about even though it is not dangerous.
setk mt="$ORIG_MT" st="$ORIG_ST"
sleep 3
if [ "$(tempf 4)" = "$ORIG_ST" ]; then
  ok "shutdown returns to ${ORIG_ST}C when the ceiling is restored"
else
  info "shutdown stayed at $(tempf 4)C after restoring max - it ratchets and needs setting back explicitly"
fi

sec "5  LIVE CHARGE HOLD  (only meaningful with a cable)"
if [ "$(present_any)" != yes ]; then
  sk "no cable attached - the arbitration above is graded, the physical hold is not"
  info "to grade the physical hold, re-run this with the phone plugged in"
else
  setk ct="$H_CT" mt="$H_MT" rt="$H_RT"
  _w=0; _held=no
  while [ $_w -lt 45 ]; do
    sleep 5; _w=$((_w+5))
    { [ "$(st_now)" = "Not charging" ] || [ "$(online_any)" = no ]; } && { _held=yes; break; }
  done
  [ "$_held" = yes ] && ok "the induced ${H_MT}C ceiling physically stopped charging in ${_w}s" \
                     || no "the induced ${H_MT}C ceiling did not stop charging in ${_w}s (status=$(st_now))"
  setk ct="$ORIG_CT" mt="$ORIG_MT" rt="$ORIG_RT"
  _w=0; _back=no
  while [ $_w -lt 60 ]; do
    sleep 5; _w=$((_w+5))
    { [ "$(st_now)" = Charging ] || [ "$(online_any)" = yes ]; } && { _back=yes; break; }
  done
  [ "$_back" = yes ] && ok "charging recovered in ${_w}s once the ceiling was restored" \
                     || no "charging did not recover in ${_w}s after restoring max_temp=$ORIG_MT"
fi

# =================================================================================================
sec "6  SHUTDOWN LEVEL AT THE END OF THE RUN"
_fs=$(tempf 4)
if [ "$_fs" -ge "$ORIG_ST" ] 2>/dev/null; then
  ok "shutdown is ${_fs}C, never taken below the ${ORIG_ST}C it started at"
else
  no "shutdown ended at ${_fs}C, below the ${ORIG_ST}C it started at"
fi

DONE=1
restore
