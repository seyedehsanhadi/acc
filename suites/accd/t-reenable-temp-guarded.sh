#!/system/bin/sh
# Every re-enable path must ask the thermometer first.
#
# _temp_hold returns TRUE while the pack is at or above max_temp, so the shipped idiom is
#     _temp_hold || enable_charging
# meaning "re-enable only if we are not too hot". Drop the guard and charging resumes above
# max_temp - the phone cooks while ACC believes it is protecting it. This is one of the defects
# the rc22 deep-fix chased across three separate re-enable paths.
#
# The mega2 mutation phase removes it everywhere at once:
#     _temp_hold || enable_charging   ->   enable_charging
# and reported "NO suite fails with the defect present. This is a real coverage hole."

ID=t-reenable-temp-guarded
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=${AD:-$execDir/accd.sh}
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AWKF=${AWKF:-$SELF/../xf.awk}
[ -f "$AD" ]   || { no "missing $AD"; fin; exit $?; }
[ -f "$AWKF" ] || { no "missing $AWKF"; fin; exit $?; }

# Comments are not code: a note describing the guard must not count as the guard.
_src=$(sed 's/^[[:space:]]*#.*//' "$AD")

# --- 1: every re-enable call is temperature-guarded -----------------------------------------
_total=$(printf '%s\n' "$_src" | grep -cE '(^|[^_[:alnum:]])enable_charging([^_[:alnum:]]|$)')
_guarded=$(printf '%s\n' "$_src" | grep -cE '_temp_hold[[:space:]]*\|\|[[:space:]]*enable_charging')
case "${_total:-x}${_guarded:-x}" in *x*) no "could not count enable_charging calls - no verdict"; fin; exit $?;; esac

if [ "$_guarded" -ge 2 ]; then
  ok "$_guarded re-enable paths are gated by _temp_hold"
else
  no "only $_guarded of $_total enable_charging calls are gated by _temp_hold - a re-enable path can resume charging above max_temp"
fi

# --- 2: _temp_hold itself must actually hold when hot ----------------------------------------
_body=$(awk -v fn=_temp_hold -f "$AWKF" "$AD" 2>/dev/null)
if [ -z "$_body" ]; then
  no "could not lift _temp_hold - no verdict"
  fin; exit $?
fi

# $1 = deci-degrees reported by the sensor. Prints HOLD (too hot) or GO.
verdict() {
  _t=$1
  (
    eval "$_body" >/dev/null 2>&1 || :
    temperature_now(){ echo "$_t"; }
    set -- 40 45 40 55
    temperature="$*"
    # shellcheck disable=SC2086
    eval 'temperature=(40 45 40 55)' 2>/dev/null || :
    _temp_hold && echo HOLD || echo GO
  )
}

_hot=$(verdict 470)    # 47.0 C, above max_temp 45
_cool=$(verdict 300)   # 30.0 C, well below

case "$_hot" in
  HOLD) ok "at 47.0C with max_temp 45 the guard holds, so no re-enable happens" ;;
  *) no "at 47.0C the guard said '$_hot' - charging would be re-enabled above max_temp" ;;
esac

case "$_cool" in
  GO) ok "control: at 30.0C the guard stands down, so charging can resume normally" ;;
  *) no "control: at 30.0C the guard said '$_cool' - it would never let charging resume" ;;
esac

fin
