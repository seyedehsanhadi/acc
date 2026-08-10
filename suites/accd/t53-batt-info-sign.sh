#!/system/bin/sh
# t53 - the numbers AccA's dashboard renders: current, voltage, wattage, and their SIGN.
#
# WHY THE SIGN IS THE WHOLE TEST
#   The kernel's current_now sign is a per-device accident, not a convention. A Mi A3 draining
#   1.19A reports +1194458 with status Discharging; a Pixel 6a draining reports -342812. batt_info
#   used to pass the raw value through, so on one of the two phones here the dashboard read
#   "+1.26A / 4.65W" for a battery that was emptying - wrong number, wrong sign, and wrong in the
#   direction that looks like fast charging.
#
#   ACC has already answered this question by the time batt_info runs: _status is the output of the
#   full arbitration chain in idle_discharging. The fix takes the magnitude from the gauge and the
#   sign from that verdict. This suite asserts it for every combination of raw sign and verdict.
#
# NO HARDWARE.

ID=t53
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
chk(){ [ "$3" = "$2" ] && ok "$1" || no "$1  (expected '$2', got '$3')"; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=$execDir/batt-info.sh

[ -f "$BI" ] || { no "batt-info.sh not found at $BI"; fin; }

# ---- the normalization, lifted verbatim -----------------------------------------------------------
# Extracted rather than retyped: a test that reasserts a copy of the logic passes forever after the
# shipped code drifts away from it.
_norm=$(sed -n '/# NORMALIZE THE SIGN/,/^  esac$/p' "$BI" | sed -n '/^  case /,/^  esac$/p')
[ -n "$_norm" ] || { no "could not extract the sign normalization from batt-info.sh"; fin; }

norm() {
  _status=$1
  currNow=$2
  eval "$_norm"
  echo "$currNow"
}

# calc2 formats %.2f, so every value here is in the shape batt_info actually produces.
chk "discharging, gauge reads positive -> negative"   "-1.26"  "$(norm Discharging 1.26)"
chk "discharging, gauge already negative -> unchanged" "-0.31" "$(norm Discharging -0.31)"
chk "charging, gauge reads negative -> positive"       "2.41"  "$(norm Charging -2.41)"
chk "charging, gauge already positive -> unchanged"    "1.95"  "$(norm Charging 1.95)"

# Zero must never acquire a sign. "-0.00 A" on a dashboard reads like a measurement, not a nothing.
chk "discharging at 0.00 stays 0.00"  "0.00" "$(norm Discharging 0.00)"
chk "discharging at 0 stays 0"        "0"    "$(norm Discharging 0)"
chk "discharging at 0.0 stays 0.0"    "0.0"  "$(norm Discharging 0.0)"
chk "charging at 0.00 stays 0.00"     "0.00" "$(norm Charging 0.00)"

# Idle is the third verdict and it is NOT a direction. Below idleThreshold the sign is noise, and
# forcing one would invent a claim the gauge cannot support.
chk "idle leaves a positive reading alone"  "0.04"  "$(norm Idle 0.04)"
chk "idle leaves a negative reading alone"  "-0.04" "$(norm Idle -0.04)"
chk "an empty status leaves the value alone" "1.10" "$(norm '' 1.10)"

# Large and small magnitudes survive intact - only the sign is ours to set.
chk "a 9A charge keeps its magnitude"      "9.87" "$(norm Charging -9.87)"
chk "a 10mA drain keeps its magnitude"    "-0.01" "$(norm Discharging 0.01)"

# ---- power follows current ------------------------------------------------------------------------
# powerNow is computed from currNow AFTER normalization. If it were computed before, the dashboard
# would show a negative current beside a positive wattage.
_ln_norm=$(grep -n "NORMALIZE THE SIGN" "$BI" | cut -d: -f1)
_ln_pow=$(grep -n "powerNow=\$(calc2" "$BI" | cut -d: -f1)
if [ -n "$_ln_norm" ] && [ -n "$_ln_pow" ] && [ "$_ln_norm" -lt "$_ln_pow" ] 2>/dev/null; then
  ok "power_now is computed after the sign is settled, so the wattage sign agrees with the current"
else
  no "power_now is computed before normalization - current and wattage would disagree in sign"
fi

# And the arithmetic itself, using the real formula.
w(){ awk "BEGIN {printf \"%.2f\", $1 * $2}"; }
chk "3.69V x -1.26A = -4.65W"  "-4.65" "$(w 3.69 -1.26)"
chk "3.81V x -0.31A = -1.18W"  "-1.18" "$(w 3.81 -0.31)"
chk "9.00V x 2.00A = 18.00W"   "18.00" "$(w 9.00 2.00)"

# ---- the charger-side block -----------------------------------------------------------------------
# Same defect, other end: the gate that decides whether to print the charger's W/V/A at all.
_gate=$(grep -n 'power_supply_amps' "$BI" | grep 'if \[' | head -1)
case "$_gate" in
  *'%.*'*) no "the supply gate still does integer arithmetic on a signed value - builds '0-0' and errors out" ;;
  *'#-'*)  ok "the supply gate tests an absolute value, so an inverted-sign phone still shows charger W/V/A" ;;
  *)       no "could not identify the supply-amps gate" ;;
esac

sgate(){ [ "${1#-}" != 0.00 ] && echo show || echo hide; }
chk "supply drawing 1.50A -> shown"   show "$(sgate 1.50)"
chk "supply drawing -1.50A -> shown"  show "$(sgate -1.50)"
chk "supply at 0.00A -> hidden"       hide "$(sgate 0.00)"
chk "supply at -0.00A -> hidden"      hide "$(sgate -0.00)"
chk "supply at 0.01A -> shown"        show "$(sgate 0.01)"

# ---- unit conversion ------------------------------------------------------------------------------
# dtr_conv_factor picks uA vs mA from the magnitude. Getting it wrong is a 1000x error on the
# dashboard, which is how a 0.3A drain becomes 310A.
_f=$(sed -n '/^  dtr_conv_factor() {/,/^  }$/p' "$BI")
if [ -n "$_f" ]; then
  eval "$_f"
  dtr_conv_factor 310312;  chk "310312 (uA) -> divide by 1000000" 1000000 "$factor"
  dtr_conv_factor 1500;    chk "1500 (mA) -> divide by 1000"      1000    "$factor"
  dtr_conv_factor 15999;   chk "15999 is still mA"                1000    "$factor"
  dtr_conv_factor 16000;   chk "16000 crosses into uA"            1000000 "$factor"
  dtr_conv_factor 0;       chk "0 needs no conversion"            1       "$factor"
  dtr_conv_factor 310312 1000; chk "a calibrated ampFactor wins over the guess" 1000 "$factor"
else
  no "could not extract dtr_conv_factor"
fi

fin
