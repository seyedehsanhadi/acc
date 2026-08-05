#!/system/bin/sh
# Measure the supply's voltage droop against current: V = Vopen - I*R.
# A healthy cable+charger is under ~0.15 ohm. High resistance makes AICL walk the current down and
# is the one explanation that also fits the charger failing with ACC stopped.
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
echo "open-circuit vbus (no draw): $(cat $U/voltage_now) uV   online=$(cat $U/online)"
echo "recovering the input..."
for f in /sys/class/power_supply/*/current_max /sys/class/power_supply/*/input_current_settled; do
  [ -w "$f" ] && echo 5000000 > "$f" 2>/dev/null || :
done
for f in $U/apsd_rerun $B/rerun_aicl; do [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || :; done
sleep 20
echo
printf '%-6s %-10s %-10s %-9s %-8s %s\n' "t" "vbus_uV" "ibat_uA" "icl" "online" "status"
V0=; I0=
i=0
while [ $i -lt 120 ]; do
  v=$(cat $U/voltage_now); ib=$(cat $B/current_now); ic=$(cat $U/current_max)
  on=$(cat $U/online); st=$(cat $B/status)
  printf '%-6s %-10s %-10s %-9s %-8s %s\n' "+${i}s" "$v" "$ib" "$ic" "$on" "$st"
  case "$st" in Charging) [ -z "$V0" ] && { V0=$v; I0=$ib; };; esac
  i=$((i+15)); sleep 15
done
echo
VN=$(cat $U/voltage_now); IN=$(cat $B/current_now); ON=$(cat $U/online)
echo "first-charging sample: vbus=${V0:-?} ibat=${I0:-?}"
echo "final sample        : vbus=$VN ibat=$IN online=$ON"
# Rough series resistance from the open-circuit reading vs a loaded one. Battery current is not
# input current, but on a 5V supply into a ~3.8V pack they are the same order, so this is a
# magnitude check, not a precision measurement.
if [ -n "$V0" ] && [ "${I0#-}" -gt 100000 ] 2>/dev/null; then
  DV=$(( 5050000 - V0 ))
  MO=$(( DV / ( ${I0#-} / 1000 ) ))
  echo "droop: ${DV} uV at ${I0#-} uA  ->  about ${MO} milliohm of series resistance"
  [ "$MO" -gt 150 ] && echo "VERDICT: high resistance. A good cable+charger is under ~150 milliohm." \
                    || echo "VERDICT: resistance looks acceptable; the collapse is something else."
else
  echo "VERDICT: never drew enough current to measure droop."
fi
