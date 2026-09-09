#!/system/bin/sh
execDir=${execDir:-install}
execDir=$(cd "$execDir" && pwd)
AMPS=${AMPS:-./amps.sh}
matrix=${matrix:-suites/sensor-matrix.tsv}
. "$execDir/state-export.sh"
eval "$(sed -n '/^current_now() {/,/^}/p' "$execDir/batt-interface.sh")"
eval "$(grep -E '^(rd|read1|san|abs|rd_current|rd_ma|voltage_mv|voltage_uv|power_mw)\(\)' "$AMPS")"
eval "$(sed -n '/^_norm(){/,/^learn_chgdir()/{ /^learn_chgdir()/!p; }' "$AMPS")"
eval "$(sed -n '/^classify_state(){/,/^minimize_combo()/{ /^minimize_combo()/!p; }' "$AMPS")"
W=$(mktemp -d "${TMPDIR:-/data/local/tmp}/sensor-matrix.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
currFile=$W/current_now
P=0; F=0; N=0
check(){ P=$((P+1)); if [ "$1" != "$2" ]; then F=$((F+1)); [ "$F" -gt 20 ] || printf 'FAIL id=%s %s %s got=%s expected=%s\n' "$id" "$family" "$3" "$1" "$2"; fi; }
tab=$(printf '\t')
while IFS="$tab" read -r id family vr ir vf af pol mv ma watts ua signed exact uv mw; do
 [ "$id" != id ] || continue
 N=$((N+1))
 [ $((N % 100)) -ne 0 ] || echo "sensor-matrix progress: $N scenarios"
 [ "$vr" != '~' ] || vr=
 [ "$ir" != '~' ] || ir=
 ampFactor=$af; ampFactor_=
 _se_voltage_mv "$vr" "$vf"; check "$_semv" "$mv" acc-voltage
 _se_ma "$ir"; check "$_sema" "$ma" acc-current
 _se_watts "$mv" "$ma"
 if [ "$_sew" != null ]; then actual_watts=$(awk -v w="$_sew" 'BEGIN {printf "%.3f",w}'); else actual_watts=null; fi
 check "$actual_watts" "$watts" acc-watts
 printf '%s\n' "$ir" > "$currFile"
 case "$af" in 1000) unit=mA;; 1000000) unit=uA;; *) unit=unknown;; esac
 amps_ua=$(rd_current "$currFile" "$unit") || amps_ua=null
 check "$amps_ua" "$ua" amps-current
 printf '%s\n' "$vr" > "$W/voltage_now"
 amps_mv=$(voltage_mv "$W/voltage_now"); [ "$amps_mv" != 0 ] || amps_mv=null
 check "$amps_mv" "$mv" amps-voltage
 expected_power=$mw; [ "$mw" != null ] || expected_power=n/a
 check "$(power_mw "$uv" "$ua")" "$expected_power" amps-watts
 if [ "$ua" != null ]; then
  normalized=$ua; [ "$pol" != inverted ] || normalized=$((0 - ua))
  if [ "${normalized#-}" -lt 30000 ]; then expected_class=bypass; elif [ "$normalized" -lt 0 ]; then expected_class=drain; else expected_class=charging; fi
  check "$(_se_class "$ir" true "$unit" "$pol")" "$expected_class" acc-direction
  if [ "${normalized#-}" -le 10000 ]; then expected_class=BYPASS; elif [ "$normalized" -lt 0 ]; then expected_class=DRAIN; else expected_class=CHARGING; fi
  check "$(classify_state 1 1 "$ua" "$pol" 10000)" "$expected_class" amps-direction
 fi
 if [ "$ua" = null ]; then
  check "$(classify_state 1 1 unknown normal 30000)" UNKNOWN amps-invalid-verdict
  check "$(_se_class "$ir" true "$unit" normal)" unknown acc-invalid-verdict
 fi
done < "$matrix"
printf 'sensor-matrix: scenarios=%s checks=%s failed=%s\n' "$N" "$P" "$F"
[ "$F" = 0 ]
