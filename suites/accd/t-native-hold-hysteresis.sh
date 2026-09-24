#!/system/bin/sh
# The native thermal hold must release at resume_temp, not at max_temp.
#
# The latch engages at max_temp and lifts at resume_temp, and the gap between them is the whole
# point: release at max_temp and the phone re-enables charging the instant it touches the limit,
# so it sits AT the set temperature charging forever instead of cooling down first.
#
# The mega2 mutation phase collapses the hysteresis by sourcing the release threshold from
# max_temp instead of resume_temp:
#   _rt=$(( ${temperature[2]:-40} * 10 ))   ->   _rt=$(( ${temperature[1]:-50} * 10 ))
# and reported "NO suite fails with the defect present. This is a real coverage hole."
#
# With temperature=(45 50 40 55) - max_temp 50, resume_temp 40 - the giveaway is 45.0C: still
# held on a clean tree, released by the mutant.

ID=t-native-hold-hysteresis
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=${AD:-$execDir/accd.sh}
[ -f "$AD" ] || { no "missing $AD"; fin; exit $?; }

# Lift from the engage threshold through the end of the latch chain. Anchor on _mt=, which both
# arms keep - anchoring on the mutated _rt= line would report "could not lift" for the mutant,
# which is a no-verdict dressed up as a failure.
_n=$(grep -n '^    _mt=$(( ${temperature\[1\]' "$AD" 2>/dev/null | head -1 | cut -d: -f1)
case "${_n:-x}" in
  ''|*[!0-9]*) no "could not locate the latch block in accd.sh - no verdict"; fin; exit $?;;
esac
BLOCK=$(awk -v s="$_n" 'NR>=s { print; if ($0 == "    fi") exit }' "$AD")
case "$BLOCK" in
  *_ntHot=1*_ntHot=0*) : ;;
  *) no "lifted block is not the latch chain - no verdict"; fin; exit $?;;
esac

# $1 = deci-degrees now, $2 = latch state coming in. Prints the latch state after.
latch() {
  _t_in=$1; _st=$2
  (
    eval 'temperature=(45 50 40 55)' 2>/dev/null || temperature="45 50 40 55"
    t=$_t_in; _ntHot=$_st
    eval "$BLOCK" >/dev/null 2>&1 || :
    echo "${_ntHot:-?}"
  )
}

# --- 1: engage at or above max_temp ----------------------------------------------------------
[ "$(latch 520 0)" = 1 ] \
  && ok "52.0C engages the hold (max_temp 50)" \
  || no "52.0C did not engage the hold - the limit never fires"

# --- 2: THE POINT. Inside the band the hold must STAY on --------------------------------------
_mid=$(latch 450 1)
if [ "$_mid" = 1 ]; then
  ok "45.0C keeps the hold engaged - it releases at resume_temp, not at max_temp"
else
  no "45.0C released the hold - charging resumes while still above resume_temp, so the phone sits at the set temperature charging"
fi

# --- 3: release at or below resume_temp -------------------------------------------------------
[ "$(latch 390 1)" = 0 ] \
  && ok "39.0C releases the hold (resume_temp 40)" \
  || no "39.0C did not release the hold - charging would never resume after a thermal pause"

# --- 4: an unreadable sensor must not move the latch either way -------------------------------
if [ "$(latch '' 1)" = 1 ] && [ "$(latch '' 0)" = 0 ]; then
  ok "an unreadable sensor holds the latch where it is, neither engaging nor releasing"
else
  no "an unreadable sensor moved the latch - a blind thermometer must not decide either way"
fi

fin
