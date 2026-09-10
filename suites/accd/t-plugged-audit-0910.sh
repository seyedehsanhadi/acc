#!/system/bin/sh
# The four findings of the 2026-09-10 plugged audit, isolated and executed.
#
# 1. mksh has no ${array[*]%pattern}: it is a fatal "bad substitution" that ends the script.
#    Every occurrence sat on a switch-recovery path, so the daemon died exactly when it was
#    trying to rescue a switch that had stopped holding.
# 2. exxit restored the default current/voltage controls before it asked whether a capacity or
#    thermal hold was still in force.
# 3. The firmware refuses charge_start_level >= charge_stop_level, so a start of 100 is never
#    written and the pulse that is meant to resume never resumes.
# 4. sync_native_limit writes start before stop, so raising both leaves start behind.
#
# Nothing here writes a real sysfs node, touches the live config or signals the daemon.

ID=t-plugged-audit-0910
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=${AD:-$execDir/accd.sh}
[ -f "$AD" ] || { no "missing $AD"; fin; }

W=${TMPDIR_T:-/data/local/tmp}/t-plugged-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null

echo "--- 1. no array-slice trim survives anywhere in the daemon"
n=$(grep -cF 'chargingSwitch[*]%' "$AD" 2>/dev/null); [ -n "$n" ] || n=0
[ "$n" = 0 ] && ok "no ${chargingSwitch[*]}-style trim left in accd.sh" \
  || no "$n array-slice trims left: each one ends the daemon with 'bad substitution'"

echo "    ...and the construct really is fatal on this shell, not merely ugly"
cat > $W/fatal.sh <<'X'
sw=(battery/input_suspend 0 1 --)
echo "msg ${sw[*]% --}"
echo REACHED
X
r=$(/system/bin/sh $W/fatal.sh 2>/dev/null)
case "$r" in
  *REACHED*) no "this shell tolerates the array trim, so section 1 cannot grade anything" ;;
  *) ok "the array trim aborts the shell here, so the grep above is a real contract" ;;
esac

echo "    ...and the scalar form the daemon now uses keeps the switch text"
cat > $W/good.sh <<'X'
sw=(battery/input_suspend 0 1 --)
t="${sw[*]}"
echo "[${t% --}]"
echo REACHED
X
r=$(/system/bin/sh $W/good.sh 2>/dev/null)
case "$r" in
  *"[battery/input_suspend 0 1]"*REACHED*) ok "the scalar trim drops the ' --' and runs on" ;;
  *) no "the scalar trim did not produce the switch text: $r" ;;
esac

echo "    ...and each recovery branch that reports a dropped switch still runs to its end"
for m in swclear-unsolicited swclear-lockfail resume-reselect; do
  l=$(grep -F "$m" "$AD" | grep -F 'ACC dropped\|is not resuming' | head -1)
  [ -n "$l" ] || l=$(grep -F "$m" "$AD" | head -1)
  ( chargingSwitch=(battery/input_suspend 0 1 --)
    capacity=(5 101 70 75 false)
    _swText="${chargingSwitch[*]}"
    warn_once_per(){ shift 2; printf '%s\n' "$*"; }
    command(){ return 0; }
    eval "$l" >/dev/null 2>&1 || exit 1
    exit 0 )
  [ $? -eq 0 ] && ok "$m reports its dropped switch without ending the daemon" \
    || no "$m still aborts when it fires"
done

echo "--- 2. a restart must not hand back the default controls while a hold is in force"
# The exit path is graded by its order: the restore has to sit behind the same guard that
# already withholds enable_charging, not in front of it.
g=$(grep -n '_ge_pause_cap 2>/dev/null || _temp_hold 2>/dev/null' "$AD" | head -1 | cut -d: -f1)
a=$(grep -n '^ *apply_on_plug default$' "$AD" | head -1 | cut -d: -f1)
if [ -z "$g" ]; then
  no "no pause/thermal guard found on the exit path"
  no "no pause/thermal guard found on the exit path"
