#!/system/bin/sh
# t151 - a candidate ACC did not adopt must never stay cut with nobody owning the release, and
# paying for that must not cost a re-arm on every failed candidate at the limit.
#
# THE TWO FAULTS, one on each side.
#
#   a39358d found that the reject arm left a candidate latched OFF for the whole session - no
#   restore in the arm, none in cycle_switches_off's second pass (its `not_charging ||` guard skips
#   precisely when the abandoned node is the thing cutting), none in enable_charging, which only
#   touches the ADOPTED switch. The values are hostile: */current_max 0, charge_stop_level 5,
#   siop_level 0. It fixed that by restoring, suppressed at or above the pause level because there
#   the cut is the thing we want and each re-arm lets the level climb through the fan-out.
#
#   That suppression assumed a later enable_charging would put the node back. It does not, because
#   when the sweep adopts nothing chargingSwitch ends up empty and there is no adopted switch to
#   restore. Measured on a Mi A3: every candidate rejected, battery/input_suspend left at 1, raising
#   the limit could not resume within 150s.
#
# test24-4 answered that by deleting the suppression, which fixes the strand and brings the fan-out
# re-arms back for every phone. The shipped answer keeps both: hold at the limit, RECORD what was
# held, and release it at the one point where "nothing was adopted" is known.
#
# NO HARDWARE.

ID=t151
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
AD=$execDir/accd.sh
[ -f "$MF" ] || { no "misc-functions.sh not found under $execDir"; fin; }

[ 1 = 2 ] && no "harness: 1 equals 2" || ok "harness: the assertions discriminate"

_cyc=$(awk '/^cycle_switches\(\) \{/,/^}/' "$MF")
[ -n "$_cyc" ] || { no "could not read the switch sweep"; fin; }

# ---- 1. one decision, two callers ----------------------------------------------------------------
_n=$(printf '%s\n' "$_cyc" | grep -c '^[[:space:]]*hand_back_or_hold$')
[ "$_n" -eq 2 ] \
  && ok "both non-adoption arms call the same helper ($_n sites)" \
  || no "expected 2 hand_back_or_hold sites in the sweep, found $_n"
grep -q '^at_or_above_pause() {' "$MF" \
  && ok "the level check exists" || no "the level check is gone"
grep -q '^hand_back_or_hold() {' "$MF" \
  && ok "the shared decision exists" || no "the shared decision is missing"

# ---- 2. the decision, driven ---------------------------------------------------------------------
_hb=$(sed -n '/^hand_back_or_hold() {/,/^}/p' "$MF")
# The stub reads _lvl/_pause from the enclosing scope, NOT from positional parameters: a function
# defined inside this subshell gets its own $1/$2, so `[ "$2" -ge "$3" ]` inside at_or_above_pause
# compares two empty strings and the whole matrix answers the same way whatever it is handed.
decide(){ # $1 node, $2 level, $3 pause -> RESTORED | HELD
  ( eval "$_hb"
    _lvl=$2; _pause=$3
    set -A chargingSwitch "$1" 1 0
    capacity[3]=$_pause
    at_or_above_pause(){ [ "$_lvl" -ge "$_pause" ] 2>/dev/null; }
    TMPDIR=/data/local/tmp/.t151-null; mkdir -p $TMPDIR 2>/dev/null || :
    flip_sw(){ echo RESTORED; exit 0; }
    hand_back_or_hold
    echo HELD ) 2>/dev/null
}
# The stub must be able to answer both ways, or every row below is the same row.
[ "$( ( _lvl=95; _pause=75; at_or_above_pause(){ [ "$_lvl" -ge "$_pause" ]; }; at_or_above_pause && echo Y || echo N ) )" = Y ] \
  && [ "$( ( _lvl=40; _pause=75; at_or_above_pause(){ [ "$_lvl" -ge "$_pause" ]; }; at_or_above_pause && echo Y || echo N ) )" = N ] \
  && ok "the level stub discriminates, so the matrix below is driven and not constant" \
  || no "the level stub answers the same way at 40% and 95% - the matrix is meaningless"
