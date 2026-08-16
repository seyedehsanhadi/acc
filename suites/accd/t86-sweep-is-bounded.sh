#!/system/bin/sh
# t86 - a runtime switch sweep must not hold a plugged phone off charge indefinitely.
#
# THE FAULT, measured on a Mi A3 (laurus), plugged in, on rc23 and identically on rc22:
#   the daemon sat inside cycle_switches for 5+ minutes. usb/present=1 and usb/online=0, the phone
#   taking ZERO current, with four limiters standing at once (main/constant_charge_current_max=0,
#   battery/charge_control_limit=1, restrict_chg=1, restrict_cur=10000). flight.log froze and a
#   config touch went unanswered for 20s, because a sweep is not the main loop: no pause, no resume,
#   no temperature limit, and every health check still reporting the daemon alive.
#
# THE COST MODEL. batt-interface.sh not_charging polls _STI=35 times a second apart, so a candidate
# that does not hold costs ~35s; the strict pass adds 3 x loopDelay[0]=3. Worst candidate 44s.
# cycle_switches_off runs up to THREE full passes per call (:519 strict, :526/:527 the
# prioritizeBattIdleMode pass, :529 plain). Unbounded, that is hours.
#
# WHY A CLOCK AND NOT A CANDIDATE COUNT. acc -t walks the whole 139-line list in 326s on laurus and
# 582s on bluejay at that same per-candidate cost, so only ~9-16 candidates actually EXIST on a given
# device; the rest are absent files that cost nothing. Counting candidates would spend the budget on
# free skips. A clock only ever spends on work.
#
# WHY A BOUND COSTS NO CAPABILITY. The reject arm (:433-436) and the failure arm (:479-482) both
# `sed -i` the candidate out of $TMPDIR/ch-switches and append it to the end. Only candidates that
# COST TIME rotate; free skips stay at the front and are re-passed in milliseconds. So the list
# self-rotates and the next sweep resumes on new work.
#
# THE THREE THINGS THAT MAKE THIS SAFE, each asserted below:
#   1. the budget is a LOCAL of cycle_switches_off, not a global. mksh scopes locals dynamically, so
#      cycle_switches sees it while that call is on the stack and it is gone the moment it returns.
#      A global would go stale and silently bound `online && ( cycle_switches on )` at accd.sh:2885 -
#      the exit-trap restore sweep, and the ONLY path that un-cuts candidates deliberately left cut
#      at or above the pause level. Bounding that strands a phone unable to charge.
#   2. an UNARMED sweep is unchanged. That is what the on direction and the restore path get.
#   3. `acc -t` is exempt. It walks everything on purpose with a user watching.
#
# NO HARDWARE. It runs the REAL cycle_switches, extracted, with the hardware answers stubbed and the
# control flow untouched.

ID=t86
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }
_src=$(awk '/^cycle_switches\(\) \{/,/^\}/' "$MF")
[ -n "$_src" ] || { no "could not extract cycle_switches"; fin; }

W=${TMPDIR:-/data/local/tmp}/t86box

# run(): $1 candidates  $2 acc_t  $3 budget seconds ('' = UNARMED)  $4 seconds per candidate
# echoes "<tried> <nodesLeftCut> <marker> <listLen> <head>"
run(){
  rm -rf $W 2>/dev/null; mkdir -p $W || { echo "0 9 err 0 -"; return; }
  local _n=$1 _at=$2 _bud=$3 _cost=$4 _i=0
  : > $W/ch-switches
  while [ $_i -lt $_n ]; do
    _i=$((_i+1)); echo 1000 > $W/node$_i
    echo "$W/node$_i 1000 0" >> $W/ch-switches
  done
  ( set +e +u
    export TMPDIR=$W dataDir=$W execDir=$execDir
    # Stubs answer for HARDWARE only. Every branch, counter and sed -i below is the real code.
    flip_sw(){ flip=$1; [ "$1" = off ] && echo 0 > "${chargingSwitch[0]}" || echo 1000 > "${chargingSwitch[0]}"; return 0; }
    # a candidate whose cut did nothing -> the failure arm, which is the path that ran for 5 minutes.
    # It sleeps, because the bound under test is a clock and a free stub would never trip it.
    not_charging(){ echo x >> $W/tried; sleep $_cost; return 1; }
    at_or_above_pause(){ return 1; }          # below the limit, so a restore is expected
    journal_arm(){ :; }; journal_disarm(){ :; }; journal_blacklisted(){ return 1; }
    invalid_switch(){ return 1; }; status(){ return 0; }
    volt_now(){ echo 4000000; }; batt_cap(){ echo 50; }
    _wlog(){ :; }; warn_once_per(){ :; }; print(){ :; }; wait_plug(){ :; }
    present(){ return 0; }; online(){ return 0; }
    levelSwitch=false; strict=false; isAccd=true; acc_t=$_at
    prioritizeBattIdleMode=false; chargingSwitch=(); currFile=$W/curr
    echo -1000000 > $W/curr
    probePending=$W/.probe-pending; echo x > $probePending
    loopDelay=(3 9); capacity=(5 101 70 74 false); LVL_SETTLE_STEP=0
    eval "$_src" 2>/dev/null || exit 1
    : > $W/tried
    # Stand in for cycle_switches_off arming the budget. Unarmed when $_bud is empty, which is what
    # the restore direction and the exit-trap sweep see.
    if [ -n "$_bud" ]; then _swEnd=$(( SECONDS + _bud )); fi
    cycle_switches off "" false >/dev/null 2>&1
    echo "${chargingSwitch[0]-}" > $W/leftsw
  ) 2>/dev/null
  local _tried=$(wc -l < $W/tried 2>/dev/null || echo 0)
  local _cut=0 _f=
  for _f in $W/node*; do [ "$(cat "$_f" 2>/dev/null)" = 0 ] && _cut=$((_cut+1)); done
  echo "${_tried:-0} ${_cut} $([ -f $W/.testingsw ] && echo marker || echo clean) $(wc -l < $W/ch-switches 2>/dev/null || echo 0) $(head -1 $W/ch-switches 2>/dev/null | sed 's|.*/||; s| .*||')"
}

