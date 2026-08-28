#!/system/bin/sh
# rc24-first-plug-discovery.sh - a VIRGIN install has no charging switch. Prove the first plug
# finds one, and that charge control actually works once it has.
#
#   su -c 'sh /data/local/tmp/suites/rc24-first-plug-discovery.sh'      # START UNPLUGGED
#
# WHY. Uninstalling wipes /data/adb/vr25, so a fresh install starts with no switch in the config.
# Until one is selected the phone has no charge control at all - it simply charges. Every other
# suite here has run against a config that already named a switch, so the selection path itself
# has never been graded. It is also the first thing a real new user hits.
#
# SELECTION IS LAZY, AND IT IS THE FIRST *PAUSE* THAT TRIGGERS IT, NOT THE FIRST PLUG. cycle_switches
# only runs when the daemon actually needs to cut, so a phone plugged in well below its limit sits
# with chargingSwitch=() indefinitely and nothing is wrong. Measured on a Mi A3: plugged at 51%
# with pause 75, no probe was attempted at all; dropping pause to 58 selected
# battery/input_suspend within 390s. So to grade this in bounded time, run it with the level
# close to pause_capacity, or lower pause_capacity first.
# Until one is discovered the phone has no charge control at all - it simply charges. Every other
# suite here has run against a config that already named a switch, so the discovery path itself has
# never been graded on either phone. It is also the first thing a real new user hits.

ID=rc24-first-plug
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
info(){ echo "  ....  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

PS=/sys/class/power_supply
DD=/data/adb/vr25/acc-data
A=/dev/.vr25/acc
CFG=$DD/config.txt
present(){ [ "$(cat $PS/usb/present 2>/dev/null)" = 1 ]; }
# The key is chargingSwitch, NOT switch. Reading the wrong name reported "no switch discovered
# after 600s - this phone has NO charge control" on a Pixel that had in fact found its firmware
# limit on the first plug, exactly as intended.
#
# A trailing " --" marks a LOCKED switch, one that has proven it holds the limit over sustained
# use (accd.sh ~1700). A virgin install discovers first and locks later, so its absence here is
# correct and must not be read as a half-configured switch.
sw(){ grep -E '^chargingSwitch=' "$CFG" 2>/dev/null | head -1; }
lvl(){ cat $PS/battery/capacity 2>/dev/null; }

echo "===== 0  PRECONDITION: unplugged, no switch ====="
[ "$(id -u)" = 0 ] || { no "not root"; fin; }
[ -f "$CFG" ] || { no "no config - the install did not initialise"; fin; }
if present; then
  sk "a cable is already attached - unplug and re-run so the FIRST plug is what gets graded"
  # CUTONLY only wants the hardware proof, and that one NEEDS the cable that disqualifies the
  # virgin check. Exiting here made CUTONLY unreachable on the very phone it was written for.
  [ "${CUTONLY:-0}" = 1 ] || fin
fi
ok "unplugged at $(lvl)%"
_sw0=$(sw)
case "$_sw0" in
  ''|chargingSwitch=|chargingSwitch=\(\)) ok "no switch configured yet, which is what a virgin install looks like" ;;
  *)
    # Not virgin, but the cut/release proof below is still worth running and is the half that
    # actually exercises hardware. CUTONLY=1 skips straight to it.
    sk "a switch is already configured ($_sw0) - this is not a virgin install"
    [ "${CUTONLY:-0}" = 1 ] || fin
    info "CUTONLY=1: running the cut/release proof against the existing switch"
    ;;
esac

echo
echo "===== 1  PLUG IN ====="
echo "  >>> PLUG IN A CHARGER NOW. <<<"
_w=0
while [ $_w -lt 900 ]; do present && break; sleep 2; _w=$((_w+2)); done
present || { no "no cable within 900s"; fin; }
ok "cable detected after ${_w}s"
info "$(cat $PS/usb/real_type 2>/dev/null || cat $PS/usb/usb_type 2>/dev/null) at $(( $(cat $PS/usb/voltage_now 2>/dev/null || echo 0) / 1000 ))mV"

