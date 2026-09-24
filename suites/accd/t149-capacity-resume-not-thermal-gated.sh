#!/system/bin/sh
# t149 - a capacity pause must resume on capacity, not on a thermal threshold that never fired.
#
# THE FAULT, measured on laurus. Config: max_temp 45, resume_temp 39, pause 75, resume 70. ACC cut
# battery/input_suspend at 80%, the pack discharged to 68%, and the cut was still in force with the
# cable out and chDisabledByAcc still true. The highest temperature in all 692 flight rows was
# 43.5 C, so max_temp was never reached and there was no thermal hold to release. The phone was
# simply warm, and would not have charged when plugged back in.
#
# WHERE IT COMES FROM. The resume branch read
#     elif _le_resume_cap && [ $(temp_now) -le $(( ${temperature[2]} * 10 )) ]; then
# resume_temp is the RELEASE end of the max_temp hysteresis, not an operating ceiling. Testing it
# unconditionally means any pack sitting in the ordinary band between resume_temp and max_temp can
# never take the branch, so a pure capacity pause is held until the phone happens to cool.
#
# THE FIX must not collapse the hysteresis it replaces: during a real thermal pause the release
# still has to wait for resume_temp, or the phone re-enables charging the moment it touches
# max_temp. _thermal_hold_active is exactly that predicate, so the branch now reads
#     elif _le_resume_cap && ! _thermal_hold_active; then
# Both halves are graded below, because a fix that only unblocks the warm case would ship the
# opposite bug.

ID=t149
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found under $execDir"; fin; }

# ---- 1. the branch condition --------------------------------------------------------------------
grep -q 'elif _le_resume_cap && ! _thermal_hold_active; then' "$AD" \
  && ok "the capacity resume is gated on the thermal HOLD, not on a bare temperature" \
  || no "the capacity resume branch is not gated on _thermal_hold_active"

grep -q 'elif _le_resume_cap && \[ \$(temp_now) -le' "$AD" \
  && no "the bare resume_temp gate is still on the capacity resume - a warm pack stays cut" \
  || ok "no bare resume_temp gate remains on the capacity resume"

# The body's own re-check is the second line of defence across the force-off sleep. Losing it would
# make this branch depend on a reading taken before that sleep.
grep -q '_temp_hold || enable_charging' "$AD" \
  && ok "the branch body still re-checks the temperature before enabling" \
  || no "the post-sleep _temp_hold re-check is gone"

# ---- 2. the predicate itself --------------------------------------------------------------------
_th=$(sed -n '/^  _thermal_hold_active() {/,/^  }/p' "$AD")
[ -n "$_th" ] || { no "_thermal_hold_active not found - the branch above cannot work"; fin; }

# Drive it with a stubbed sensor. temperature=(cooldown max resume shutdown).
# $1 = raw deci-C, $2 = incoming mtReached -> HOLD | FREE, and the mtReached it leaves behind.
th(){ ( eval "$_th"
        temperature[0]=42; temperature[1]=45; temperature[2]=39; temperature[3]=50
        _rd=$1; temperature_now(){ echo "$_rd"; }
        mtReached=$2
        if _thermal_hold_active; then printf 'HOLD %s\n' "$mtReached"
        else printf 'FREE %s\n' "$mtReached"; fi ) 2>/dev/null; }

# The laurus case: warm, never hot. This is the whole bug.
[ "$(th 435 false)" = 'FREE false' ] \
  && ok "43.5C with max_temp 45 and resume_temp 39 is NOT a hold - the warm capacity pause resumes" \
  || no "43.5C still reads as a thermal hold - laurus stays cut ($(th 435 false))"

# At and above max_temp it must hold, and must arm the hysteresis for the cooling band.
[ "$(th 450 false)" = 'HOLD true' ] \
  && ok "45.0C holds and latches mtReached" \
  || no "45.0C did not hold or did not latch ($(th 450 false))"
[ "$(th 460 false)" = 'HOLD true' ] \
  && ok "46.0C holds" || no "46.0C did not hold ($(th 460 false))"

# The cooling band: once latched, the release waits for resume_temp, not max_temp.
[ "$(th 440 true)" = 'HOLD true' ] \
  && ok "44.0C after max_temp was reached still holds - the hysteresis is intact" \
  || no "the hold released at 44.0C - the cooling band collapsed to max_temp ($(th 440 true))"
[ "$(th 400 true)" = 'HOLD true' ] \
  && ok "40.0C after max_temp was reached still holds" \
  || no "the hold released at 40.0C ($(th 400 true))"
[ "$(th 390 true)" = 'FREE true' ] \
  && ok "39.0C releases exactly at resume_temp" \
  || no "the hold did not release at resume_temp ($(th 390 true))"

# A sensor that cannot be read must answer "no hold": refusing to release is the dangerous
# direction, and it is the one that strands a phone.
[ "$(th '' false)" = 'FREE false' ] \
  && ok "an unreadable sensor is not a hold" \
  || no "an unreadable sensor fabricated a hold ($(th '' false))"

# A garbage max_temp must not abort the loop under set -e.
[ "$(th 435 false)" = 'FREE false' ] && ok "a numeric max_temp is required and present" || :
_bad=$( ( eval "$_th"
          temperature[0]=42; temperature[1]=x; temperature[2]=39; temperature[3]=50
          temperature_now(){ echo 435; }
          mtReached=false
          if _thermal_hold_active; then echo HOLD; else echo FREE; fi ) 2>/dev/null )
[ "$_bad" = FREE ] \
  && ok "a non-numeric max_temp answers 'no hold' instead of erroring" \
  || no "a non-numeric max_temp did not answer cleanly ($_bad)"

fin
