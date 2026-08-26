#!/system/bin/sh
# rc24-plugged-auto.sh - the whole plugged round, unattended, on ONE phone.
#
#   su -c 'sh /data/local/tmp/plug/rc24-plugged-auto.sh' > /data/local/tmp/plug/AUTO.log 2>&1
#
# Everything is written to ONE log with a verdict block at the end, so nothing has to be watched
# while it runs and no result depends on a shell staying connected.
#
# WHAT THIS EXISTS TO PREVENT (all measured, all in one session):
#   * stale processes from an earlier run measuring at the same time  -> kills them first
#   * a suite left mid-run mutating the config                        -> snapshots and restores
#   * a "result" produced against code that never deployed            -> records file hashes
#   * a verdict read off a window shorter than the daemon's cadence   -> waits for real evidence
#   * a phone left capped or cut after an aborted round               -> restores, then verifies
#
# It never reboots, never flashes, and never leaves a limit applied.

set -u
D=/data/adb/vr25/acc-data
A=/dev/.vr25/acc
P=/data/local/tmp/plug
LOG=$P/AUTO.log
mkdir -p $P 2>/dev/null || :

say(){ echo "$*"; }
hr(){ say ""; say "################ $* ################"; }

# ---- 0. clean slate -----------------------------------------------------------------------------
hr "0  CLEAN SLATE"
for pat in preflight cpumeas runall 'rc24-' 'accd/t'; do
  for p in $(pgrep -f "$pat" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    kill -9 "$p" 2>/dev/null || :
  done
done
sleep 2
say "stray test processes: $(pgrep -f 'preflight|cpumeas|runall|rc24-' 2>/dev/null | grep -c . || :)"
cp $D/config.txt $P/config.autobak 2>/dev/null || :
say "config snapshot : $(grep -E '^capacity=' $P/config.autobak)"
say "daemon          : $($A/acc -D 2>&1 | tail -1)"
say "build fingerprint:"
for f in accd.sh misc-functions.sh acca.sh state-export.sh cfg-guard.sh; do
  say "  $(md5sum /data/adb/vr25/acc/$f 2>/dev/null)"
done

# ---- 1. must be charging ------------------------------------------------------------------------
hr "1  PRECONDITION"
_st=$($A/acca --state 2>/dev/null)
_pl=$(printf '%s' "$_st" | sed -n 's/.*"plugged":\([a-z]*\).*/\1/p')
_lv=$(printf '%s' "$_st" | sed -n 's/.*"capacityPct":\([0-9]*\).*/\1/p')
say "plugged=$_pl level=${_lv}%"
if [ "$_pl" != true ]; then
  say "ABORT: not plugged in. The whole point of this round is a live supply."
  exit 2
fi
if [ "${_lv:-100}" -ge 95 ]; then
  say "WARN: ${_lv}% is too full to observe a charge ramp; results will be taper-limited."
fi

# ---- 2. the lift experiment, FIRST, while the pack still pulls hard ------------------------------
hr "2  usb/current_max LIFT EXPERIMENT"
say "Decides whether a 5000000 write renegotiates the port down, or whether the ~100mA collapse"
say "was the cable. Does NOT touch the cap-clear paths either way."
sh $P/lift-exp.sh 2>&1 || say "(lift experiment returned $?)"

# ---- 3. the plugged suites ----------------------------------------------------------------------
hr "3  PLUGGED SUITES"
PASS=0; FAIL=0; NOV=0; FAILED=""
for s in rc24-plugged.sh rc24-plugged-full.sh rc24-plugged-deep.sh rc24-plugged-9vramp.sh \
         rc24-limits-hardcore.sh rc24-repair-path.sh rc24-mcv-oscillation.sh \
         rc24-weak-supply.sh rc24-weak-supply2.sh fastcharge-audit.sh \
         rc24-acc-vs-thermal.sh rc24-thermal.sh; do
  [ -f "$P/$s" ] || { say "-- $s : not staged, skipped"; continue; }
  say ""
  say "---- $s ----"
  out=$(execDir=/data/adb/vr25/acc sh "$P/$s" 2>&1)
  printf '%s\n' "$out" | grep -E '^  (FAIL|SKIP)' || :
  v=$(printf '%s\n' "$out" | grep -E '^[a-zA-Z0-9_-]+: [0-9]+ passed' | tail -1)
  if [ -n "$v" ]; then
    say "  => $v"
    p=$(printf '%s' "$v" | sed -n 's/.*: \([0-9]*\) passed.*/\1/p')
    f=$(printf '%s' "$v" | sed -n 's/.*passed, \([0-9]*\) failed.*/\1/p')
    PASS=$(( PASS + ${p:-0} )); FAIL=$(( FAIL + ${f:-0} ))
    [ "${f:-0}" -gt 0 ] && FAILED="$FAILED $s"
  else
    say "  => NO VERDICT LINE"
    NOV=$(( NOV + 1 )); FAILED="$FAILED $s(noverdict)"
  fi
  # After every suite: put the config back and make sure nothing is left holding the charge.
  cp $P/config.autobak $D/config.txt 2>/dev/null || :
done

# ---- 4. restore and PROVE it -------------------------------------------------------------------
hr "4  RESTORE AND VERIFY"
cp $P/config.autobak $D/config.txt 2>/dev/null || :
$A/acc -D restart >/dev/null 2>&1 || :
sleep 20
say "config now : $(grep -E '^capacity=' $D/config.txt)"
say "mcc/mcv    : $(grep -E '^maxCharging' $D/config.txt | tr '\n' ' ')"
say "daemon     : $($A/acc -D 2>&1 | tail -1)"
# The daemon must be LOOPING, not merely reporting alive. flight.log is the only honest heartbeat,
# and the idle nap can exceed 160s, so wait properly rather than sampling once.
_h0=$(tail -1 $D/logs/flight.log 2>/dev/null | cut -d, -f1)
_i=0
while [ $_i -lt 20 ]; do
  sleep 15; _i=$(( _i + 1 ))
  _h1=$(tail -1 $D/logs/flight.log 2>/dev/null | cut -d, -f1)
  [ "$_h1" != "$_h0" ] && break
done
if [ "${_h1:-}" != "${_h0:-}" ]; then
  say "heartbeat  : LOOPING (advanced after $(( _i * 15 ))s)"
else
  say "heartbeat  : NOT ADVANCING after 300s - investigate before trusting anything above"
fi
_st2=$($A/acca --state 2>/dev/null)
say "state      : $(printf '%s' "$_st2" | tr ',' '\n' | grep -E '"capacityPct"|"status"|"plugged"|"watts"' | tr -d '"' | tr '\n' ' ')"

# ---- 5. verdict ---------------------------------------------------------------------------------
hr "5  VERDICT"
say "suite assertions : $PASS passed, $FAIL failed, $NOV suites gave no verdict"
[ -n "$FAILED" ] && say "needs attention  :$FAILED"
if [ "$FAIL" -eq 0 ] && [ "$NOV" -eq 0 ]; then
  say "PLUGGED ROUND: CLEAN"
else
  say "PLUGGED ROUND: NOT CLEAN - read the sections above"
fi
say "finished $(date '+%Y-%m-%d %H:%M:%S')"
