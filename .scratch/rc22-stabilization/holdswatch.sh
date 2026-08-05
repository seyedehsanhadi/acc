#!/system/bin/sh
# With ACC enabled: does the charge HOLD, or does ACC only delay the collapse?
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
printf '%-7s %-9s %-9s %-10s %-7s %-12s %s\n' "t" "vbus_mV" "icl" "ibat_uA" "online" "status" "level"
ZERO=0; CHG=0; n=0
i=0
while [ $i -lt 720 ]; do
  v=$(cat $U/voltage_now); ic=$(cat $U/current_max); ib=$(cat $B/current_now)
  on=$(cat $U/online); st=$(cat $B/status); lv=$(cat $B/capacity)
  printf '%-7s %-9s %-9s %-10s %-7s %-12s %s\n' "+${i}s" "$(( v / 1000 ))" "$ic" "$ib" "$on" "$st" "$lv"
  n=$((n+1))
  [ "$ic" = 0 ] && ZERO=$((ZERO+1))
  [ "$st" = Charging ] && CHG=$((CHG+1))
  i=$((i+40)); sleep 40
done
echo
echo "samples=$n  charging=$CHG  icl-zero=$ZERO"
echo "ledger (ACC's own writes during this window):"
tail -14 /dev/.vr25/acc/.write-ledger 2>/dev/null
if [ "$CHG" -ge $(( n * 3 / 4 )) ]; then
  echo "VERDICT: ACC keeps this cable charging ($CHG of $n samples)."
elif [ "$CHG" -gt 0 ]; then
  echo "VERDICT: ACC recovers it repeatedly but it keeps collapsing ($CHG of $n charging)."
else
  echo "VERDICT: collapsed and stayed collapsed even with ACC."
fi
