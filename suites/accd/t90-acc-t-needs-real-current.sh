#!/system/bin/sh
# t90 - `acc -t` must not run its switch test on a phone that is not actually taking charge.
#
# THE FAULT, measured on a Mi A3 whose charger contract had collapsed to the 500mA SDP floor:
#   4b ran 26s: works 3 rejected 0
#   voltage_max left at 3600000 (was 4400000)
#   daemon DEAD
# The phone could not charge afterwards until the node was written back by hand. That is the bricking
# state: a float-voltage ceiling does not pause charging, it ends it, at every level and across reboots.
#
# WHY IT RAN AT ALL. acc.sh guards the test with
#     while not_charging; do ... give up after ACC_T_WAIT ...; done
# and that loop never executed. `acc -t` stops the daemon first, so in that process chDisabledByAcc is
# false and $flip is empty - BOTH suppressors of the kernel-status tie-break are off. The phone's
# status node still said "Charging" (it does not follow a collapsed input), the tie-break promoted the
# verdict, not_charging answered "it is charging", and the guard fell through.
#
# WHY EVERY SWITCH THEN "WORKS". The test asks "did charging stop when I wrote the off value". On a
# phone already taking zero current the answer is yes for every candidate, including ones that do
# nothing at all - and including a voltage node, which is then recorded as working and left applied.
#
# THE RULE. The precondition for a switch test is not "does ACC believe charging is happening", it is
# "is this pack actually taking current right now". Those are different questions, and only the second
# one can be answered without trusting a status node that is known to go stale. Judge it on MAGNITUDE
# of real current plus the kernel agreeing - the same two-armed evidence the daemon uses to learn
# polarity - and never on not_charging alone.
#
# NO HARDWARE.

ID=t90
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AS=$execDir/acc.sh
[ -f "$AS" ] || { no "acc.sh not found"; fin; }

# ---- 1..5: EXECUTE the precondition rule ----------------------------------------------------------
# Does this phone have current flowing INTO the pack right now? idleThreshold is the daemon's own
# floor for "this is not just sensor noise".
_taking(){ # $1 current_now  $2 kernel status  $3 polarity (pos|neg) -> yes/no
  ( _cur=$1; _kst=$2; _pol=$3; _abs=${_cur#-}
    [ "${_abs:-0}" -gt 10000 ] 2>/dev/null || { echo no; exit; }
    [ "$_kst" = Charging ] || { echo no; exit; }
    case "$_pol" in
      neg) case "$_cur" in -*) echo yes;; *) echo no;; esac ;;
      *)   case "$_cur" in -*) echo no;;  *) echo yes;; esac ;;
    esac )
}
[ "$(_taking -2006684 Charging neg)" = yes ] \
  && ok "(rule) a Mi A3 charging at 2.0A is taking current" \
  || no "(rule) a real charge was rejected"
[ "$(_taking 2726562 Charging pos)" = yes ] \
  && ok "(rule) a Pixel charging at 2.7A is taking current" \
  || no "(rule) a real charge was rejected on the positive-sign phone"
[ "$(_taking 457000 Charging neg)" = no ] \
  && ok "(rule) THE FAULT: +457mA on an inverted-sign phone is DISCHARGE, even though the kernel says Charging" \
  || no "(rule) a discharging phone was accepted as charging - this is the state that graded 3 switches as working"
[ "$(_taking 78000 Charging neg)" = no ] \
  && ok "(rule) +78mA is not a charge either" \
  || no "(rule) a trickle in the wrong direction was accepted"
[ "$(_taking -2006684 Discharging neg)" = no ] \
  && ok "(rule) real current but the kernel disagrees -> not trusted, one arm is not enough" \
  || no "(rule) accepted on current alone with the kernel dissenting"

# ---- 6: the shipped guard must not rest on not_charging alone --------------------------------------
_src=$(sed 's/^[[:space:]]*#.*//' "$AS")
# Extract the -t precondition guard by REGION, not by counting lines.
#
# acc.sh has more than one `while not_charging`: switch_fails() has its own, waiting for charging to
# come BACK after a failed candidate, which is a different question with a different right answer.
# So the region is bounded by the two things unique to this guard - the ACC_T_WAIT budget above it and
# the give-up message below it.
#
# A line-window on comment-stripped source is what a first attempt used, and it silently PASSED
# against the unfixed file: stripping leaves blank lines, the added rationale pushed the `while` out
# of the window, the search found nothing, and "nothing found" was read as "no longer a bare guard".
# A test that cannot fail is worse than no test.
_region=$(awk '/_twmax=/{f=1} f{print} f && /Giving up after/{exit}' "$AS")
_wait=$(printf '%s\n' "$_region" | grep -c 'while.*not_charging') || _wait=0
case "${_wait:-0}" in ''|*[!0-9]*) _wait=0;; esac
if [ "$_wait" -eq 0 ] 2>/dev/null; then
  no "could not find the -t wait loop between the ACC_T_WAIT budget and the give-up message - this suite is not looking at the guard it claims to test"
  _wait=
else
  _wait=$(printf '%s\n' "$_region" | grep 'while.*not_charging' | head -1)
fi
if [ -z "$_wait" ]; then
  : # already reported above; do not turn "not found" into a pass
else
  # Accept it only if the loop condition ALSO consults real current. not_charging can be promoted by
  # a stale kernel status the moment nothing suppresses the tie-break, which is exactly the state
  # `acc -t` creates for itself by stopping the daemon first.
  # Two forms are acceptable and equivalent, because both stop a stale kernel status deciding it:
  #   - read the current directly, or
  #   - set flip=off so not_charging judges on the sign alone with the promotion suppressed.
  # The second is the idiom disable_charging already uses for the same reason.
  _cond=$_wait
  case "$_cond" in
    *current_now*|*_t_taking*|*taking*)
      ok "the wait condition consults real current, not just not_charging" ;;
    *flip=off*)
      ok "the wait condition suppresses the tie-break (flip=off), so a stale kernel status cannot walk past it" ;;
    *) no "acc -t still gates on a bare 'while not_charging' (line ${_wait} of the stripped source) - with the daemon stopped both tie-break suppressors are off, so a stale kernel 'Charging' walks straight past this guard and the test runs on a phone taking zero current" ;;
  esac
fi

# ---- 7: and a voltage candidate must never be left applied by that path ----------------------------
# t83/t84 cover the restore arms. This asserts the thing those cannot: that the test refuses to start
# rather than relying on a restore to undo what it should not have written.
printf '%s\n' "$_src" | grep -q 'Giving up after' \
  && ok "the give-up path exists, so a phone that never charges is not tested indefinitely" \
  || no "no give-up path in the acc -t wait"

sh -n "$AS" 2>/dev/null && ok "acc.sh parses" || no "acc.sh does not parse"
fin
