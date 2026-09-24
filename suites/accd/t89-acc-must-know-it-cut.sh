#!/system/bin/sh
# t89 - ACC must never cut charging and then forget that it did.
#
# THE DEFECT, root-caused from four measured stalls on a Mi A3 (90-190s each, daemon awake the whole
# time, logging every 3s and not resuming):
#
#   1. disable_charging calls flip_sw off, which sets the GLOBAL $flip=off and writes the cut.
#   2. sw_holds -> not_charging, whose first act is `local switch=${flip-}; flip=` - it CONSUMES $flip.
#      That call sees switch=off, the kernel-status tie-break is suppressed, and the cut is correctly
#      graded as holding.
#   3. Ten lines later a SECOND not_charging runs (misc-functions.sh:654). $flip is now empty AND
#      chDisabledByAcc is still false, because it is set at :664 - AFTER this gate. So BOTH suppressors
#      of the tie-break are off, the kernel's stale "Charging" promotes the verdict, and ACC grades its
#      own working cut as "still charging".
#   4. -> `return 7`, so chDisabledByAcc=true NEVER RUNS. The phone is cut and ACC does not know it.
#   5. Every later pass re-promotes for the same reason, is_charging (accd.sh:1191) returns TRUE, the
#      loop parks in the CHARGING branch and naps loopDelay[0]=3s (accd.sh:1434) - the exact measured
#      cadence - while the entire resume path (accd.sh:1436-1657) sits in the `else` it cannot enter.
#
# AND THE MIRROR IMAGE, which makes fixing only the first half useless: enable_charging clears
# chDisabledByAcc at misc-functions.sh:1009 on the write being ISSUED, with no check that current came
# back. If the release did not take, the next pass promotes again and the daemon is straight back in
# the stuck state, with the stall watchdog at accd.sh:1613 blinded by the same flag.
#
# WHY ONLY THE SWITCH PATH. A firmware-limit phone never executes any of this: accd.sh:1085
# `if $nativeLimit` continues at :1160/:1186, before is_charging at :1191. Its resume is one
# unconditional sync_native_limit write per pass. There is no belief to be wrong about.
#
# NO HARDWARE.

ID=t89
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
BI=$execDir/batt-interface.sh
[ -f "$MF" ] && [ -f "$BI" ] || { no "sources not found"; fin; }

# ---- 1..3: the tie-break, in the three contexts that matter -----------------------------------------
# Same shipped condition, executed. The phone traits are laurus's and are held constant: sign verdict
# Discharging (inverted polarity), kernel says Charging (status node ignores a current cut), coulomb
# arbiter abstaining.
_promote(){ # $1 switch  $2 chDisabledByAcc  -> the verdict
  ( _status=Discharging; _kstatus=Charging; _ccd=
    switch=$1; chDisabledByAcc=$2
    if [ "$_status" = Discharging ] && [ "${_kstatus-}" = Charging ] && [ -z "${_ccd-}" ] \
      && [ "${switch-}" != off ] && { [ "${switch-}" = on ] || ! ${chDisabledByAcc:-false}; }
    then _status=Charging; fi
    echo "$_status" )
}
[ "$(_promote off false)" = Discharging ] \
  && ok "the FLIP test (switch=off) suppresses the promotion - a working cut is graded as holding" \
  || no "the flip test promotes - a working cut would be graded broken"
[ "$(_promote '' true)" = Discharging ] \
  && ok "the CONFIRMATION, once ACC has recorded the cut, is also suppressed" \
  || no "the confirmation promotes even with chDisabledByAcc set"
[ "$(_promote '' false)" = Charging ] \
  && ok "(the fault, reproduced) switch consumed AND flag not yet set -> the kernel overrules a working cut" \
  || no "could not reproduce the promotion in the unguarded context - this suite's premise is stale"

