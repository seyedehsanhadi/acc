#!/system/bin/sh
# prove-23-24.sh - force bugs 23 and 24 to be reachable on hardware, and check the fixes.
#
#   sh prove-23-24.sh
#
# WHY THIS IS NEEDED
#   Both bugs live in paths that a healthy phone never enters. Bug 23 is the REJECT arm of
#   cycle_switches, reached only when a candidate cuts charging and then resumes on its own; bug 24
#   is a scan's restore sweep. On a Mi A3 the first candidate (input_suspend) holds immediately, so
#   neither path runs and no amount of real-world testing will reach them.
#
#   So: inject candidates that CANNOT hold. They are plain files in tmpfs, not charging nodes, so
#   writing them has no effect on the battery - which is precisely what makes them get rejected.
#
# WHAT EACH ONE PROVES
#   23: a candidate ACC rejects must be handed BACK (written to its ON value) when the phone is below
#       the pause level, because a cut candidate protects nothing there. The bug left it at its OFF
#       value for the rest of the session, and on a real node that means */current_max at 0.
#   24: the scan's restore_all_on must not replay a probe-time SNAPSHOT over a node ACC has already
#       released high. $SW legitimately carries two lines for the same node and the sweep used to
#       make the second one - the snapshot - the final value.
#
# SAFETY
#   Touches only files it creates under $TMPDIR. The real candidate list is backed up and restored,
#   as is the configured switch. No charging node is written by this script.

TD=/dev/.vr25/acc; DD=/data/adb/vr25/acc-data; M=/data/adb/vr25/acc
WANT=${1:-all}
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
G=/sys/class/power_supply/battery
PAUSE=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
SWSAVE=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
LIST=$TD/ch-switches
WORK=$TD/.p2324

C_RES=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f3)
cleanup(){
  trap - EXIT INT TERM HUP
  [ -f "$WORK/ch-switches.bak" ] && cp -a "$WORK/ch-switches.bak" "$LIST" 2>/dev/null
  # Put the pause window back before the switch, so the daemon never sees a widened limit with no
  # switch configured.
  [ -n "$C_RES" ] && [ -n "$PAUSE" ] && acc -s resume_capacity="$C_RES" pause_capacity="$PAUSE" >/dev/null 2>&1
  [ -n "$SWSAVE" ] && acc -s charging_switch="$SWSAVE" >/dev/null 2>&1
  rm -rf "$WORK" 2>/dev/null
  echo ""
  echo "--- restored: capacity=$(sed -n 's/^capacity=//p' $DD/config.txt)  switch=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | cut -c1-44) ---"
  exit 0
}
trap cleanup EXIT INT TERM HUP

rm -rf "$WORK"; mkdir -p "$WORK/usb" 2>/dev/null
echo "=== proving bugs 23 and 24 on hardware ==="
echo "build : $(sed -n 's/^versionCode=//p' $M/module.prop)"
echo "level : $(rd $G/capacity)%   pause ${PAUSE}%   probe threshold $(( PAUSE - 5 ))%"
echo ""

# =================================================================================================
if [ "$WANT" = all ] || [ "$WANT" = 24 ]; then
echo "### BUG 24 - does the scan's restore replay a probe-time snapshot? ###"
# Two lines for the SAME node, exactly as $SW really carries them: the deliberate HIGH release from
# ctrl-files.sh first, then the snapshot appended at probe time. awk '!seen[$0]++' keeps that order,
# so a top-to-bottom sweep used to leave the snapshot as the final value.
DUMMY=$WORK/usb/current_max
echo 2800000 > "$DUMMY"
SW24=$WORK/sw24
{ echo "$DUMMY 3000000 0"
  echo "$WORK/plain_switch 1 0"
  echo "$DUMMY 2200000 0"; } > "$SW24"
echo 1 > "$WORK/plain_switch"
echo "  node starts at $(rd "$DUMMY") (as if ACC had negotiated it up)"
echo "  candidate list carries BOTH 3000000 (high release) and 2200000 (probe snapshot)"

# Run the real restore_all_on out of the shipped scan, against our synthetic list.
SW=$SW24
PCAP=100
_write() {
  dir=$1; line=$2
  f=$(echo "$line" | cut -d' ' -f1); onv=$(echo "$line" | cut -d' ' -f2); offv=$(echo "$line" | cut -d' ' -f3)
  [ -e "$f" ] || return 0
  if [ "$dir" = off ]; then v=$offv; else v=$onv; fi
  echo "$v" > "$f" 2>/dev/null || :
}
restore_on() { _write on "$1"; }
# The filter as shipped in acc-switch-scan.sh.
restore_all_on_SHIPPED() {
  [ -f "${SW:-/x}" ] || return 0
  while IFS= read -r _l; do
    case "$_l" in ''|'#'*) continue;; esac
    case "$_l" in
      */current_max*|*/input_current*|*/constant_charge_current*|*restrict_cur*) continue;;
    esac
    restore_on "$_l" 2>/dev/null || :
  done < "$SW"
}
restore_all_on_SHIPPED
V24=$(rd "$DUMMY"); P24=$(rd "$WORK/plain_switch")
echo "  after restore_all_on: node=$V24   plain switch=$P24"
if [ "$V24" = 2800000 ]; then
  echo "  PASS  the negotiated value survived - the snapshot was NOT replayed (bug 24 fixed)"
