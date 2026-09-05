#!/system/bin/sh
# t144 - a percentage-cap stop node is half of a PAIR, and the pair has an ordering rule.
#
# WHAT WENT WRONG
#   t131 fixed the OFF value: a forced disable below the limit caps at the current level instead
#   of pause_capacity. Correct, and still not enough. On google,charger the stop node is paired
#   with charge_start_level and the firmware requires stop > start STRICTLY.
#
#   Measured on a Pixel 6a at 52% with start=70: writing start=52 then stop=52 was REFUSED, stop
#   stayed at 80. Writing start=51 then stop=52 was accepted. The switch spec names only the stop
#   node, so the clamped OFF value was written, silently discarded by the firmware, and charging
#   carried on. sw_holds waited out its four ticks, disable_charging concluded the switch was
#   broken, unset_switch emptied chargingSwitch and the daemon exited 7 - the phone was left with
#   no charge control at all until something restarted it.
#
#   Every modern Pixel ships this pair as its only switch, so one press of the disable button
#   reached it. Fix: on OFF, lower the start node first and remember the original; on ON, put the
#   stop node back up first and then restore start. Only when the constraint is not already met.

ID=t144
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
TMPDIR=${TMPDIR:-/dev/.vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "missing $MF"; fin; }
_src=$(sed 's/^[[:space:]]*#.*//' "$MF")

printf '%s' "$_src" | grep -q 'charge_start_level' \
  && ok "flip_sw knows the stop node has a paired start node" \
  || no "flip_sw never mentions charge_start_level - a forced disable below the limit is discarded"

_blk=$(printf '%s' "$_src" | grep -B4 -A20 '_fsStart=' | head -60)
case "$_blk" in
  *'$flip = off'*) ok "the start node is only lowered on an OFF flip" ;;
  *) no "the start node is touched on ON flips too" ;;
esac
case "$_blk" in
  *'-le "$_fsCur"'*) ok "it acts only when the constraint is not already satisfied" ;;
  *) no "it rewrites the start node unconditionally, changing the ordinary pause path" ;;
esac
case "$_src" in
  *'.pcap-start'*) ok "the original start value is persisted for the restore" ;;
  *) no "nothing remembers the original start value - ON cannot put it back" ;;
esac

[ "$(id -u 2>/dev/null)" = 0 ] || { sk "not root"; fin; }
g=/sys/devices/platform/google,charger
[ -f $g/charge_start_level ] && [ -f $g/charge_stop_level ] \
  || { sk "this phone has no google,charger start/stop pair"; fin; }

export execDir TMPDIR
export dataDir=${dataDir:-/data/adb/vr25/acc-data}
export config=${config:-$dataDir/config.txt}
export PS=${PS:-/sys/class/power_supply}
. $execDir/logf.sh 2>/dev/null || :
. $execDir/misc-functions.sh 2>/dev/null || :
command -v flip_sw >/dev/null 2>&1 || { sk "flip_sw not loadable here"; fin; }

# The daemon re-asserts the native limit on its own tick, which lands between the write and the
# read often enough to make this suite lie. Park it for the live arms and put it back afterwards.
_accdWas=0
if pgrep -f accd >/dev/null 2>&1; then
  _accdWas=1
  $execDir/acc.sh -D stop >/dev/null 2>&1 || :
  sleep 3
fi
_s0=$(cat $g/charge_start_level); _p0=$(cat $g/charge_stop_level)
_restore(){ echo 100 > $g/charge_stop_level 2>/dev/null; sleep 1
            echo $_s0 > $g/charge_start_level 2>/dev/null; sleep 1
            echo $_p0 > $g/charge_stop_level 2>/dev/null
            rm -f $TMPDIR/.pcap-start 2>/dev/null
            [ $_accdWas = 1 ] && { setsid $execDir/acc.sh -D start >/dev/null 2>&1 </dev/null & } || :; }
trap '_restore' EXIT HUP INT TERM

echo 100 > $g/charge_stop_level; sleep 1; echo 70 > $g/charge_start_level; sleep 1
echo 80 > $g/charge_stop_level; sleep 1
rm -f $TMPDIR/.pcap-start
_lvl=$(batt_cap 2>/dev/null)
case ${_lvl:-x} in ''|*[!0-9]*) sk "cannot read the level"; fin;; esac
[ "$_lvl" -lt 70 ] 2>/dev/null || { sk "level ${_lvl}% is not below start 70 - the broken case needs it below"; fin; }

capacity=(5 101 70 80 false)
chargingSwitch=($g/charge_stop_level 100 pcap)

flip_sw off >/dev/null 2>&1; sleep 1
_st=$(cat $g/charge_stop_level); _sa=$(cat $g/charge_start_level)
[ "$_st" = "$_lvl" ] \
  && ok "the stop node accepted the live level ($_st) - before the fix the firmware discarded it" \
  || no "the stop node reads $_st, wanted $_lvl - the write was refused"
[ "$_sa" -lt "$_st" ] 2>/dev/null \
  && ok "start ($_sa) is strictly below stop ($_st), which is what the firmware requires" \
  || no "start=$_sa is not strictly below stop=$_st"
[ -f $TMPDIR/.pcap-start ] && ok "the original start was remembered" || no "the original start was not saved"

flip_sw on >/dev/null 2>&1; sleep 1
[ "$(cat $g/charge_stop_level)" = 100 ] && ok "ON put the stop node back to 100" || no "stop is $(cat $g/charge_stop_level) after ON"
[ "$(cat $g/charge_start_level)" = 70 ] && ok "ON restored the start node to 70" || no "start is $(cat $g/charge_start_level) after ON"
[ -f $TMPDIR/.pcap-start ] && no "the saved-start marker leaked past the restore" || ok "the saved-start marker was cleared"

# The OFF value is clamped to the live level whenever the level sits below the configured pause
# (that is t131's fix), so this arm has to build its window UNDER the current level or it grades
# the clamp instead of the pair guard. Derive it rather than hardcoding a charge state.
_lvl2=$(batt_cap 2>/dev/null)
case ${_lvl2:-x} in ''|*[!0-9]*) sk "cannot read the level for the untouched-path arm"; fin;; esac
[ "$_lvl2" -ge 12 ] 2>/dev/null || { sk "level ${_lvl2}% is too low to build a window below it"; fin; }
_pz=$(( _lvl2 - 5 )); _sz=$(( _pz - 5 ))
echo 100 > $g/charge_stop_level; sleep 1; echo $_sz > $g/charge_start_level; sleep 1
rm -f $TMPDIR/.pcap-start
capacity=(5 101 $_sz $_pz false)
flip_sw off >/dev/null 2>&1; sleep 1
[ "$(cat $g/charge_start_level)" = "$_sz" ] \
  && ok "start untouched when pause ${_pz}% already sits above start ${_sz}%" \
  || no "start became $(cat $g/charge_start_level) when the constraint was already satisfied"
[ "$(cat $g/charge_stop_level)" = "$_pz" ] \
  && ok "stop took the configured pause (${_pz}), the ordinary path is byte-for-byte unchanged" \
  || no "stop is $(cat $g/charge_stop_level), wanted $_pz"
[ -f $TMPDIR/.pcap-start ] && no "the fix fired on the ordinary path" || ok "no marker written on the ordinary path"

_restore; trap - EXIT HUP INT TERM
fin