echo
echo "===== 2  DISCOVERY ====="
# Discovery runs on the daemon's own schedule, and on a first plug it has to probe. Give it room,
# and report what it lands on rather than asserting a particular switch - the two test phones use
# different mechanisms (input-cut vs a firmware %-limit) and both are correct answers.
_w=0; _swN=
while [ $_w -lt 600 ]; do
  _swN=$(sw)
  case "$_swN" in ''|chargingSwitch=|chargingSwitch=\(\)) ;; *) break;; esac
  sleep 10; _w=$((_w+10))
done
case "$_swN" in
  ''|chargingSwitch=|chargingSwitch=\(\))
    no "no switch discovered after ${_w}s on the first plug - this phone has NO charge control"
    info "probe state: $(ls $DD/.probe-pending $DD/.probe-blacklist 2>/dev/null | tr '\n' ' ')"
    ;;
  *)
    ok "switch discovered after ${_w}s: $_swN"
    ;;
esac

echo
echo "===== 3  THE DISCOVERED SWITCH ACTUALLY CONTROLS CHARGING ====="
# A switch written into the config is a claim. Cutting and releasing it is the proof.
case "${_swN:-}" in ''|chargingSwitch=|chargingSwitch=\(\)) _nosw=1;; *) _nosw=0;; esac
if [ "$_nosw" = 1 ]; then
  sk "nothing discovered, so there is nothing to exercise"
else
  _st0=$(cat $PS/battery/status 2>/dev/null)
  info "status before: $_st0"
  "$A/acc" -d >/dev/null 2>&1
  sleep 8
  _st1=$(cat $PS/battery/status 2>/dev/null)
  _on1=$(cat $PS/usb/online 2>/dev/null)
  info "after acc -d: status=$_st1 online=$_on1"
  case "$_st1" in
    Charging) no "acc -d did not stop charging - the discovered switch does not work" ;;
    *) ok "acc -d stopped charging (status $_st0 -> $_st1)" ;;
  esac
  "$A/acc" -e >/dev/null 2>&1
  sleep 10
  _st2=$(cat $PS/battery/status 2>/dev/null)
  info "after acc -e: status=$_st2"
  case "$_st2" in
    Charging) ok "acc -e resumed charging" ;;
    *) no "acc -e did NOT resume charging (status $_st2) - the phone is left unable to charge" ;;
  esac
fi

echo
echo "===== 4  FINAL STATE ====="
info "switch : $(sw)"
info "status : $(cat $PS/battery/status 2>/dev/null)  level $(lvl)%  present=$(cat $PS/usb/present 2>/dev/null)"
_n=0
for p in $(pgrep -f accd 2>/dev/null); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null); set -f; set -- $c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh|busybox|*/busybox) ;; *) continue;; esac
  [ "${1##*/}" = busybox ] && shift
  # A daemon FORKS: mksh subshells inherit the parent's cmdline, so a plain scan counts the
  # daemon and its child as two daemons. Measured on a Mi A3 - pid 29567 (ppid 1) holding the
  # lock, pid 29653 with ppid 29567, identical argv - and chased twice as a phantom second
  # daemon before the parent was checked. Skip any candidate whose parent is itself a daemon.
  case "${2:-}" in */accd.sh|accd.sh) ;; *) continue;; esac
      _pp=$(awk '{print $4}' /proc/$p/stat 2>/dev/null)
      if [ -n "$_pp" ] && [ -r "/proc/$_pp/cmdline" ]; then
        _pc=$(tr '\0' ' ' < /proc/$_pp/cmdline 2>/dev/null)
        case "$_pc" in *accd.sh*) continue;; esac
      fi
  _n=$((_n+1))
done
# acc -d and acc -e STOP THE DAEMON BY DESIGN, so a bare count here grades documented CLI
# behaviour as a fault - it failed on both phones for that reason alone. Bring it back the way a
# real phone is, then require that it is running.
sh /data/adb/modules/acc/service.sh >/dev/null 2>&1
sleep 15
_n=0
for p in $(pgrep -f accd 2>/dev/null); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null); set -f; set -- $c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh|busybox|*/busybox) ;; *) continue;; esac
  [ "${1##*/}" = busybox ] && shift
  case "${2:-}" in */accd.sh|accd.sh) _n=$((_n+1));; esac
done
[ "$_n" = 1 ] && ok "the daemon is running again at exit" || no "$_n daemons at exit - expected 1"
fin
