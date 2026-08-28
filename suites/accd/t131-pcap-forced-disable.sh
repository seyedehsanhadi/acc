#!/system/bin/sh
# t131 - a forced disable must actually stop charging on a percentage-cap device.
#
# WHAT WENT WRONG
#   For a `pcap` switch flip_sw resolves the OFF value to pause_capacity. A percentage cap only
#   stops charging once the level REACHES it, so that value cannot stop a phone sitting BELOW the
#   limit - which is every forced disable taken before the limit is reached: acc -d, and AccA's
#   "disable charging" button.
#
#   The write succeeds, so nothing looks wrong. sw_holds then waits its four firmware ticks,
#   charging legitimately continues, and disable_charging concludes the switch is broken:
#   unset_switch empties chargingSwitch and the daemon exits 7. The phone is left with NO charge
#   control at all until something restarts the daemon.
#
#   Reproduced on a Pixel 6a at 74% with pause_capacity 75: charge_stop_level went to 75, the
#   phone kept charging, and the only control the device has was thrown away. Every modern Pixel
#   has a percentage cap as its only switch, so this is reachable by a single button press.
#
#   Fix: when the current level is below pause_capacity, cap at the current level instead, so an
#   OFF always means "stop now". At or above the limit the value is pause_capacity as before.

ID=t131
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "missing $MF"; fin; }

_src=$(sed 's/^[[:space:]]*#.*//' "$MF")

# The pcap branch must consult the live level, not pause_capacity alone.
printf '%s' "$_src" | grep -q '_fsLvl' \
  && ok "the pcap OFF value reads the current level" \
  || no "the pcap OFF value is still pause_capacity alone - a forced disable below the limit destroys the switch"

# It must take the LOWER of the two, never the higher: capping above the current level is the bug.
_blk=$(printf '%s' "$_src" | grep -A6 '_fsLvl=')
case "$_blk" in
  *'-lt "$off"'*) ok "it takes the lower of the current level and pause_capacity" ;;
  *) no "the comparison does not pick the lower value" ;;
esac

# The ordinary pause path must be untouched: at or above the limit the value stays pause_capacity.
case "$_blk" in
  *'off=$_fsLvl'*) ok "only the below-the-limit case changes the value" ;;
  *) no "the current level is read but never used as the OFF value" ;;
esac

# ---- live ---------------------------------------------------------------------------------------
[ "$(id -u 2>/dev/null)" = 0 ] || { sk "not root"; fin; }
CFG=${config:-/data/adb/vr25/acc-data/config.txt}
_sw=$(grep -E '^chargingSwitch=' "$CFG" 2>/dev/null)
case "$_sw" in
  *pcap*|*stop_level*|*charge_control_limit*) ;;
  *) sk "this phone does not use a percentage-cap switch"; fin ;;
esac

PS=/sys/class/power_supply
_lvl=$(cat $PS/battery/capacity 2>/dev/null)
_pause=$(sed -n 's/^capacity=(//p' "$CFG" | tr -d ')' | awk '{print $4}')
case "${_lvl:-x}${_pause:-x}" in *[!0-9]*) sk "cannot read level/pause"; fin;; esac

if [ "$_lvl" -ge "$_pause" ] 2>/dev/null; then
  sk "level ${_lvl}% is at or above pause ${_pause}% - the broken case needs a level BELOW the limit"
  fin
fi
ok "staged: level ${_lvl}% is below pause ${_pause}%, which is the case that used to destroy the switch"

[ "$(cat $PS/usb/present 2>/dev/null)" = 1 ] || { sk "needs a cable to grade a real disable"; fin; }

A=/dev/.vr25/acc
[ -x "$A/acc" ] || { sk "no runtime link"; fin; }

"$A/acc" -d >/dev/null 2>&1
_w=0
while [ $_w -lt 60 ]; do
  _st=$(cat $PS/battery/status 2>/dev/null)
  [ "$_st" != Charging ] && break
  sleep 5; _w=$((_w+5))
done
_st=$(cat $PS/battery/status 2>/dev/null)
[ "$_st" != Charging ] \
  && ok "acc -d stopped charging below the limit after ${_w}s (status $_st)" \
  || no "acc -d left it Charging after ${_w}s - the cap did not go below the current level"

# And the switch must SURVIVE. This is the damage the bug actually did.
_sw2=$(grep -E '^chargingSwitch=' "$CFG" 2>/dev/null)
case "$_sw2" in
  chargingSwitch=\(\)|'') no "chargingSwitch was emptied - the phone has lost charge control" ;;
  *) ok "chargingSwitch survived the forced disable" ;;
esac
# RESTORE THE WAY A REAL PHONE IS SHAPED, THEN GRADE THE RESUME.
#
# Two things make a naive "acc -e then check Charging" wrong here, and neither is a defect:
#   - acc -e and acc -d stop the daemon by design, so asserting a daemon count straight after one
#     of them grades the CLI's documented behaviour as a fault.
#   - on this device charge_stop_level LATCHES stopped: writing the ON value (100) back does not
#     re-arm the charger, only charge_start_level does, and it is the daemon that manages that
#     pair. Measured here: stop_level=100 with status "Not charging" held for a full 60s.
# So bring the daemon back first, which is the state any real phone is in, and then require that
# charging recovers.
"$A/acc" -e >/dev/null 2>&1
sleep 5
sh /data/adb/modules/acc/service.sh >/dev/null 2>&1
sleep 20

_n=0
for p in $(pgrep -f accd 2>/dev/null); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null); set -f; set -- $c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh) ;; *) continue;; esac
  # A daemon FORKS: mksh subshells inherit the parent's cmdline, so a plain scan counts the
  # daemon and its child as two daemons. Measured on a Mi A3 - pid 29567 (ppid 1) holding the
  # lock, pid 29653 with ppid 29567, identical argv - and chased twice as a phantom second
  # daemon before the parent was checked. Skip any candidate whose parent is itself a daemon.
  case "${2:-}" in */accd.sh) ;; *) continue;; esac
      _pp=$(awk '{print $4}' /proc/$p/stat 2>/dev/null)
      if [ -n "$_pp" ] && [ -r "/proc/$_pp/cmdline" ]; then
        _pc=$(tr '\0' ' ' < /proc/$_pp/cmdline 2>/dev/null)
        case "$_pc" in *accd.sh*) continue;; esac
      fi
  _n=$((_n+1))
done
[ "$_n" = 1 ] && ok "the daemon is running again after the forced disable" || no "$_n daemons - expected 1"

# Below the pause level with the daemon back, the phone must charge again. At or above it,
# "Not charging" is the correct answer and asserting Charging would itself be the bug.
_lvl2=$(cat $PS/battery/capacity 2>/dev/null)
_pause2=$(sed -n 's/^capacity=(//p' "$CFG" | tr -d ')' | awk '{print $4}')
_w=0
while [ $_w -lt 60 ]; do
  _st3=$(cat $PS/battery/status 2>/dev/null)
  [ "$_st3" = Charging ] && break
  sleep 5; _w=$((_w+5))
done
_st3=$(cat $PS/battery/status 2>/dev/null)
if [ "${_lvl2:-0}" -ge "${_pause2:-101}" ] 2>/dev/null; then
  sk "level ${_lvl2}% is at the pause limit ${_pause2}%, so 'Not charging' is correct - resume is not gradeable here"
else
  [ "$_st3" = Charging ]     && ok "charging recovered after the forced disable (${_w}s, level ${_lvl2}% < pause ${_pause2}%)"     || no "still $_st3 after ${_w}s at ${_lvl2}% with pause ${_pause2}% - the phone cannot charge"
fi
fin
