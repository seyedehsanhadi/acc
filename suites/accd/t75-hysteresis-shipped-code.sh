#!/system/bin/sh
# t75 - run the SHIPPED thermal-hold code, not a copy of it.
#
# WHY THIS EXISTS ON TOP OF t74. t74 proves the hysteresis is correct by re-implementing the latch
# inside the test and ramping that. That is a real gap: the thing it grades is the test's own copy,
# so a shipped block that drifts from the copy still passes. For the one defect a user actually
# reported -- "still charges above set temperature" -- a re-implementation is not evidence.
#
# This test lifts the decision block out of accd.sh VERBATIM and evaluates it. If the shipped text
# changes, what runs here changes with it.
#
# NO HARDWARE. The extracted block is pure arithmetic over $t and the temperature array.

ID=t75
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found at $AD"; fin; }

# ---- extract ------------------------------------------------------------------------------------
# From the hysteresis marker down to (but NOT including) the `if` that consumes the latch: that `if`
# opens a block whose body is the firmware-node write, which needs real hardware. Everything above
# it is the decision, and the decision is what the report is about.
_BLK=$(sed -n '/rc23: HYSTERESIS/,/^    if \[ "\${_ntHot:-0}" = 1 \]/p' "$AD" | sed '$d')
[ -n "$_BLK" ] || { no "could not extract the hysteresis block - has the marker moved?"; fin; }

printf '%s' "$_BLK" | grep -q '_ntHot=1' && printf '%s' "$_BLK" | grep -q '_ntHot=0' \
  && ok "extracted the shipped block, both latch edges present ($(printf '%s' "$_BLK" | wc -l) lines)" \
  || { no "the extracted block does not set the latch both ways - extraction is wrong, not the code"; fin; }

# Guard the extraction itself: if this ever silently captures nothing but comments, every ramp below
# would trivially "pass" by leaving _ntHot at its initial value.
_code=$(printf '%s\n' "$_BLK" | grep -vc '^[[:space:]]*#')
[ "${_code:-0}" -ge 5 ] 2>/dev/null \
  && ok "the extract carries $_code executable lines, not just commentary" \
  || no "only $_code executable lines extracted - the ramps below would prove nothing"

# ---- execute ------------------------------------------------------------------------------------
# temperature=(cooldown max resume shutdown), in whole degrees. $t is deci-degrees, as the kernel
# node reports it. The block is evaluated once per sample, exactly as the daemon evaluates it once
# per pass, with the latch carried across samples the same way the daemon carries it across passes.
ramp() {   # $1=max $2=resume, then the temperature samples -> one digit of hold state per sample
  ( _mx=$1; _rs=$2; shift 2
    temperature=(0 $_mx $_rs 0)
    _ntHot=0
    _out=
    for t in "$@"; do
      eval "$_BLK" 2>/dev/null
      _out="$_out${_ntHot:-0}"
    done
    printf '%s' "$_out" )
}

# sanity: the harness must be able to fail. If eval silently did nothing, this returns all zeros.
_r=$(ramp 50 40 600)
[ "$_r" = 1 ] \
  && ok "the harness really runs the block (600 deci-degrees engages the hold)" \
  || { no "eval of the shipped block produced '$_r' for a temperature far above the limit - the harness is broken, not the code"; fin; }

# ---- the reported defect --------------------------------------------------------------------------
_r=$(ramp 50 40 499 500 499)
[ "$_r" = 011 ] \
  && ok "49.9C after 50.0C keeps the hold on - the reported bug, in the shipped code" \
  || no "shipped code gave $_r, expected 011: it still releases a tenth of a degree under the limit"

_r=$(ramp 50 40 300 450 499 500 501 490 460 420 401 400 399 350)
[ "$_r" = 000111111000 ] \
  && ok "engages at max_temp and holds all the way down to resume_temp ($_r)" \
  || no "shipped ramp was $_r, expected 000111111000"

_r=$(ramp 50 40 500 450 450 450 450)
[ "$_r" = 11111 ] \
  && ok "held through a 45C plateau instead of oscillating at the limit" \
  || no "shipped ramp was $_r - the hold flickers, which is the burst charging users see"

_r=$(ramp 50 40 500 400)
[ "$_r" = 10 ] \
  && ok "it does release once resume_temp is actually reached" \
  || no "shipped ramp was $_r - a hold that never releases would strand charging"

# Boundary: both comparisons are inclusive, so exactly max_temp engages and exactly resume_temp
# clears. An off-by-one to `-gt`/`-lt` would leave a one-tenth dead band at each edge.
_r=$(ramp 50 40 500)
[ "$_r" = 1 ] && ok "exactly max_temp engages the hold" || no "500 gave $_r - max_temp itself does not engage"
_r=$(ramp 50 40 500 400)
[ "$_r" = 10 ] && ok "exactly resume_temp clears it" || no "400 gave ${_r#?} - resume_temp itself does not clear"

# ---- the user's own numbers ------------------------------------------------------------------------
# The rc18 report was max 40 with the pack reaching 43. Under the fix a 40C limit holds from 40.0
# down to 30.0 and cannot be sitting at 43 with charging allowed.
#                  38.0 40.0 43.0 41.0 39.9 35.0 30.1 30.0 29.0
#                   .   engage...................... release at exactly 30.0
_r=$(ramp 40 30 380 400 430 410 399 350 301 300 290)
[ "$_r" = 011111100 ] \
  && ok "a 40C limit holds from 40.0C down to 30.0C ($_r)" \
  || no "40C limit ramp was $_r, expected 011111100"

# ---- mis-edited configs must degrade, never strand -------------------------------------------------
_r=$(ramp 50 50 500 499 450 400)
[ "$_r" = 1000 ] \
  && ok "resume equal to max degrades to the old single threshold instead of holding forever" \
  || no "equal temps gave $_r - the hold could never release"

_r=$(ramp 50 60 500 499 450 400)
[ "$_r" = 1000 ] \
  && ok "resume ABOVE max degrades too, rather than stranding charging" \
  || no "resume above max gave $_r - charging would never resume"

# An absent array must not crash the block or latch it on. The defaults in the shipped text are
# 50 and 40, so this behaves as a normal config.
_r=$( ( _BLK=$_BLK; _ntHot=0; unset temperature; _out=
        for t in 300 500 450 400; do eval "$_BLK" 2>/dev/null; _out="$_out${_ntHot:-0}"; done
        printf '%s' "$_out" ) )
[ "$_r" = 0110 ] \
  && ok "with no temperature array at all the shipped defaults (50/40) still hysterese ($_r)" \
  || no "unset config gave $_r, expected 0110"

# ---- the generic path is not collateral damage -------------------------------------------------------
grep -q 'temp_now) -le \$(( \${temperature\[2\]} \* 10 ))' "$AD" \
  && ok "the switch path's resume is still gated on resume_temp, untouched" \
  || no "the generic path lost its resume_temp gate"

# ---- standing instruction ---------------------------------------------------------------------------
printf '%s' "$_BLK" | grep -q 'temperature\[3\]' \
  && no "the hysteresis block reads shutdown_temp - it must not" \
  || ok "shutdown_temp is not referenced by any of this"

# ---- the stale comment that described the defect as the design ----------------------------------------
sed -n '/rc23: HYSTERESIS/,/_ntHot:-0/p' "$AD" | grep -q "lifts on its own once the temperature drops back" \
  && no "the old comment still says the hold lifts under max_temp - it contradicts the code" \
  || ok "no comment left claiming the hold lifts at max_temp"

fin