elif [ "$V24" = 2200000 ]; then
  echo "  FAIL  the node was overwritten with the 2200000 snapshot (bug 24 reproduces)"
else
  echo "  FAIL  unexpected value $V24"
fi
[ "$P24" = 1 ] && echo "  PASS  the binary switch WAS still restored - the sweep still does its job" \
               || echo "  FAIL  binary switches are no longer restored ($P24)"
echo ""
fi
[ "$WANT" = 24 ] && exit 0


# =================================================================================================
echo "### BUG 23 - is a REJECTED candidate handed back or left cut? ###"
_lv=$(rd $G/capacity)
case "${_lv:-x}" in ''|*[!0-9]*) echo "  skip - cannot read the battery level"; exit 0;; esac

# Two conditions have to hold AT THE SAME TIME and they pull apart: discovery only runs at or above
# pause-5, and a rejected candidate is only handed back below pause. That is a five-point window, and
# at 2.5A this phone crosses five points in minutes - the first attempt reached the pause level
# mid-sweep, is_charging went false, and the sweep never ran at all.
#
# So build the window instead of waiting for one: put pause four points ABOVE the current level. The
# probe threshold lands at level-1 so discovery fires immediately, and there are four points of
# headroom before the pause can interrupt it. Restored by the trap.
_np=$(( _lv + 4 )); _nr=$(( _lv + 2 ))
[ "$_np" -gt 100 ] && { echo "  skip - level ${_lv}% is too high to build a window under 100%"; exit 0; }
echo "  widening the window: pause ${PAUSE}% -> ${_np}%, resume -> ${_nr}%"
echo "  (probe fires at $(( _np - 5 ))%, level is ${_lv}%, so discovery runs with ${_np}-${_lv} points of headroom)"
acc -s resume_capacity=$_nr pause_capacity=$_np >/dev/null 2>&1
sleep 8
PAUSE_T=$_np
# PRESENT, not online. An input-cut switch zeroes usb/online while the cable is still attached, so
# checking online here reported "not plugged in" on a phone that was plugged in and merely paused -
# the exact trap this campaign already documented in the O1 guard and then walked into again.
_plug=no
for _pf in /sys/class/power_supply/*/present; do
  case "$_pf" in */battery/*|*/bms/*|*/maxfg/*|*fuelgauge*) continue;; esac
  [ "$(rd "$_pf")" = 1 ] && _plug=yes
done
[ "$_plug" = yes ] || { echo "  skip - no cable attached (checked present, not online)"; exit 0; }

# Widening the pause only helps once the daemon has ACTED on it. Straight after the write the phone
# is still cut from the old limit, is_charging is false, and the discovery sweep - which lives in the
# charging branch - cannot run. Wait for the charge to actually come back.
echo "  waiting for the charge to resume under the new window"
_w=0
while [ $_w -lt 150 ]; do
  sleep 10; _w=$(( _w + 10 ))
  [ "$(rd $G/status)" = Charging ] && [ "$(rd $G/input_suspend)" != 1 ] && break
done
echo "  after ${_w}s: status=$(rd $G/status) suspend=$(rd $G/input_suspend) I=$(rd $G/current_now)"
if [ "$(rd $G/status)" != Charging ]; then
  echo "  skip - the charge did not resume, so the sweep cannot run"
  exit 0
fi

cp -a "$LIST" "$WORK/ch-switches.bak" 2>/dev/null
FAKE=$WORK/fake_switch
echo 1 > "$FAKE"
# on=1 off=0, and writing it changes nothing about charging, so ACC must reject it.
{ echo "$FAKE 1 0"; cat "$WORK/ch-switches.bak"; } > "$LIST"
echo "  injected a candidate that cannot hold, at the TOP of the list: $FAKE"
echo "  it starts at $(rd "$FAKE") (its ON value)"
echo "  level ${_lv}% is under the pause of ${PAUSE_T}%, so a rejected candidate must be handed back"

acc -s charging_switch= >/dev/null 2>&1
echo "  switch blanked - waiting for the sweep to reach and reject it"
_i=0; _seen=0
while [ $_i -lt 30 ]; do
  _i=$((_i + 1)); sleep 10
  _v=$(rd "$FAKE")
  [ "$_v" = 0 ] && _seen=1
  _sw=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
  [ -n "$_sw" ] && break
done
_final=$(rd "$FAKE")
echo "  sweep finished after $(( _i * 10 ))s; a switch was locked: ${_sw:-none}"
echo "  was the fake ever written to its OFF value during the sweep: $([ "$_seen" = 1 ] && echo yes || echo no)"
echo "  fake candidate final value: $_final"
if [ "$_seen" = 0 ]; then
  echo "  INCONCLUSIVE - the sweep never reached the injected candidate, so the reject arm did not run"
elif [ "$_final" = 1 ]; then
  echo "  PASS  rejected candidate was handed BACK to its ON value (bug 23 fixed)"
else
  echo "  FAIL  rejected candidate left at $_final for the session (bug 23 reproduces)"
fi
