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
# IA_ONLY=1 runs ONLY the live idle-avoidance section and the restore, for the case this round
# hits most often: the phone was too flat to observe idle avoidance when the round first ran.
#   su -c 'IA_ONLY=1 sh /data/local/tmp/plug/rc24-plugged-auto.sh'
# It never reboots, never flashes, and never leaves a limit applied.

set -u

# Declared before ANY mode branch. These lived inside the suite-loop section, which IA_ONLY skips,
# while the verdict block below reads them unconditionally -- so `IA_ONLY=1`, the very command the
# 2b skip message tells you to run, reached the verdict and died on "PASS: unbound variable".
PASS=0; FAIL=0; NOV=0; FAILED=""
ATTENDED="rc24-plugged-deep.sh rc24-plugged-9vramp.sh"
D=/data/adb/vr25/acc-data
A=/dev/.vr25/acc
P=/data/local/tmp/plug
LOG=$P/AUTO.log
mkdir -p $P 2>/dev/null || :

say(){ echo "$*"; }
hr(){ say ""; say "################ $* ################"; }

# ---- 0. clean slate -----------------------------------------------------------------------------
hr "0  CLEAN SLATE"
# Sparing only $$ is not enough. This script's own ancestors carry its name too: launched the
# documented way, `su -c 'sh .../rc24-plugged-auto.sh'`, the su process matches 'rc24-' and gets
# SIGKILLed by its own child, taking the session and the log with it. Walk the parent chain and
# spare all of it, so the sweep can only ever reach genuine strays.
_mine=" $$ "
_pp=$$
while [ "${_pp:-0}" -gt 1 ] 2>/dev/null; do
  _pp=$(awk '{print $4}' /proc/$_pp/stat 2>/dev/null) || break
  [ -n "${_pp:-}" ] || break
  _mine="$_mine$_pp "
done
for pat in preflight cpumeas runall 'rc24-' 'accd/t'; do
  for p in $(pgrep -f "$pat" 2>/dev/null); do
    case "$_mine" in *" $p "*) continue;; esac
    kill -9 "$p" 2>/dev/null || :
  done
done
sleep 2
say "stray test processes: $(pgrep -f 'preflight|cpumeas|runall|rc24-' 2>/dev/null | grep -c . || :)"
# The header of this file promises "a phone left capped or cut after an aborted round -> restores,
# then verifies". It did not. The snapshot failure was swallowed by `2>/dev/null || :`, so a
# restore from a file that was never written failed just as quietly, and there was no trap at all:
# Ctrl-C or a kill anywhere after section 2b left the test's own capacity policy live on the phone.
if ! cp $D/config.txt $P/config.autobak 2>/dev/null || [ ! -s $P/config.autobak ]; then
  say "ABORT: cannot snapshot $D/config.txt - refusing to run a round that rewrites it"
  exit 4
fi
_restore_cfg(){
  [ -s $P/config.autobak ] || return 0
  cp $P/config.autobak $D/config.txt 2>/dev/null || :
  $A/accd --init $D/config.txt >/dev/null 2>&1 || :
}
trap '_restore_cfg; exit 130' INT TERM HUP
trap _restore_cfg EXIT
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
if [ -z "${IA_ONLY:-}" ]; then
hr "2  usb/current_max LIFT EXPERIMENT"
say "Decides whether a 5000000 write renegotiates the port down, or whether the ~100mA collapse"
say "was the cable. Does NOT touch the cap-clear paths either way."
sh $P/lift-exp.sh 2>&1 || say "(lift experiment returned $?)"