# ---- 4: the ONE line that fixes the fault, and what must not be bolted onto it ----------------------
# The fault above is reached only when $flip is empty at the confirmation. `flip=off` on the line
# before it is what stops that, and the tie-break tests `switch != off` BEFORE it tests
# chDisabledByAcc, so once that line is there the ownership flag can do nothing extra here. test24-4
# hoisted the flag above the confirmation anyway and paired it with a rollback; t152 measured both
# and they were reverted. This suite grades the line that actually does the work.
_dis=$(awk '/^disable_charging\(\) \{/,/^\}/' "$MF")
[ -n "$_dis" ] || { no "could not extract disable_charging"; fin; }
_pre=$(printf '%s\n' "$_dis" | sed -n '1,/if ! not_charging; then/p')
printf '%s\n' "$_pre" | grep -q '^    flip=off' \
  && ok "flip=off is re-armed immediately before the confirmation, so switch=off suppresses the promotion" \
  || no "flip=off is missing before the confirmation - the fault above is live"

# And nothing between that line and the confirmation may consume a status verdict, or the
# suppression would be incomplete for it.
_win=$(printf '%s\n' "$_dis" | sed -n '/^    flip=off/,/if ! not_charging; then/p' | sed '1d;$d')
_extra=$(printf '%s\n' "$_win" | grep -c 'not_charging\|is_charging\|read_status')
[ "${_extra:-0}" -eq 0 ] \
  && ok "no other status consumer sits between flip=off and the confirmation" \
  || no "$_extra status consumers sit in that window, where flip=off may already be consumed"

# The failed-cut arm. sw_holds waits up to four firmware ticks and not_charging samples for _STI
# seconds, so a confirmation that did not land is not proof the switch does not work. Undoing the
# write here resets that progress on every pass - measured in t152 as never reaching a hold at all
# for a switch needing three applied passes, against pass 3 when the cut is kept.
_fail=$(printf '%s\n' "$_dis" | sed -n '/if ! not_charging; then/,/return 7/p')
printf '%s\n' "$_fail" | grep -q 'flip_sw on' \
  && no "the failure path re-arms the switch before returning 7 - a settling switch can never confirm" \
  || ok "a failed confirmation leaves the cut in place and lets the next daemon pass retry it"
printf '%s\n' "$_fail" | grep -q 'chDisabledByAcc' \
  && no "the failure path touches the ownership flag, which is only set after a confirmed cut" \
  || ok "the failure path leaves the ownership flag alone"

# Ownership is recorded once the cut is CONFIRMED, which is the rc24 position and the only one that
# cannot claim a cut ACC does not have.
_after=$(printf '%s\n' "$_dis" | sed -n '/return 7/,$p')
printf '%s\n' "$_after" | grep -q 'chDisabledByAcc=true' \
  && ok "ownership is recorded after the confirmation, on the path where the cut is known to hold" \
  || no "chDisabledByAcc=true is not on the confirmed path"

# ---- 5: enable_charging must not clear the flag on the write alone ---------------------------------
_en=$(awk '/^enable_charging\(\) \{/,/^\}/' "$MF")
[ -n "$_en" ] || { no "could not extract enable_charging"; fin; }
_clr=$(printf '%s\n' "$_en" | grep -n '^ *chDisabledByAcc=false' | head -1 | cut -d: -f1)
if [ -z "$_clr" ]; then
  no "could not find the chDisabledByAcc=false in enable_charging"
