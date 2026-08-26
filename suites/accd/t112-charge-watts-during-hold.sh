#!/system/bin/sh
# t112 - the charger's measured input power must survive a hold.
#
# THE REPORT. On a Mi A3 held at its pause level, `acca --state` reported "charge":{"watts":null}
# while the phone was drawing 1797 mA from the wall to run itself. Every consumer read that as
# "no charger attached": AccA hid its "From charger" row on a phone with the cable in.
#
# CAUSE. _se_charge() computed everything -- including the measured input watts -- inside
# `if [ "$st" = "Charging" ]`. Input power is measured, not inferred, and is real whether or not
# the battery is taking it.
#
# CONTRACT UNDER TEST
#   watts    non-null whenever input volts x amps are readable, in ANY status.
#   class    charging only. slow/fast describes how fast the battery FILLS; during a hold it is
#            not filling, so a class would be a claim about something that is not happening.
#   approx   only ever set by the battery-side fallback, which stays charging-only.
#
# So "watts non-null with class null" is the signature of a hold, and that is what a consumer
# should key off. This suite pins that pairing in both directions.
#
# NO HARDWARE - drives _se_charge() directly with synthetic readings.

ID=t112
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SE=$execDir/state-export.sh
[ -f "$SE" ] || { no "state-export.sh not found at $SE"; fin; }

# _se_charge needs _se_ma from the same file; source it and stub what it expects.
maxChargingCurrent=
. "$SE" 2>/dev/null || { no "could not source state-export.sh"; fin; }
command -v _se_charge >/dev/null 2>&1 || { no "_se_charge not defined after sourcing"; fin; }

# field extraction from the emitted JSON fragment
_f(){ printf '%s' "$1" | sed 's/.*"'"$2"'":\([^,}]*\).*/\1/'; }

# args: inMv inMa battCur battVolt status tempDeciC capacityPct
say(){ _se_charge "$@"; }

# --- 1. charging: watts AND class, as before ---------------------------------
j=$(say 9000 2000 2500000 4000000 Charging 300 50)
[ "$(_f "$j" watts)" = 18 ] && ok "charging: 9V x 2A reported as 18 W" \
                            || no "charging: watts was $(_f "$j" watts), expected 18"
[ "$(_f "$j" class)" = '"fast"' ] && ok "charging: 18 W classified fast" \
                                  || no "charging: class was $(_f "$j" class), expected fast"

# --- 2. THE REGRESSION: held, charger still supplying the phone --------------
# The A3's own reading: input 7.5 V at 1797 mA, battery flowing OUT at -170 mA.
j=$(say 7500 1797 -170000 3750000 Discharging 270 19)
w=$(_f "$j" watts)
[ "$w" != null ] && [ "$w" -ge 12 ] 2>/dev/null && [ "$w" -le 15 ] 2>/dev/null \
  && ok "held: measured input still reported ($w W)" \
  || no "held: watts was $w - a charger delivering 13 W read as no charger"
[ "$(_f "$j" class)" = null ] && ok "held: no class, because the battery is not filling" \
                              || no "held: class was $(_f "$j" class), expected null"
[ "$(_f "$j" approx)" = false ] && ok "held: not marked approx - this is a measured figure" \
                                || no "held: approx was $(_f "$j" approx), expected false"

# --- 3. "Not charging" is the same case with a different word ----------------
j=$(say 9000 1300 -400000 3800000 "Not charging" 300 38)
[ "$(_f "$j" watts)" != null ] && ok "Not charging: input power still reported" \
                               || no "Not charging: watts went null"
[ "$(_f "$j" class)" = null ] && ok "Not charging: class stays null" \
                             || no "Not charging: class was $(_f "$j" class)"

# --- 4. genuinely unplugged must stay null ----------------------------------
j=$(say null null -300000 3700000 Discharging 300 40)
[ "$(_f "$j" watts)" = null ] && ok "unplugged: no input nodes -> watts null" \
                              || no "unplugged: watts was $(_f "$j" watts), expected null"

# a charger reporting a trickle below the noise floor is not a charger
j=$(say 5000 20 -300000 3700000 Discharging 300 40)
[ "$(_f "$j" watts)" = null ] && ok "noise floor: 20 mA input ignored" \
                              || no "noise floor: watts was $(_f "$j" watts), expected null"

# --- 4b. a suspended input must not report its stale current -----------------
# Measured on a Mi A3 with input_suspend=1: usb/input_current_now still read 2084 mA while
# usb/online, usb/current_max and usb/input_current_settled were all 0. The kernel never clears
# that node on a cut, so the last value before the cut sits there indefinitely.
command -v _se_gate_ma >/dev/null 2>&1 || { no "_se_gate_ma not defined"; fin; }
_se_gate_ma 0 2084; [ "$_segma" = 0 ] && ok "offline supply: stale 2084 mA zeroed"                                       || no "offline supply: reported $_segma mA from a dead input"
_se_gate_ma 1 1994; [ "$_segma" = 1994 ] && ok "online supply: reading passes through"                                          || no "online supply: mangled 1994 to $_segma"
_se_gate_ma 0 null; [ "$_segma" = null ] && ok "offline with no reading stays null"                                          || no "offline null became $_segma"
# a device with no online node has never been gated and must not start reading 0
_se_gate_ma "" 1500; [ "$_segma" = 1500 ] && ok "no online node: reading trusted"                                           || no "no online node: reading became $_segma"

# and end to end: an offline input yields no wattage, not a phantom one
j=$(say 8440 0 470000 3780000 Discharging 280 27)
[ "$(_f "$j" watts)" = null ] && ok "held with a suspended input: no phantom wattage"                               || no "held: invented $(_f "$j" watts) W from a suspended input"

# --- 5. the battery-side fallback stays charging-only -----------------------
# No input nodes, but charging: the old approx path must still work.
j=$(say null null 2000000 4000000 Charging 300 50)
[ "$(_f "$j" watts)" != null ] && ok "charging with no input nodes: battery-side fallback used" \
                               || no "charging fallback: watts went null"
[ "$(_f "$j" approx)" = true ] && ok "charging fallback: marked approx" \
                               || no "charging fallback: approx was $(_f "$j" approx)"
# ...and must NOT fire during a hold, where battery current flows the wrong way
j=$(say null null -2000000 4000000 Discharging 300 50)
[ "$(_f "$j" watts)" = null ] && ok "held with no input nodes: no fabricated wattage" \
                              || no "held: invented $(_f "$j" watts) W from a DRAINING battery"

fin