# ---- 2b. idle-avoidance, live ---------------------------------------------------------------
# t125 proves the RULE off-hardware. This proves the phone acts on it: set the documented
# forever-plugged pair (pause 60 / resume 40, aiapc=false) and watch whether the level actually
# leaves the limit instead of parking at it. That parking is the reported symptom -- a phone stuck
# at 59% with exactly this config -- and it is what the removed `pause > 60` gate caused.
fi
hr "2b LIVE IDLE-AVOIDANCE (pause 60 / resume 40 / aiapc=false)"
_ia_lv=$($A/acca --state 2>/dev/null | sed -n 's/.*"capacityPct":\([0-9]*\).*/\1/p')
if [ "${_ia_lv:-0}" -lt 62 ]; then
  # This is the section that exercises the removed `pause > 60` gate in cap_idle_threshold, so a
  # silent SKIP here is the round quietly not testing its most important change. Record it as work
  # still owed, with the command to finish it, and surface that in the verdict.
  say "SKIP: level ${_ia_lv}% is not above a pause of 60 yet; nothing to observe."
  say "      This is the live check for the cap_idle_threshold change. Charge past 62% and run:"
  say "        su -c 'IA_ONLY=1 sh $P/rc24-plugged-auto.sh'"
  DEFERRED="  2b live idle-avoidance: needs >62%, was ${_ia_lv}% at round start"
else
  $A/acca -s shutdown_capacity=5 cooldown_capacity=101 resume_capacity=40 pause_capacity=60 >/dev/null 2>&1
  $A/acca -s allow_idle_above_pcap=false >/dev/null 2>&1
  say "config: $(grep -E '^capacity=|^allowIdleAbovePcap=' $D/config.txt | tr '
' ' ')"
  _ia0=$_ia_lv; _i=0
  while [ $_i -lt 12 ]; do
    sleep 30; _i=$(( _i + 1 ))
    _ia1=$($A/acca --state 2>/dev/null | sed -n 's/.*"capacityPct":\([0-9]*\).*/\1/p')
    _cur=$($A/acca --state 2>/dev/null | sed -n 's/.*"current_raw":\(-*[0-9]*\).*/\1/p')
    say "  t+$(( _i * 30 ))s level=${_ia1}% raw=${_cur}"
    [ "${_ia1:-0}" -lt "${_ia0:-0}" ] && break
  done
  if [ "${_ia1:-0}" -lt "${_ia0:-0}" ]; then
    say "RESULT: level fell ${_ia0}% -> ${_ia1}% - it is discharging toward resume, not parked."
  else
    say "RESULT: level did NOT fall in 6 minutes. Either this switch bypasses (phone runs off the"
    say "        charger, which is what aiapc=false exists to prevent) or idle-avoidance is not"
    say "        engaging. Check the flight log for cutByAcc and the switch that is in force."
  fi
  cp $P/config.autobak $D/config.txt 2>/dev/null || :
  $A/acc -D restart >/dev/null 2>&1 || :
  sleep 15
  say "restored: $(grep -E '^capacity=' $D/config.txt)"
fi

# ---- 3. the plugged suites ----------------------------------------------------------------------
if [ -z "${IA_ONLY:-}" ]; then
hr "3  PLUGGED SUITES"
# Two of these cannot run unattended, and that is not a defect in them: rc24-plugged-deep.sh waits
# up to 600s for an operator to plug a NAMED charger type, and rc24-plugged-9vramp.sh demands the
# phone START unplugged and then waits ten minutes for a 9V brick. On a round that begins already
# plugged they block for the full timeout, print no summary line, and land in the tally as NO
# VERDICT, which reads exactly like a failure. Twenty minutes of a round were being spent proving
# nothing. They are not dropped, they move to an attended pass and are named in the verdict, so the
# choice is explicit instead of being an unexplained pair of blanks.
for s in rc24-plugged.sh rc24-plugged-full.sh \
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

fi
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
say ""
say "NOT RUN - these need an operator at the cable and will block without one:"
for s in $ATTENDED; do say "  $s"; done
say "  run each on its own, watching the prompt:"
say "    su -c 'sh $P/rc24-plugged-deep.sh'     (asks which charger to plug, then waits)"
say "    su -c 'sh $P/rc24-plugged-9vramp.sh'   (must START unplugged, then plug a 9V QC/PD brick)"
if [ -n "${DEFERRED:-}" ]; then say ""; say "DEFERRED - not observable at this battery level:"; say "$DEFERRED"; fi
if [ "$FAIL" -eq 0 ] && [ "$NOV" -eq 0 ]; then
  say "PLUGGED ROUND: CLEAN"
else
  say "PLUGGED ROUND: NOT CLEAN - read the sections above"
fi
say "finished $(date '+%Y-%m-%d %H:%M:%S')"
