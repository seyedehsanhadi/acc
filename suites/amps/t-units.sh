#!/system/bin/sh
AMPS=${AMPS:-./amps.sh}
T=$(mktemp -d "${TMPDIR:-/data/local/tmp}/amps-units.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
P=0; F=0
ck(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL $1: got=$2 expected=$3"; fi; }
w(){ mkdir -p "${1%/*}"; printf '%s\n' "$2" > "$1"; }
eval "$(sed -n '/^node_unit(){/,/^}/p' "$AMPS"; grep -E '^(rd|read1|san|abs|rd_current|rd_ma|_norm|is_idle)\(\)' "$AMPS" | grep -v '^_norm')"
eval "$(sed -n '/^_norm(){/,/^learn_chgdir()/{ /^learn_chgdir()/!p; }' "$AMPS")"
eval "$(sed -n '/^classify_state(){/,/^minimize_combo()/{ /^minimize_combo()/!p; }' "$AMPS")"
PSY=$T; BATT=$T/battery; CURF=$BATT/current_now; CHGIN=$T/usb/input_current_now; HAVE_TO=0
w "$CURF" -895; w "$T/bms/current_now" -822265
w "$BATT/constant_charge_current_max" 5400000; w "$CHGIN" 1189550
CUR_UNIT=$(node_unit "$CURF"); CHGIN_UNIT=$(node_unit "$CHGIN")
ck oneplus-unit "$CUR_UNIT" mA
ck oneplus-battery "$(rd_ma "$CURF")" -895
ck oneplus-bms "$(rd_ma "$T/bms/current_now")" -822
ck oneplus-input "$(rd_ma "$CHGIN")" 1189
ck oneplus-baseline "$(classify_state 1 1 "$(rd_ma "$CURF")" inverted 10)" CHARGING
w "$BATT/constant_charge_current_max" 50
ck control-independent "$(CUR_UNIT=; node_unit "$CURF")" mA
for u in mA uA; do
 CUR_UNIT=$u
 for ma in -2000 -51 -50 -11 -10 -1 0 1 10 11 50 51 2000; do
  raw=$ma; [ "$u" = uA ] && raw=$((ma * 1000))
  w "$CURF" "$raw"
  ck "$u/$ma" "$(rd_ma "$CURF")" "$ma"
 done
done
CUR_UNIT=uA
for raw in 15999 16000 99999 100000; do
 w "$CURF" "$raw"; ck "boundary/$raw" "$(rd_ma "$CURF")" "$((raw / 1000))"
done
w "$CURF" -999; ck negative-sub-mA "$(rd_ma "$CURF")" 0
CUR_UNIT=mA; CHGIN_UNIT=uA
w "$CURF" -12; w "$CHGIN" 5000
ck mixed-battery "$(rd_ma "$CURF")" -12
ck mixed-input "$(rd_ma "$CHGIN")" 5
w "$T/bms/current_now" 0; w "$CHGIN" 2000000; w "$CURF" 1000
CUR_UNIT=; ST_UNIT=
ck ambiguous "$(node_unit "$CURF")" unknown
ck ambiguous-read "$(rd_ma "$CURF" || echo unavailable)" unavailable
ST_UNIT=uA; ck learned-uA "$(rd_ma "$CURF")" 1
ST_UNIT=mA; ck learned-mA "$(rd_ma "$CURF")" 1000
AMPS_CURRENT_UNIT=uA; ck override "$(rd_ma "$CURF")" 1
AMPS_CURRENT_UNIT=mA; w "$CURF" 20000; ck high-current-mA-override "$(rd_ma "$CURF")" 20000
AMPS_CURRENT_UNIT=; ST_UNIT=; CUR_UNIT=
w "$CURF" 100; w "$T/bms/current_now" 2000000
ck unrelated-bms "$(node_unit "$CURF")" unknown
CUR_UNIT=mA
for raw in '' n/a --1 999999999999999999999999; do
 w "$CURF" "$raw"; ck "invalid/$raw" "$(rd_ma "$CURF" || echo unavailable)" unavailable
done
w "$CURF" '+000895 mA'; ck signed-leading-zero "$(rd_ma "$CURF")" 895
ck missing "$(rd_ma "$T/missing" || echo unavailable)" unavailable
IDLE=10; ck missing-not-idle "$(is_idle unknown)" 0
if grep -qE 'san "\$\(read1 "\$(CURF|CHGIN)"' "$AMPS"; then ck raw-consumers present absent; else ck raw-consumers absent absent; fi
ck precision-mA "$(rd_current "$CURF")" 895000
CUR_UNIT=uA
for raw in -10001 -10000 -9999 -1 0 1 9999 10000 10001 49999 50000 50001; do
 w "$CURF" "$raw"; ck "exact-uA/$raw" "$(rd_current "$CURF")" "$raw"
done
if grep -q 'UNIT=mA; THR=' "$AMPS"; then ck thresholds variable fixed; else ck thresholds fixed fixed; fi
eval "$(sed -n '/^chg_now(){/,/^resume_desc()/{ /^resume_desc()/!p; }' "$AMPS")"
BLINDV=0; CUR_USABLE=1
med_cur(){ echo unknown; }
ck missing-not-resumed "$(chg_now)" 0
eval "$(grep '^_mA()' "$AMPS")"
ck missing-display "$(_mA unknown)" n/a
ck negative-sub-mA-display "$(_mA -999)" 0
AMPS_CURRENT_UNIT=typo
ck invalid-override "$(node_unit "$CURF")" unknown
eval "$(grep -E '^(voltage_mv|voltage_uv)\(\)' "$AMPS")"
for pair in '4200000:4200' '4200:4200' '+004200:4200' '-4200000:0' 'x:0' '0:0' '999999999999999999999:0'; do
 w "$BATT/voltage_now" "${pair%:*}"
 ck "voltage-$pair" "$(voltage_mv "$BATT/voltage_now")" "${pair#*:}"
done
# OnePlus 8 Pro (IN2023, kona, oplus), reported against rc24/7.3.1: mA battery node, uA control
# nodes, uA input node, and no bms to cross-check. It logged "unit corrected to uA" -> BYPASS ->
# "could NOT reach native charging". A peer settles the unit only at a ratio near 1000: input and
# battery current differ physically by at most about 3x.
CUR_UNIT=; CHGIN_UNIT=; ST_UNIT=; AMPS_CURRENT_UNIT=
rm -f "$T/bms/current_now"
w "$CURF" -1500; w "$BATT/constant_charge_current" 3000000; w "$CHGIN" 1650000
ck oneplus8-unit "$(node_unit "$CURF")" mA
ck oneplus8-read "$(rd_ma "$CURF")" -1500
ck oneplus8-baseline "$(classify_state 1 1 "$(rd_current "$CURF")" inverted 10000)" CHARGING
# The shape that must NOT resolve: a uA phone idling at 8 mA while the charger runs the load.
w "$CURF" -8000; w "$CHGIN" 2000000
ck load-ratio-no-verdict "$(node_unit "$CURF")" unknown

printf 't-units: %s passed, %s failed\n' "$P" "$F"
[ "$F" = 0 ]