else
  # EXECUTE the shipped shape rather than pattern-matching it. Mutation-tested: the old `*if*` arm
  # matched any substring, so a build with the guard DELETED passed, and so did one with it INVERTED
  # (`if not_charging; then chDisabledByAcc=false; fi`) - strictly worse than rc22. A window of context
  # containing the word "if" proves nothing at all.
  #
  # Lift the tail of enable_charging and run it twice: once where the release took, once where it did
  # not. The flag must survive only in the second case.
  _tail=$(printf '%s\n' "$_en" | sed -n "$(( _clr > 8 ? _clr - 8 : 1 )),$(( _clr + 2 ))p")
  _try(){ # $1 = did charging come back? (yes/no) -> prints the flag afterwards
    ( set +u
      chDisabledByAcc=true
      _r=$1
      not_charging(){ [ "$_r" = no ]; }
      # rc25 also asks whether a charger is attached. Stub it true: this case is about a phone WITH
      # the cable in, which is the only situation where keeping the flag buys a retry. The unplugged
      # half of that guard is asserted separately below.
      present(){ return 0; }
      set_temp_level(){ :; }
      eval "$_tail" >/dev/null 2>&1
      printf '%s' "${chDisabledByAcc:-unset}" ) 2>/dev/null
  }
  _took=$(_try yes); _didnt=$(_try no)
  # rc25: with no charger attached there is never a later pass carrying real charging current, so the
  # flag has to clear regardless of what the observer says. A Fairphone 5 sat unplugged with it stuck
  # true for 174 consecutive flight records and ACC then believed it already owned a cut on the next
  # plug-in. This is only asserted when the guard is present, so the check still means something on
  # a build that does not have it.
  if grep -q 'if not_charging && present; then' "$MF"; then
    _unplugged=$( set +u
      chDisabledByAcc=true
      not_charging(){ return 0; }
      present(){ return 1; }
      switch_release_observed(){ return 1; }
      set_temp_level(){ :; }
      eval "$_tail" >/dev/null 2>&1
      printf '%s' "${chDisabledByAcc:-unset}" )
    [ "$_unplugged" = false ]       && ok "with no charger attached the flag clears whatever the observer says"       || no "unplugged, the cut flag stayed [${_unplugged}] - ACC would believe it owns a cut at the next plug-in"
  fi
  if [ "$_took" = false ] && [ "$_didnt" = true ]; then
    ok "the flag clears only when the release is OBSERVED (took->${_took}, did not->${_didnt}), so a failed resume is retried"
  else
    no "the clear is not conditional: release-took gave [${_took}], release-failed gave [${_didnt}] - they must differ, or a failed resume is never retried and the stall watchdog is blinded by the flag its own resume cleared"
  fi
fi

# ---- 6: the observation must not be the promotion itself -------------------------------------------
# Checking "did charging come back" with the tie-break live is circular: it would answer yes because
# the kernel says Charging, which is the very thing that is stale.
printf '%s\n' "$_en" | grep -q 'chDisabledByAcc=false.*not_charging' \
  && no "the clear and the check are on one line in an order that lets the flag drop before the check" \
  || ok "the clear does not precede its own check on the same line"

# ---- 7: a wrong polarity must not freeze for the whole boot ----------------------------------------
# .dpol_unstable is set after 2 sign flips (batt-interface.sh, misc-functions.sh) and read at
# accd.sh's set_dp as `[ ! -f $TMPDIR/.dpol_unstable ] || return 0` - which stops the re-latch loop
# permanently. Nothing under install/ ever removed it, so a polarity learned wrong stayed wrong until
# reboot, and the daemon was left structurally dependent on the kernel tie-break for its entire
# charge/discharge verdict. On the one phone in the fleet with an inverted sign, that is the same
# signal the stall above turned on.
#
# Clearing it on a REAL cable removal matches .hvcontract, the other per-plug latch, cleared at the
# same `! present` branch. It cannot thrash: the 2-flip counter has to be earned again from scratch.
AD=$execDir/accd.sh
if [ -f "$AD" ]; then
  grep -q 'rm -f $TMPDIR/.dpol_unstable' "$AD" \
    && ok "the polarity-unstable latch is cleared somewhere, so a wrong sign is not frozen until reboot" \
    || no ".dpol_unstable is set but never cleared - a polarity learned wrong freezes for the whole boot and the daemon can only ever fall back on the kernel tie-break"
  # and it must be cleared ON UNPLUG, not on some path that runs while the latch is still earning its
  # keep. Strip comments first and take the WHOLE branch, not a fixed 6-line window: the rm sits 13
  # lines below the `if`, so what -A6 actually matched was the comment above it, and moving the rm
  # anywhere in the file left this check green. It was grading prose.
  _branch=$(sed 's/^[[:space:]]*#.*//' "$AD" | awk '/if ! present 2>\/dev\/null; then/{f=1} f{print} f && /^      fi$/{exit}')
  printf '%s\n' "$_branch" | grep -q 'rm -f $TMPDIR/.dpol_unstable' \
    && ok "cleared inside the '! present' branch itself, the same lifetime .hvcontract gets" \
    || no "the rm is not inside the unplug branch - it may sit elsewhere in the file and never run on a cable event"
fi

sh -n "$MF" 2>/dev/null && ok "misc-functions.sh parses" || no "misc-functions.sh does not parse"
fin
