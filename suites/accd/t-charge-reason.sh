#!/system/bin/sh
# Why a plugged phone is charging slowly, on the OnePlus 8 Pro report of 2026-09-11.
#
# His shot: max_charging_current 1800 mA, max_charging_voltage 4000 mV, pack resting at 4008 mV,
# 181 mA going in. ACC answered "user_limit" and AccA printed "your Max current cap is applied".
# The cap was nowhere near 181 mA; the ceiling he had set below his own pack voltage was the block,
# and there was no reason code for that at all. user_limit also sat FIRST, so any phone with a cap
# set could never be told it was hot or tapering.
#
# Also here: the input wattage used to be withheld below 50 mA while the amps were still printed,
# so his second shot read "5.1 V - 0.03 A - (nothing) W input".

ID=t-charge-reason
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SE=${SE:-$execDir/state-export.sh}
[ -f "$SE" ] || { no "missing $SE"; fin; }

# charge <mcc> <mcv> <inMv> <inMa> <battCurUa> <battMv> <status> <tempDeci> <cap> <measuredClass>
charge() {
  ( . "$SE" 2>/dev/null || :
    maxChargingCurrent=($1); maxChargingVoltage=($2)
    _se_charge "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" )
}
field() { # field <json> <key>
  echo "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p"
}

echo "--- 1. the reporter's own numbers"
J=$(charge 1800 4000 5100 480 181000 4008000 Charging 290 59 charging)
r=$(field "$J" reason)
[ ".$r" = '."voltage_limit"' ] \
  && ok "a 4000 mV ceiling under a 4008 mV pack is named as the block: $r" \
  || no "expected voltage_limit, got $r   ($J)"

echo "--- 2. a cap that is nowhere near the current must not take the blame"
J=$(charge 1800 '' 5100 480 181000 4008000 Charging 290 59 charging)
r=$(field "$J" reason)
[ ".$r" = .null ] \
  && ok "1800 mA cap against 181 mA in explains nothing, so no reason is claimed" \
  || no "expected null, got $r   ($J)"

echo "--- 3. a cap that DOES bind still reports user_limit"
J=$(charge 500 '' 5100 600 480000 3900000 Charging 290 60 charging)
r=$(field "$J" reason)
[ ".$r" = '."user_limit"' ] && ok "480 mA against a 500 mA cap is the cap: $r" \
  || no "expected user_limit, got $r   ($J)"

echo "--- 4. an input-side cap binds too (Tensor caps the CHARGER input, not the battery)"
J=$(charge 500 '' 9000 490 100000 3900000 Charging 290 60 charging)
r=$(field "$J" reason)
[ ".$r" = '."user_limit"' ] && ok "490 mA input against a 500 mA cap is the cap: $r" \
  || no "expected user_limit, got $r   ($J)"

echo "--- 5. a hot battery is reachable again with a cap set"
J=$(charge 1800 '' 5100 480 181000 3900000 Charging 430 59 charging)
r=$(field "$J" reason)
[ ".$r" = '."thermal"' ] && ok "43.0 C is reported even though a cap exists: $r" \
  || no "expected thermal, got $r   ($J)"

echo "--- 6. so is a taper"
J=$(charge 1800 '' 5100 480 181000 4300000 Charging 300 96 charging)
r=$(field "$J" reason)
[ ".$r" = '."taper"' ] && ok "96% with a cap set is still a taper: $r" \
  || no "expected taper, got $r   ($J)"

echo "--- 7. a ceiling ABOVE the pack is not a block"
J=$(charge '' 4400 5100 480 900000 4008000 Charging 290 59 charging)
r=$(field "$J" reason)
[ ".$r" = .null ] && ok "4400 mV over a 4008 mV pack blocks nothing, so nothing is claimed" \
  || no "expected null, got $r   ($J)"

echo "--- 8. 30 mA of input is a measurement, not a rounding error"
J=$(charge '' '' 5100 30 -233000 3938000 'Not charging' 290 59 bypass)
w=$(field "$J" watts)
case "$w" in null|'') no "input watts still withheld at 30 mA: $w   ($J)";; *) ok "30 mA at 5.1 V is reported as $w W";; esac

echo "--- 9. an unreadable input is still not zero watts"
J=$(charge '' '' 5100 null -233000 3938000 'Not charging' 290 59 bypass)
w=$(field "$J" watts)
[ ".$w" = .null ] && ok "a missing input current yields no wattage, as before" \
  || no "an unreadable input invented $w W   ($J)"

echo "--- 10. a held phone reports input power with no class, unchanged"
J=$(charge '' '' 5100 160 0 3956000 'Not charging' 310 60 bypass)
w=$(field "$J" watts); c=$(field "$J" class)
[ ".$c" = .null ] && [ ".$w" != .null ] \
  && ok "bypass keeps watts ($w) and claims no charge class" \
  || no "held-phone row changed: watts=$w class=$c   ($J)"

fin
