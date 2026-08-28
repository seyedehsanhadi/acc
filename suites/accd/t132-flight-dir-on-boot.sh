#!/system/bin/sh
# t132 - the flight recorder must survive a boot with its log directory missing.
#
# WHAT WENT WRONG
#   `mkdir -p $dataDir/logs` runs only under _INIT, which is set by the -i flag - and that block
#   ends with `exec $0 $args`, re-execing WITHOUT -i, so the daemon proper never runs it.
#   service.sh, the boot path, passes no -i either. So a boot with $dataDir/logs absent never
#   recreates it, and every flight write is `>> ... 2>/dev/null || :`, which means the recorder
#   dies SILENTLY and PERMANENTLY: no heartbeat, no charge-decision history, no shutdown trace.
#
#   That is the log this project treats as the only honest signal that a daemon is looping, and
#   every liveness check in these suites reads it - so the failure also blinds the test rig.
#
#   Reproduced on a Mi A3: remove the directory and start via service.sh and it stays absent;
#   start via `accd --init` and it appears.
#
# NO CHARGER NEEDED.

ID=t132
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "missing $AD"; fin; }
_src=$(cat "$AD")

# Plain greps: toybox sed has no `,+N` address form, so an address-range extraction silently
# produced nothing here and failed a fix that was present. Match the line itself instead.
grep -q 'mkdir -p "$dataDir/logs"' "$AD"   && ok "the daemon ensures $dataDir/logs outside the -i block"   || no "nothing ensures $dataDir/logs outside the -i block - a boot without it kills the recorder"

# It has to run before SWITCH SELECTION, which is 35 one-second iterations per candidate and runs
# before ctrl_charging. Two earlier placements failed for exactly this: with no chargingSwitch
# configured, `ctrl_charging` never appeared in the daemon trace at all, so a guard in flight_rec
# or at the top of ctrl_charging never executed. Right after misc-functions.sh is sourced is the
# earliest point where $dataDir exists, so require the ensure within a few lines of it.
_srcln=$(grep -n 'misc-functions.sh' "$AD" | grep -v '^.*#' | tail -1 | cut -d: -f1)
_ensln=$(grep -n 'mkdir -p "$dataDir/logs"' "$AD" | head -1 | cut -d: -f1)
if [ -n "$_srcln" ] && [ -n "$_ensln" ] && [ "$_ensln" -gt "$_srcln" ] 2>/dev/null    && [ $(( _ensln - _srcln )) -lt 30 ] 2>/dev/null; then
  ok "the ensure sits just after dataDir is defined (lines $_srcln -> $_ensln), ahead of switch selection"
else
  no "the ensure is not adjacent to the dataDir definition (source=$_srcln ensure=$_ensln)"
fi

# ---- live ---------------------------------------------------------------------------------------
[ "$(id -u 2>/dev/null)" = 0 ] || { sk "not root"; fin; }
DD=/data/adb/vr25/acc-data
[ -d "$DD" ] || { sk "no data dir"; fin; }
SVC=/data/adb/modules/acc/service.sh
[ -f "$SVC" ] || { sk "no service.sh (module not installed)"; fin; }

# THIS SUITE IS DESTRUCTIVE: it stops the daemon and deletes the log directory. Put both back on
# every exit path, or an ordinary unit round leaves the phone with no charge control - which is
# exactly what happened the first time it ran inside one.
_t132_restore(){
  [ -d "$DD/logs" ] || mkdir -p "$DD/logs" 2>/dev/null || :
  sh "$SVC" >/dev/null 2>&1 || :
}
trap '_t132_restore; exit 130' INT TERM HUP
trap _t132_restore EXIT

for p in $(pgrep -f accd 2>/dev/null); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null); set -f; set -- $c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh) ;; *) continue;; esac
  case "${2:-}" in */accd.sh) kill "$p" 2>/dev/null;; esac
done
sleep 4
rm -rf "$DD/logs"

# PROVE THE SETUP LANDED, or this passes on a phone where the directory was never removed.
[ -d "$DD/logs" ] && { sk "could not remove the log directory"; fin; }
ok "staged: $DD/logs removed and every daemon stopped"

# Start the way BOOT does - no -i.
sh "$SVC" >/dev/null 2>&1
_w=0
while [ $_w -lt 90 ]; do
  [ -d "$DD/logs" ] && break
  sleep 5; _w=$((_w+5))
done

# THE DIRECTORY is the fix. flight.log itself cannot be required on a fixed deadline: with no
# chargingSwitch configured the daemon runs switch selection first, which is minutes of work
# before the first record, and that is correct behaviour rather than a fault.
if [ -d "$DD/logs" ]; then
  ok "the boot path recreated the log directory after ${_w}s"
else
  no "no log directory ${_w}s after a boot-path start - the recorder is silently dead"
  fin
fi

_sw=$(grep -E '^chargingSwitch=' "$DD/config.txt" 2>/dev/null)
case "$_sw" in
  'chargingSwitch=()'|'')
    sk "no switch configured, so the daemon is in switch selection and has not reached the recorder yet" ;;
  *)
    _w2=0
    while [ $_w2 -lt 120 ]; do
      [ -s "$DD/logs/flight.log" ] && break
      sleep 10; _w2=$((_w2+10))
    done
    [ -s "$DD/logs/flight.log" ]       && ok "the recorder is writing again (${_w2}s)"       || no "the directory exists but no record was written in ${_w2}s"
    ;;
esac
fin
