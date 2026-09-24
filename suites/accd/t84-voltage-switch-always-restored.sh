#!/system/bin/sh
# t84 - every rejected charging-switch candidate must be put back.
#
# THE FAULT, on a Mi A3 with no chargingSwitch configured. The phone sat plugged in and simply would
# not charge, for hours, across reboots:
#     pmi632_charger: battery over-voltage vbat_fg = 3905196uV, fv = 3600000uV
# battery/voltage_max was 3600000 against a 3.9V pack. Clearing it restored charging at 2.8A.
#
# WHERE IT COMES FROM. With no switch configured the daemon calls cycle_switches to find one. Each
# candidate is written to its OFF value and judged. Rejected candidates used to remain cut whenever
# the battery was at its pause level, even though ACC had not adopted them and therefore owned no
# reliable release path.
#
# It is wrong for a VOLTAGE switch. A float voltage left at 3600mV does not pause charging, it ends
# it - the charger reports over-voltage and refuses, at every level, including well below resume,
# and nothing restores the node because the daemon never recorded owning it. The phone is stuck
# until something writes the value back by hand.
#
# It is also wrong for current-cap and binary switches. On Mi A3, a rejected
# constant_charge_current_max=0 took effect late, and a later run rejected every candidate but left
# input_suspend=1. Both made resume depend on a full restore sweep and miss 150 seconds. A rejected
# switch is not protection: restore every candidate; only an adopted switch may hold a cut.

ID=t84
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }
_cycle=$(awk '/^cycle_switches\(\) \{/,/^}/' "$MF")
[ -n "$_cycle" ] || { no "cycle_switches not found"; fin; }

_n=$(printf '%s\n' "$_cycle" | grep -c '^[[:space:]]*hand_back_or_hold$') || _n=0
[ "${_n:-0}" -eq 2 ] \
  && ok "both rejected-candidate arms go through the same decision" \
  || no "expected 2 hand_back_or_hold call sites, found ${_n:-0}"

# The point of THIS suite: a voltage candidate is restored at every level, because its off value is
# a float-voltage ceiling that ends charging rather than pausing it. Driven, not pattern-matched.
_hb=$(sed -n '/^hand_back_or_hold() {/,/^}/p' "$MF")
[ -n "$_hb" ] || { no "hand_back_or_hold not found"; fin; }
# _lvl/_pause come from the enclosing scope. A stub defined in here has its OWN positional
# parameters, so reading $2/$3 inside it compares empty strings and the matrix stops discriminating.
decide(){ # $1 node, $2 level, $3 pause level -> RESTORED | HELD
  ( eval "$_hb"
    _lvl=$2; _pause=$3
    set -A chargingSwitch "$1" 1 0
    capacity[3]=$_pause
    at_or_above_pause(){ [ "$_lvl" -ge "$_pause" ] 2>/dev/null; }
    TMPDIR=/data/local/tmp/.t84-null; mkdir -p $TMPDIR 2>/dev/null || :
    flip_sw(){ echo RESTORED; exit 0; }
    hand_back_or_hold
    echo HELD ) 2>/dev/null
}
[ "$(decide battery/voltage_max 95 75)" = RESTORED ] \
  && ok "a voltage candidate is restored even at 95% against a 75% pause" \
  || no "a voltage candidate was left applied above the pause level"
[ "$(decide battery/voltage_max 40 75)" = RESTORED ] \
  && ok "a voltage candidate is restored below the pause level too" \
  || no "a voltage candidate was left applied below the pause level"
[ "$(decide battery/input_suspend 40 75)" = RESTORED ] \
  && ok "a current/suspend candidate below the pause level is handed back" \
  || no "a current candidate was left cut on a healthy charge"
[ "$(decide battery/input_suspend 95 75)" = HELD ] \
  && ok "a current/suspend candidate at the pause level is held, not re-armed into a climbing level" \
  || no "a current candidate re-armed charging while a pause was what the sweep was for"

grep -q '^release_unowned_probes() {' "$MF" \
  && ok "and what is held has a releaser when the sweep adopts nothing" \
  || no "a held candidate has no releaser - the Mi A3 strand is back"

sh -n "$MF" 2>/dev/null && ok "misc-functions.sh parses" || no "misc-functions.sh does not parse"
fin
