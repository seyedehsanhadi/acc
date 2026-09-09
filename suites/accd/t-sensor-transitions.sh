#!/system/bin/sh
execDir=${execDir:-install}
execDir=$(cd "$execDir" && pwd)
. "$execDir/state-export.sh"
W=$(mktemp -d "${TMPDIR:-/data/local/tmp}/sensor-transitions.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
TMPDIR=$W; SE_POLCACHE=$W/polarity; SE_CCCACHE=$W/counter
P=0; F=0
check(){ P=$((P+1)); if [ "$1" != "$2" ]; then F=$((F+1)); [ "$F" -gt 20 ] || echo "FAIL $3 got=$1 expected=$2"; fi; }
for voltage in 5000 9000000 5000000 9000; do
 for units in mA uA; do
  for raw in -895 895; do
   value=$raw; [ "$units" = mA ] || value=$((raw * 1000))
   for old_polarity in normal inverted unstable unknown; do
    check "$(_se_class "$value" true "$units" "$old_polarity" rising Unknown)" charging "rising/$voltage/$units/$raw/$old_polarity"
    check "$(_se_class "$value" true "$units" "$old_polarity" falling Charging)" drain "falling/$voltage/$units/$raw/$old_polarity"
   done
   polarity=$(_se_polarity Charging "$value" false "$units" 50 2000000000)
   check "$(_se_class "$value" false "$units" "$polarity" flat Unknown)" discharging "unplugged/$voltage/$units/$raw"
  done
 done
done
date(){ echo 2000000000; }
for bad in '' garbage 0 -1 999999999999999999999999; do
 printf '1000000 1999999990\n' > "$SE_CCCACHE"
 check "$(_se_ccdir "$bad")" unknown "counter-fault/$bad"
 check "$(_se_ccdir 1000000)" unknown "counter-recovery/$bad"
done
for pair in '1000500:rising' '999500:falling' '1000001:flat' '1:unknown' '999999999:unknown'; do
 printf '1000000 1999999990\n' > "$SE_CCCACHE"
 check "$(_se_ccdir "${pair%:*}")" "${pair#*:}" "counter/$pair"
done
for when in 0 1999999800 2000000010 99999999999999999999 garbage; do
 printf '1000000 %s\n' "$when" > "$SE_CCCACHE"
 check "$(_se_ccdir 1000500)" unknown "counter-time/$when"
done
n=0
while [ "$n" -lt 10000 ]; do
 n=$((n+1)); raw=895; ampFactor=1000; voltage=5000; vf=1000; expected=895; expected_v=5000; expected_w=4.475
 [ $((n % 2)) -ne 0 ] || { raw=-895; expected=-895; }
 [ $((n % 4)) -lt 2 ] || { raw=$((raw * 1000)); ampFactor=1000000; }
 [ $((n % 8)) -lt 4 ] || { voltage=9000; expected_v=9000; expected_w=8.055; }
 [ $((n % 16)) -lt 8 ] || { voltage=$((voltage * 1000)); vf=1000000; }
 _se_ma "$raw"; check "$_sema" "$expected" stress-current
 _se_voltage_mv "$voltage" "$vf"; check "$_semv" "$expected_v" stress-voltage
 _se_watts "$_semv" "$_sema"; check "$_sew" "$expected_w" stress-watts
done
echo "sensor-transitions: checks=$P failed=$F stress_rounds=$n"
[ "$F" = 0 ]
