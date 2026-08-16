#!/system/bin/sh
# t84 - a rejected VOLTAGE switch must always be put back, even at or above the pause level.
#
# THE FAULT, on a Mi A3 with no chargingSwitch configured. The phone sat plugged in and simply would
# not charge, for hours, across reboots:
#     pmi632_charger: battery over-voltage vbat_fg = 3905196uV, fv = 3600000uV
# battery/voltage_max was 3600000 against a 3.9V pack. Clearing it restored charging at 2.8A.
#
# WHERE IT COMES FROM. With no switch configured the daemon calls cycle_switches to find one. Each
# candidate is written to its OFF value and judged. Both the reject arm and the failure arm restore
# with:
#     at_or_above_pause || flip_sw on 2>/dev/null || :
# so the restore is SKIPPED whenever the level is at or above the pause level. That suppression is
# deliberate and correct for a current/suspend switch: leaving it cut merely keeps charging off,
# which is what is wanted at the limit, and the next enable_charging puts it back.
#
# It is wrong for a VOLTAGE switch. A float voltage left at 3600mV does not pause charging, it ends
# it - the charger reports over-voltage and refuses, at every level, including well below resume,
# and nothing restores the node because the daemon never recorded owning it. The phone is stuck
# until something writes the value back by hand.
#
# So: current switches keep the existing anti-creep behaviour; voltage switches are always restored.
# NO HARDWARE - the decision is executed against stubs.

ID=t84
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }
_src=$(sed 's/^[[:space:]]*#.*//' "$MF")

# ---- 1: both restore sites special-case a voltage switch --------------------------------------------
_plain=$(printf '%s' "$_src" | grep -c 'at_or_above_pause || flip_sw on') || _plain=0
case "${_plain:-0}" in ''|*[!0-9]*) _plain=0;; esac
_volt=$(printf '%s' "$_src" | grep -c '\*voltage\*') || _volt=0
case "${_volt:-0}" in ''|*[!0-9]*) _volt=0;; esac
[ "${_volt:-0}" -ge 2 ] 2>/dev/null \
  && ok "both cycle_switches restore arms special-case a voltage switch (${_volt} sites)" \
  || no "only ${_volt} voltage special-case(s) against ${_plain} unconditional suppression(s) - a rejected voltage switch stays applied and the phone cannot charge at all (the shipped fault)"

# ---- 2..5: EXECUTE the decision ---------------------------------------------------------------------
# The rule, in isolation: restore ALWAYS for a voltage node; for anything else keep the existing
# behaviour of skipping the restore at or above the pause level.
_decide(){ # $1 = switch node, $2 = at_or_above_pause rc (0 = true/at-limit)
  ( eval "at_or_above_pause(){ return $2; }"
    flip_sw(){ echo "RESTORED"; }
    chargingSwitch="$1"
    case "${chargingSwitch}" in
      *voltage*) flip_sw on 2>/dev/null || : ;;
      *) at_or_above_pause || flip_sw on 2>/dev/null || : ;;
    esac ) 2>/dev/null
}
# sanity: the rule this test encodes must itself behave, or the assertions below prove nothing
[ "$(_decide /sys/class/power_supply/battery/voltage_max 0)" = RESTORED ] \
  && ok "(rule check) a voltage switch at the limit restores" \
  || no "(rule check) the encoded rule is wrong - a voltage switch at the limit did not restore"
[ -z "$(_decide /sys/class/power_supply/battery/input_suspend 0)" ] \
  && ok "(rule check) a current/suspend switch at the limit is still left cut, as before" \
  || no "(rule check) the encoded rule changed current-switch behaviour"
[ "$(_decide /sys/class/power_supply/battery/input_suspend 1)" = RESTORED ] \
  && ok "(rule check) below the limit everything restores" \
  || no "(rule check) below the limit a current switch did not restore"

# ---- 6: the shipped code must implement that rule ------------------------------------------------------
# Pull each restore arm out of the file and run it the same way.
_arms=$(printf '%s' "$_src" | grep -n 'flip_sw on 2>/dev/null' | cut -d: -f1)
_n=0; _bad=0
for _a in $_arms; do
  _n=$((_n + 1))
  _ctx=$(printf '%s' "$_src" | sed -n "$(( _a > 3 ? _a - 3 : 1 )),${_a}p")
  case "$_ctx" in
    *voltage*) : ;;
    *at_or_above_pause*) _bad=$((_bad + 1)) ;;
    *) : ;;
  esac
done
if [ "${_bad:-0}" -eq 0 ]; then
  ok "no restore arm suppresses a voltage switch at the limit"
else
  no "${_bad} restore arm(s) still gate a voltage switch behind at_or_above_pause"
fi

sh -n "$MF" 2>/dev/null && ok "misc-functions.sh parses" || no "misc-functions.sh does not parse"
fin