elif [ -n "$a" ] && [ "$a" -lt "$g" ]; then
  no "apply_on_plug default runs at line $a, before the hold guard at $g: a restart un-caps the charge"
  no "the guarded exit line does not carry the restore"
else
  ok "no unguarded apply_on_plug default remains on the exit path"
  grep -q 'then :; else apply_on_plug default; enable_charging; fi' "$AD" \
    && ok "the restore is inside the same else-branch as enable_charging" \
    || no "the restore is not on the guarded branch"
fi

echo "--- 3. the firmware start level is clamped to something the kernel will accept"
grep -qF '[ "$start" -le 99 ] || start=99' "$AD" \
  && ok "start clamps to 99, below the highest stop the node accepts" \
  || no "start still clamps to 100, which charge_start_level always refuses"

echo "    ...and a node with the kernel's own rule proves why"
mkdir -p $W/psy
echo 75 > $W/psy/charge_stop_level; echo 70 > $W/psy/charge_start_level
# A stand-in for the driver: it refuses any start that is not below the current stop.
nwrite(){ # $1 node $2 value
  case ${1##*/} in
    charge_start_level) [ "$2" -lt "$(cat $W/psy/charge_stop_level)" ] || return 1 ;;
  esac
  echo "$2" > "$1"
}
nwrite $W/psy/charge_start_level 100 2>/dev/null \
  && no "the fixture accepted start=100, so it does not model the driver" \
  || ok "start=100 is refused while stop is 75, as measured on the device"

echo "--- 4. the resume pulse raises the stop before it raises the start"
sl=$(grep -n 'echo 100 > \$gcsl' "$AD" | head -1 | cut -d: -f1)
st=$(grep -n 'echo 99 > \$gcst' "$AD" | head -1 | cut -d: -f1)
if [ -n "$sl" ] && [ -n "$st" ] && [ "$sl" -lt "$st" ]; then
  ok "the pulse writes stop=100 first, then start=99"
else
  no "the pulse still writes start before stop, or still writes start=100"
fi
# ...replayed against the fixture, in the order the file actually has them.
echo 75 > $W/psy/charge_stop_level; echo 70 > $W/psy/charge_start_level
if [ -n "$sl" ] && [ -n "$st" ] && [ "$sl" -lt "$st" ]; then
  nwrite $W/psy/charge_stop_level 100 2>/dev/null || :
  nwrite $W/psy/charge_start_level 99 2>/dev/null || :
else
  nwrite $W/psy/charge_start_level 100 2>/dev/null || :
  nwrite $W/psy/charge_stop_level 100 2>/dev/null || :
fi
r="$(cat $W/psy/charge_stop_level)/$(cat $W/psy/charge_start_level)"
[ ".$r" = .100/99 ] && ok "the shipped order leaves the node unrestricted and armed to resume: $r" \
  || no "the shipped order left the node at $r, so the pulse cannot resume"

echo "--- 5. raising both levels must not leave the start behind"
grep -A2 -F 'if [ "$(cat $gcst 2>/dev/null)" = "$start" ]; then :; else' "$AD" | tail -20 >/dev/null
n=$(grep -cF 'if [ "$(cat $gcst 2>/dev/null)" = "$start" ]; then :; else' "$AD")
[ "$n" -ge 2 ] && ok "the start write is retried after the stop write" \
  || no "the start write happens once, before the stop: raising both strands the start"
echo 60 > $W/psy/charge_stop_level; echo 55 > $W/psy/charge_start_level
start=80; stop=85
nwrite $W/psy/charge_start_level $start 2>/dev/null || :
nwrite $W/psy/charge_stop_level $stop 2>/dev/null || :
[ "$n" -ge 2 ] && { [ "$(cat $W/psy/charge_start_level)" = "$start" ] || nwrite $W/psy/charge_start_level $start 2>/dev/null || :; }
r="$(cat $W/psy/charge_stop_level)/$(cat $W/psy/charge_start_level)"
[ ".$r" = .85/80 ] && ok "raising 60/55 to 85/80 lands both levels: $r" \
  || no "raising 60/55 to 85/80 left the node at $r"

rm -rf "$W" 2>/dev/null
fin
