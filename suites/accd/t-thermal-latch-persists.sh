#!/system/bin/sh
# The thermal latch must CARRY across daemon passes, not restart cold each time.
#
# The hysteresis band only exists because _ntHot survives from one pass to the next: it is read
# back from $TMPDIR/.nthot at loop start and written again at the end of the latch block. Reset
# it before the evaluation and the band becomes decorative - every pass starts cold, so a pack
# sitting at 45C between resume_temp 40 and max_temp 50 is treated as cool and charging resumes.
# The code still LOOKS like it has hysteresis; it just has none.
#
# The mega2 mutation phase inserts the reset immediately above the engage threshold:
#   _mt=$(( ... ))   ->   _ntHot=0
#                         _mt=$(( ... ))
# and reported "NO suite fails with the defect present. This is a real coverage hole."
#
# t-native-hold-hysteresis cannot see this: it injects the incoming latch state itself and lifts
# from _mt=, which is BELOW where the reset lands. This suite grades the persisted value instead,
# and starts its lift above the insertion point.

ID=t-thermal-latch-persists
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=${AD:-$execDir/accd.sh}
[ -f "$AD" ] || { no "missing $AD"; fin; exit $?; }

_TMPD0=${TMPDIR:-}
[ -d "${_TMPD0:-/nonexistent}" ] || _TMPD0=/data/local/tmp
[ -d "$_TMPD0" ] || _TMPD0=/tmp
[ -d "$_TMPD0" ] || _TMPD0=.

# Anchor on the persistence write - present in both arms - then walk BACK far enough to include
# anything injected above the engage threshold, and forward to the write itself.
_w=$(grep -n 'printf .*_ntHot:-0.* > \$TMPDIR/\.nthot' "$AD" 2>/dev/null | head -1 | cut -d: -f1)
case "${_w:-x}" in
  ''|*[!0-9]*) no "could not locate the .nthot persistence write - no verdict"; fin; exit $?;;
esac
_m=$(grep -n '^    _mt=$(( ${temperature\[1\]' "$AD" 2>/dev/null | head -1 | cut -d: -f1)
case "${_m:-x}" in
  ''|*[!0-9]*) no "could not locate the engage threshold - no verdict"; fin; exit $?;;
esac
_from=$(( _m - 4 )); [ "$_from" -ge 1 ] || _from=1
BLOCK=$(sed -n "${_from},${_w}p" "$AD")
case "$BLOCK" in
  *_ntHot=1*_ntHot=0*nthot*) : ;;
  *) no "lifted block is not the latch-plus-persist region - no verdict"; fin; exit $?;;
esac

# $1 = deci-degrees this pass, $2 = latch state persisted by the PREVIOUS pass.
# Prints whatever this pass persists.
pass() {
  _t_in=$1; _prev=$2
  _W=$(TMPDIR=$_TMPD0 mktemp -d) || { echo MKTEMP-FAILED; return; }
  (
    TMPDIR=$_W
    printf '%s' "$_prev" > "$_W/.nthot"
    # This is the loop-start read the daemon does before the block runs.
    _ntHot=$(cat "$_W/.nthot" 2>/dev/null || echo 0)
    _nvHeld=0; _nvPause=false
    eval 'temperature=(45 50 40 55)' 2>/dev/null || temperature="45 50 40 55"
    t=$_t_in
    eval "$BLOCK" >/dev/null 2>&1 || :
    cat "$_W/.nthot" 2>/dev/null || echo MISSING
  )
  rm -rf "$_W"
}

_r=$(pass 450 1)
case "$_r" in MKTEMP-FAILED|MISSING) no "the block did not persist anything ('$_r') - no verdict"; fin; exit $?;; esac

# --- 1: THE POINT. Hot last pass, 45C now - the latch must still read hot ---------------------
if [ "$_r" = 1 ]; then
  ok "a pass at 45.0C after a hot pass persists 1 - the latch carries and the band holds"
else
  no "a pass at 45.0C after a hot pass persisted '$_r' - the latch is reset before evaluation, so the hysteresis band is inert and charging resumes above resume_temp"
fi

# --- 2: control. Cool last pass, 45C now - must stay cool, not invent a hold ------------------
_r2=$(pass 450 0)
[ "$_r2" = 0 ] \
  && ok "control: 45.0C after a cool pass persists 0 - the band does not engage on its own" \
  || no "control: 45.0C after a cool pass persisted '$_r2' - the latch engages without ever reaching max_temp"

# --- 3: the thresholds still decide, whatever the previous pass said --------------------------
_hot=$(pass 520 0); _cold=$(pass 390 1)
if [ "$_hot" = 1 ] && [ "$_cold" = 0 ]; then
  ok "52.0C engages and 39.0C releases regardless of the previous pass"
else
  no "thresholds did not override the carried state (52.0C->'$_hot', 39.0C->'$_cold')"
fi

fin