# ---- 1: the bound -----------------------------------------------------------------------------------
# 40 candidates at 3s each. The check is at the top of the loop body and a started candidate always
# runs to completion, so the honest expectation is "a few", not an exact count.
# 12s of budget against 3s candidates. The live ratio is 120s against a 35-44s candidate, so the
# progress floor is never as tight as 6s/3s made it here - that margin was thin enough that one slow
# pass tipped the count and failed a bound that was working correctly.
set -- $(run 40 false 12 3)
_tried=$1; _cut=$2; _marker=$3; _len=$4; _head=$5
if [ "${_tried:-0}" -lt 40 ] 2>/dev/null && [ "${_tried:-0}" -gt 0 ] 2>/dev/null; then
  ok "an armed sweep stopped after ${_tried} of 40 candidates (12s budget, 3s each)"
else
  no "UNBOUNDED: tried ${_tried} of 40 - at ~35s a real candidate that is a plugged phone held off charge for ~$(( ${_tried:-0} * 35 / 60 )) minutes per pass, three passes per call"
fi

# ---- 2: it must still make PROGRESS, or discovery deadlocks across sessions --------------------------
[ "${_tried:-0}" -ge 2 ] 2>/dev/null \
  && ok "it started ${_tried} candidates before stopping, so every sweep retires real work" \
  || no "only ${_tried} candidate(s) started - a sweep that makes no progress can never finish discovery"

# ---- 3: bailing must not leave a node cut ------------------------------------------------------------
[ "${_cut:-1}" -eq 0 ] \
  && ok "no candidate node left at its off value when the sweep stopped" \
  || no "${_cut} node(s) left cut - below the pause level every candidate must be restored"

# ---- 4: the marker must not survive the bail ---------------------------------------------------------
[ "$_marker" = clean ] \
  && ok ".testingsw removed on the bail path (a stale marker makes every liveness check lie)" \
  || no ".testingsw left behind when the sweep stopped early"

# ---- 5: no forged switch selection --------------------------------------------------------------------
# `while read -A chargingSwitch` assigns the GLOBAL array, so a bail leaves it holding the untried
# candidate - and accd.sh:1219 writes that straight to $TMPDIR/.sw as if it had been chosen.
_left=$(cat $W/leftsw 2>/dev/null)
[ -z "$_left" ] \
  && ok "chargingSwitch left empty, so the bail cannot be mistaken for a switch selection" \
  || no "bail left chargingSwitch='$_left' - accd.sh:1219 would write that to .sw as a chosen switch"

# ---- 6: discovery must still be able to finish --------------------------------------------------------
[ "${_len:-0}" -eq 40 ] \
  && ok "all 40 candidates still in ch-switches, so nothing untried was lost" \
  || no "candidate list went from 40 to ${_len} - a bounded sweep must not drop what it did not try"

# ---- 7: and the next sweep must not repeat the same prefix forever -------------------------------------
case "${_head:-node1}" in
  node1) no "list did not rotate: the next sweep retries the same candidates and never reaches the rest" ;;
  *)     ok "list rotated, head is now ${_head}, so the next sweep continues past what this one tried" ;;
esac

# ---- 8: an UNARMED sweep is unchanged -------------------------------------------------------------------
# This is what `cycle_switches on` and the exit-trap restore sweep at accd.sh:2885 get. Bounding that
# path would strand a phone whose candidates were deliberately left cut at or above the pause level.
set -- $(run 8 false '' 1)
[ "$1" -eq 8 ] 2>/dev/null \
  && ok "an UNARMED sweep still walks all 8 - the restore direction and the exit-trap sweep are untouched" \
  || no "an unarmed sweep stopped after $1 of 8 - the budget is leaking into paths that must not be bounded"

# ---- 9: acc -t is exempt ---------------------------------------------------------------------------------
set -- $(run 8 true 1 1)
[ "$1" -eq 8 ] 2>/dev/null \
  && ok "acc -t walks all 8 even with a 1s budget armed - the bound is runtime-only" \
  || no "acc -t stopped after $1 of 8 - bounding the deliberate full test breaks switch discovery"

# ---- 10: the budget must be a LOCAL of cycle_switches_off, never a global ---------------------------------
# A global is never cleared, and cycle_switches is also reached by accd.sh:2885's restore sweep.
_off=$(awk '/^cycle_switches_off\(\) \{/,/^\}/' "$MF")
printf '%s\n' "$_off" | grep -q 'local .*_swEnd' \
  && ok "cycle_switches_off declares the budget local, so it cannot go stale and bound the restore sweep" \
  || no "the budget is not declared local in cycle_switches_off - a stale global would silently bound accd.sh:2885's restore sweep, the only path that un-cuts candidates left cut at or above pause"

# ---- 11: one budget for the whole call, not one per pass --------------------------------------------------
# Three separate budgets would put the ceiling at 3x, worse than the 326s full walk it is meant to beat.
_arm=$(printf '%s\n' "$_off" | grep -c '_swEnd=') || _arm=0
case "${_arm:-0}" in
  1) ok "the budget is armed exactly once, so all three passes share it" ;;
  *) no "${_arm} arming sites in cycle_switches_off - three passes with a budget each is 3x the ceiling" ;;
esac

sh -n "$MF" 2>/dev/null && ok "misc-functions.sh parses" || no "misc-functions.sh does not parse"
fin
