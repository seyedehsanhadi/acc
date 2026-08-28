#!/system/bin/sh
# t130 - per-plug markers must not survive a plug cycle the daemon SLEPT THROUGH.
#
# WHAT WENT WRONG
#   Every per-plug clear in accd.sh hangs off a loop pass that observes `! present`. That is not
#   guaranteed. Measured on a Mi A3, screen off: flight.log logged present=1, then present=1 again
#   93 SECONDS LATER, with the cable physically out for most of that window - sysfs read present=0
#   throughout and the waiting suite passed its own "no cable" preflight. The daemon never got a
#   pass while the cable was out, so nothing cleared, and .hvcontract plus .hvpeak from the
#   previous plug were still standing on the next one.
#
#   That is not cosmetic. A stale .hvcontract is the gate on rekick_usb (misc-functions.sh ~960),
#   so a genuinely collapsed new supply is refused the re-kick that would repair it - the exact
#   failure the latch was added to prevent, reached from the other direction.
#
#   Fix: a wall-clock gap larger than any nap the daemon asks for means plug continuity is unknown,
#   so the per-plug markers go. Safe on a false positive because the latch writer re-derives
#   .hvcontract from real_type on every plugged pass.
#
# WHY .hvkicked AND NOT .hvcontract. On a real high-voltage plug the writer re-creates .hvcontract
# and .hvpeak within one loop, which is the safety property - so neither can witness the clear.
# .hvkicked is only ever written by an actual re-kick, so it stays gone once dropped.

ID=t130
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "missing $AD"; fin; }

# ---- 1: source level ----------------------------------------------------------------------------
_src=$(sed 's/^[[:space:]]*#.*//' "$AD")

printf '%s' "$_src" | grep -q '_pgLast' \
  && ok "accd tracks the previous pass time (_pgLast)" \
  || no "no _pgLast - a slept-through plug cycle leaves the per-plug markers standing"

printf '%s' "$_src" | grep -q 'plugGapMax' \
  && ok "the gap threshold is tunable (plugGapMax)" \
  || no "the gap threshold is hardcoded"

# The guard must require present, or it would fire on the ordinary unplugged idle nap, where the
# block below it already does the clearing.
# grep -q, NOT an alternation: toybox grep has no \| and silently matches the literal instead.
printf '%s' "$_src" | grep -q '_pgNow - _pgLast' \
  && ok "the guard compares the wall-clock gap against the threshold" \
  || no "the gap comparison is missing"

# It must clear .hvcontract AND .hvpeak - the two that were caught surviving.
_g=$(printf '%s' "$_src" | grep -A3 '_pgNow - _pgLast')
case "$_g" in
  *".hvcontract"*) ok "the guard clears .hvcontract" ;;
  *) no "the guard does not clear .hvcontract, which is the gate on rekick_usb" ;;
esac
case "$_g" in
  *".hvpeak"*) ok "the guard clears .hvpeak" ;;
  *) no "the guard does not clear .hvpeak, so a stale peak makes a weak supply look negotiated" ;;
esac

# ---- 2: live ------------------------------------------------------------------------------------
[ "$(id -u 2>/dev/null)" = 0 ] || { sk "not root; skipping the live clear"; fin; }
T=/dev/.vr25/acc
[ -d "$T" ] || { sk "no runtime dir"; fin; }
PS=/sys/class/power_supply
[ "$(cat $PS/usb/present 2>/dev/null)" = 1 ] || { sk "needs a cable attached (the guard only fires while present)"; fin; }

CFG=${config:-/data/adb/vr25/acc-data/config.txt}
_bak=/data/local/tmp/.t130.cfg
cp "$CFG" "$_bak" 2>/dev/null || { sk "cannot back up the config"; fin; }
_undo(){ cp "$_bak" "$CFG" 2>/dev/null; rm -f "$_bak" 2>/dev/null; "$T/accd" --init "$CFG" >/dev/null 2>&1 || :; }

# PROVE THE DAEMON IS COMPLETING LOOP PASSES BEFORE GRADING ONE.
#
# The guard lives in the main loop. A daemon that is in SWITCH SELECTION has not reached that loop
# at all - selection is 35 one-second iterations per candidate and runs first - so the marker sits
# untouched and this suite reports "the guard never fired" against a build where it is present and
# correct. Seen on a Mi A3 with chargingSwitch=(): the suite failed while the daemon was busy and
# healthy, and the same suite passed twice on the same build minutes earlier.
#
# flight.log is the honest signal: a record appearing means a loop pass completed.
_FL=/data/adb/vr25/acc-data/logs/flight.log
_h0=$(wc -l < "$_FL" 2>/dev/null || echo 0)
_hw=0
while [ $_hw -lt 90 ]; do
  _h1=$(wc -l < "$_FL" 2>/dev/null || echo 0)
  [ "${_h1:-0}" -gt "${_h0:-0}" ] 2>/dev/null && break
  sleep 10; _hw=$((_hw+10))
done
if [ "${_h1:-0}" -le "${_h0:-0}" ] 2>/dev/null; then
  sk "the daemon completed no loop pass in ${_hw}s (switch selection, or not looping) - the guard cannot be graded"
  fin
fi
ok "the daemon is completing loop passes, so the guard is reachable"

# Drive the threshold to 1s through the config's own `:` hook, so ANY ordinary loop gap trips it.
printf '\n:; plugGapMax=1\n' >> "$CFG"
: > $T/.hvkicked 2>/dev/null

# PROVE THE SETUP LANDED, or the assertion below passes on a phone where the marker was never made.
[ -f $T/.hvkicked ] || { sk "could not stage .hvkicked"; _undo; fin; }
ok "staged .hvkicked with plugGapMax=1"

# 45s was too tight and made this flaky - it passed at 36s and failed at 45s on the same build.
# Plugged and holding at the pause level the loop turns over about every 25s, and the config
# re-source that picks up plugGapMax costs a pass of its own, so 45s is barely two passes. Give it
# a window measured against the slow cadence, and report how long it actually took.
_w=0
while [ $_w -lt 150 ]; do
  [ -f $T/.hvkicked ] || break
  sleep 3; _w=$((_w+3))
done

if [ -f $T/.hvkicked ]; then
  no "the daemon left .hvkicked standing for ${_w}s with plugGapMax=1 - the guard never fired"
  echo "        (flight records in that window: $(tail -60 /data/adb/vr25/acc-data/logs/flight.log 2>/dev/null | wc -l) - if this is 0 the daemon was not looping and the result says nothing)"
else
  ok "the daemon dropped the per-plug marker after ${_w}s once the gap exceeded the threshold"
fi

_undo
fin
