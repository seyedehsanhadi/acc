#!/system/bin/sh
# The switch scanner must leave the phone charging and the daemon really running.
#
# THE THREE HOLES THIS CLOSES
#   mega2's mutation phase plants fourteen defects and reports which ones no suite catches. Three
#   went undetected on BOTH a Pixel 6a and a Mi A3, across two campaigns, all of them in
#   acc-switch-scan.sh's teardown path - the code that runs when a scan ends and is the last thing
#   standing between a scan and an uncapped or uncharging phone:
#
#     1. the daemon hand-off un-detached. daemon_ctrl ends in `exec accd`, so without setsid (or
#        nohup) and a background &, the daemon is a child in the dying scanner's session and goes
#        with it. The scan prints that charging is back under ACC control and there is no daemon.
#     2. the per-candidate restore given restore_all_on's filter, so a current node that write_off
#        drove to 0 is never put back. The phone cannot draw current, and every candidate measured
#        after it is measured on a phone that cannot charge - the scan corrupts its own results.
#     3. the daemon-back check reverted to a bare `pgrep -f accd.sh`. That pattern matches
#        `pkill -f .../accd.sh` and `start-stop-daemon -bx .../accd.sh -S`, which carry the path in
#        their own argv: the check greets the process tearing the daemon DOWN as proof it is up.
#
#   All three are silent in the way that matters - each one reports success - which is exactly why
#   no behavioural test caught them. These are source-shape assertions on the teardown path, so
#   they run anywhere, touch nothing, and fail the moment the shape regresses.
#
# NO HARDWARE. Reads acc-switch-scan.sh and nothing else.

ID=t-scan-teardown-contract
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
SS=${SS:-$execDir/acc-switch-scan.sh}
[ -f "$SS" ] || { no "missing $SS"; fin; exit $?; }

_src=$(sed 's/^[[:space:]]*#.*//' "$SS")

# --- 1: every daemon restart in the scanner is detached AND backgrounded ------------------------
# Both halves are load-bearing. setsid without & still blocks the exiting scanner on a process that
# never returns; & without setsid leaves the daemon in the dying session. Checked per call site, so
# adding an un-detached second one cannot hide behind a correct first one.
# No \s in the pattern chain: toybox grep does not support it, and a `grep -v '^\s*$'` filter here
# silently discarded every match, so this assertion failed on CLEAN source - a detector that fails
# on the thing it is meant to approve is worse than none.
_calls=$(printf '%s\n' "$_src" | grep -n '"\$ACCA" -D restart')
if [ -z "$_calls" ]; then
  no "no '\$ACCA -D restart' call in the scanner - the daemon hand-off is gone entirely"
else
  _bad=0; _n=0
  printf '%s\n' "$_calls" > /dev/null
  for _ln in $(printf '%s\n' "$_calls" | cut -d: -f1); do
    _n=$((_n+1))
    _line=$(printf '%s\n' "$_src" | sed -n "${_ln}p")
    case "$_line" in
      *setsid*|*nohup*) ;;
      *) _bad=$((_bad+1)); no "line $_ln restarts the daemon without setsid or nohup - it dies with the scanner: $(printf '%s' "$_line" | sed 's/^[[:space:]]*//')" ;;
    esac
    case "$_line" in
      *"&") ;;
      *) _bad=$((_bad+1)); no "line $_ln restarts the daemon in the foreground - the scanner blocks on a process that never returns" ;;
    esac
  done
  [ "$_bad" = 0 ] && ok "all $_n daemon restart call(s) are detached and backgrounded"
fi

# --- 2: the per-candidate restore puts back EVERY node it wrote ---------------------------------
# restore_all_on legitimately filters; restore_on must not. Extract restore_on alone so a filter
# living in its sibling cannot satisfy or break this.
_ron=$(printf '%s\n' "$_src" | sed -n '/^restore_on() {/,/^}/p')
if [ -z "$_ron" ]; then
  no "restore_on() not found in the scanner"
else
  if printf '%s\n' "$_ron" | grep -qE 'current_max|constant_charge_current|input_current'; then
    no "restore_on skips current nodes - a node driven to 0 by write_off is never restored, leaving the phone unable to draw current and every later candidate measured on a phone that cannot charge"
  else
    ok "restore_on restores every node it was given, current nodes included"
  fi
  printf '%s\n' "$_ron" | grep -qF '[ "$1" = "--" ]' \
    && ok "restore_on skips only the '--' separator" \
    || no "restore_on's separator skip has changed shape - check what else it now drops"
fi

# --- 3: the daemon-back check tests the daemon, not a substring ---------------------------------
# `pgrep -f accd.sh` inside the wait loop is the regression. daemon_alive exists precisely because
# pkill and start-stop-daemon carry that path in their own argv.
_wait=$(printf '%s\n' "$_src" | grep -E 'up=1' )
if [ -z "$_wait" ]; then
  no "no 'up=1' daemon-back wait loop found in the scanner"
else
  if printf '%s\n' "$_wait" | grep -q 'pgrep'; then
    no "the daemon-back check uses pgrep directly - it matches pkill and start-stop-daemon, so it reports 'restarted' against the process tearing the daemon down"
  else
    ok "the daemon-back check does not rely on a bare pgrep match"
  fi
  printf '%s\n' "$_wait" | grep -q 'daemon_alive' \
    && ok "the daemon-back check goes through daemon_alive" \
    || no "the daemon-back check no longer calls daemon_alive"
fi

# --- 4: daemon_alive still verifies the process shape -------------------------------------------
# The detectors above are only worth anything while daemon_alive itself is a real test.
_da=$(printf '%s\n' "$_src" | sed -n '/^_is_accd() {/,/^}/p')
if [ -z "$_da" ]; then
  no "_is_accd() not found - daemon_alive has nothing to verify a pid against"
else
  printf '%s\n' "$_da" | grep -q 'cmdline' \
    && ok "_is_accd reads the process cmdline rather than trusting a pattern match" \
    || no "_is_accd no longer reads cmdline - it cannot tell the daemon from a helper naming it"
  printf '%s\n' "$_da" | grep -qE 'accd\.sh\)' \
    && ok "_is_accd requires accd.sh to be the shell's script argument" \
    || no "_is_accd no longer requires accd.sh as the script argument"
fi

fin