printf '  %-34s %-8s %-8s %s\n' node level pause decision
for row in "battery/input_suspend 40 75" "battery/input_suspend 75 75" "battery/input_suspend 95 75" \
           "battery/voltage_max 95 75" "battery/voltage_max 40 75"; do
  set -- $row
  printf '  %-34s %-8s %-8s %s\n' "$1" "$2" "$3" "$(decide "$1" "$2" "$3")"
done
[ "$(decide battery/input_suspend 40 75)" = RESTORED ] \
  && ok "below the limit a failed candidate is handed back, so discovery never slows a healthy charge" \
  || no "a failed candidate stayed cut on a healthy charge - the a39358d fault"
[ "$(decide battery/input_suspend 95 75)" = HELD ] \
  && ok "at the limit it is held, so a fan-out does not re-arm charging once per candidate" \
  || no "a failed candidate re-armed charging while a pause was the point of the sweep"
[ "$(decide battery/voltage_max 95 75)" = RESTORED ] \
  && ok "a voltage candidate is restored at every level" \
  || no "a float-voltage ceiling was left applied"

# ---- 3. what is held has an owner --------------------------------------------------------------
printf '%s' "$_hb" | grep -q 'sweep-held' \
  && ok "a held candidate is recorded" || no "a held candidate is not recorded anywhere"
grep -q '^release_unowned_probes() {' "$MF" \
  && ok "a releaser exists" || no "no releaser exists"
_tail=$(printf '%s\n' "$_cyc" | sed -n '/_swAdopted/,$p')
printf '%s' "$_tail" | grep -q 'release_unowned_probes' \
  && ok "the sweep releases on the no-adoption path" \
  || no "release_unowned_probes is never reached from the sweep"
printf '%s' "$_tail" | sed -n '/-n "${_swAdopted-}"/,/else/p' | grep -q 'release_unowned_probes' \
  && no "the release also runs when a switch WAS adopted, which would un-cut it" \
  || ok "the release does not run when a switch was adopted"
printf '%s\n' "$_cyc" | grep -q 'rm -f \$TMPDIR/.sweep-held' \
  && ok "the record is cleared on entry, so a killed sweep cannot hand back a node a later one adopts" \
  || no "a stale record can survive into the next sweep"

# ---- 4. the releaser itself, driven --------------------------------------------------------------
_ru=$(sed -n '/^release_unowned_probes() {/,/^}/p' "$MF")
_T=${TMPDIR:-/data/local/tmp}/.t151
mkdir -p "$_T" 2>/dev/null || :
printf '%s\n' "battery/input_suspend 1 0" "usb/current_max 0 2000000" > "$_T/.sweep-held"
_got=$( ( eval "$_ru"
          TMPDIR=$_T
          chargingSwitch=()
          flip_sw(){ echo "on:${chargingSwitch[0]}"; }
          release_unowned_probes ) 2>/dev/null )
_cnt=$(printf '%s\n' "$_got" | grep -c '^on:')
[ "$_cnt" -eq 2 ] \
  && ok "every recorded node is handed back ($_cnt of 2)" \
  || no "expected 2 restores from the record, got $_cnt: $_got"
printf '%s' "$_got" | grep -q 'on:battery/input_suspend' && printf '%s' "$_got" | grep -q 'on:usb/current_max' \
  && ok "each restore names the node it was recorded for" \
  || no "the restores do not match the recorded nodes: $_got"
[ -f "$_T/.sweep-held" ] \
  && no "the record survives the release, so the next sweep would replay it" \
  || ok "the record is removed once released"
# An empty record must not error, and must not restore anything.
_empty=$( ( eval "$_ru"; TMPDIR=$_T; chargingSwitch=(); flip_sw(){ echo on; }; release_unowned_probes; echo RC=$? ) 2>&1 )
case "$_empty" in
  *on*) no "an empty record still restored something" ;;
  *RC=0*) ok "an empty record is a clean no-op" ;;
  *) no "an empty record did not return cleanly: $_empty" ;;
esac
rm -rf "$_T" 2>/dev/null || :

# ---- 5. the runtime backstop --------------------------------------------------------------------
grep -q '_ge_pause_cap; } && ! not_charging' "$AD" \
  && ok "the breach monitor still watches for a level that got past the limit during a sweep" \
  || no "nothing at runtime catches a level that creeps past"

fin
