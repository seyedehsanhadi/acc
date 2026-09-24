#!/system/bin/sh
# t156 - a status of Unknown is not evidence that a switch failed.
#
# current_factor() answers "unknown" when the battery current is small and another supply node
# reads microamp-scale: a microamp phone holding in bypass right after a boot (battery -2000,
# input 450000) is exactly that. status() then reports Unknown and not_charging() is false, so
# the paused phone reads as "charging". Both switch watchdogs counted that as a breach and could
# blacklist a working automatic switch. Enforcement is unaffected by this guard: the pause branch
# still re-asserts the cut every loop. Only the destructive replace/drop decisions wait for a
# status that was actually measured.
ID=t156
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; exit $?; }

execDir=${execDir:-/data/adb/vr25/acc}
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AD=${AD:-$execDir/accd.sh}
BI=${BI:-$execDir/batt-interface.sh}
SE=${SE:-$execDir/state-export.sh}
AWKF=${AWKF:-$SELF/../xf.awk}
[ -f "$AWKF" ] || AWKF=$execDir/suites/xf.awk
for f in "$AD" "$BI" "$SE" "$AWKF"; do [ -f "$f" ] || { no "missing $f"; fin; }; done

_ad=$(sed 's/^[[:space:]]*#.*//' < "$AD" | tr '\n' ' ')
[ "${#_ad}" -gt 50000 ] || { no "harness: accd.sh lift truncated (${#_ad} bytes)"; fin; }

grade(){
  case "$1" in
    *'! not_charging && [ "${_status-}" != Unknown ] '*'sleep 2 && present'*'! not_charging && [ "${_status-}" != Unknown ]'*)
      echo guarded;;
    *) echo open;;
  esac
}
grade_unsol(){
  case "$1" in
    *'{ ! not_charging || { isCharging=false; false; }; }'*'&& [ "${_status-}" != Unknown ]'*) echo guarded;;
    *) echo open;;
  esac
}

[ "$(grade "$_ad")" = guarded ] && ok "breach watchdog ignores an Unknown status" || no "breach watchdog counts an Unknown status as a breach"
[ "$(grade_unsol "$_ad")" = guarded ] && ok "unsolicited-resume counter ignores an Unknown status" || no "unsolicited-resume counter counts an Unknown status"

# Mutant: the pre-fix text must grade open, or the assertions above prove nothing.
_mut=$(printf '%s' "$_ad" | sed 's/ \&\& \[ "${_status-}" != Unknown \]//g')
[ "$(grade "$_mut")" = open ] && ok "mutant (guard removed) is caught by the breach check" || no "breach check cannot fail"
[ "$(grade_unsol "$_mut")" = open ] && ok "mutant (guard removed) is caught by the unsolicited check" || no "unsolicited check cannot fail"

# The premise: current_factor really does answer unknown in the bypass-after-boot state.
W=${TMPDIR:-/data/local/tmp}/t156-$$; rm -rf "$W"; mkdir -p "$W/battery" "$W/usb"
( xf(){ awk -v fn="$1" -f "$AWKF" "$2"; }
  eval "$(xf _se_rd "$SE")"; eval "$(xf _se_int "$SE")"
  eval "$(xf current_now "$BI")"; eval "$(xf current_factor "$BI")"
  ACC_PSY=$W; currFile=$W/battery/current_now; ampFactor=
  echo -2000 > $W/battery/current_now; echo 450000 > $W/usb/input_current_now
  echo "f=[$(current_factor)]" ) > $W/out 2>&1
case "$(cat $W/out)" in
  'f=[]') ok "premise holds: bypass-after-boot unit is unknown";;
  *) no "premise changed: current_factor says $(cat $W/out) - re-evaluate this guard";;
esac
rm -rf "$W"
fin
