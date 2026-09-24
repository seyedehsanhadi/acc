#!/system/bin/sh
# A native thermal hold must bind BELOW the resume level too.
#
# When the pack is hotter than max_temp, sync_native_limit clamps the firmware levels so charging
# actually stops. If the pack is already below the resume level, clamping to `start` does nothing
# - the firmware happily charges up to start - so the hold has to come down to the CURRENT level
# instead. Getting this wrong is one of the three silent rc22 defects: the limit is simply absent
# below the resume level, and nothing says so.
#
# The mega2 mutation phase reproduces it by blanking the level read:
#   _tl=$(batt_cap 2>/dev/null)   ->   _tl=
# and reported "NO suite fails with the defect present. This is a real coverage hole."
# This suite is that missing detector. It evaluates the shipped clamp block itself, so it grades
# the real source text rather than a paraphrase of it.

ID=t-native-hold-below-resume
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=${AD:-$execDir/accd.sh}
[ -f "$AD" ] || { no "missing $AD"; fin; exit $?; }

# Lift the clamp block: from the level read to the `fi` at the SAME indent as its `if`.
# A naive /start/,/fi/ range would stop at the inner `fi` and grade half the logic.
BLOCK=$(awk '
  !f && /^[ \t]*_tl=/ {
    f = 1; ind = $0; sub(/[^ \t].*$/, "", ind); closer = ind "fi"; print; next
  }
  f { print; if ($0 == closer) exit }
' "$AD")

if [ -z "$BLOCK" ]; then
  no "could not lift the clamp block from accd.sh - no verdict"
  fin; exit $?
fi
case "$BLOCK" in
  *stop=*) : ;;
  *) no "lifted block never assigns stop - wrong block, no verdict"; fin; exit $?;;
esac

# $1 = battery level reported by batt_cap. Prints "stop start".
clamp() {
  _lvl=$1
  (
    # The stub must echo the level this CASE asked for. Writing `echo "$1"` here echoes
    # batt_cap's own (empty) argument instead, which reads as a blank level and makes a clean
    # tree look exactly like the defect.
    batt_cap(){ echo "$_lvl"; }
    start=70; stop=75
    eval "$BLOCK" >/dev/null 2>&1 || :
    echo "$stop $start"
  )
}

# --- 1: pack BELOW the resume level - the case the defect breaks -----------------------------
set -- $(clamp 50)
_stop=$1; _start=$2
case "${_stop:-x}${_start:-x}" in
  *x*) no "clamp produced no values at level 50 - no verdict"; fin; exit $?;;
esac
if [ "$_stop" = 50 ] && [ "$_start" = 49 ]; then
  ok "at level 50 with resume 70 the hold clamps to the pack (stop=50 start=49), so it binds"
else
  no "at level 50 the hold clamped to stop=$_stop start=$_start - above the pack, so the firmware keeps charging and the limit is absent below the resume level"
fi

# --- 2: pack AT or ABOVE the resume level - clamping to start is correct there ----------------
set -- $(clamp 80)
_stop2=$1; _start2=$2
if [ "$_stop2" = 70 ] && [ "$_start2" = 69 ]; then
  ok "at level 80 the hold clamps to the resume level (stop=70 start=69), which does hold"
else
  no "at level 80 the hold clamped to stop=$_stop2 start=$_start2, expected stop=70 start=69"
fi

# --- 3: stop and start must never be equal, or the firmware resumes after a 1% sag ------------
if [ "$_stop" != "$_start" ] && [ "$_stop2" != "$_start2" ]; then
  ok "stop and start are never equal, so a 1% sag cannot resume charging mid-hold"
else
  no "stop equals start in one of the cases - the firmware resumes the instant the pack loses 1%"
fi

fin
