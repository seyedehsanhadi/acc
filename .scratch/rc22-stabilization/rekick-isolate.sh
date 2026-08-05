#!/system/bin/sh
# Does a re-kick ALONE kill a working charge? Nothing else is touched.
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
row(){ printf '%-10s icl=%-9s online=%-3s vbus=%-8s cur=%-10s kernel=%-12s level=%s\n' "$1" \
  "$(cat $U/current_max)" "$(cat $U/online)" "$(cat $U/voltage_now)" "$(cat $B/current_now)" \
  "$(cat $B/status)" "$(cat $B/capacity)"; }
recover(){
  for f in /sys/class/power_supply/*/current_max /sys/class/power_supply/*/input_current_settled; do
    [ -w "$f" ] && echo 5000000 > "$f" 2>/dev/null || :
  done
  for f in $U/apsd_rerun $B/rerun_aicl; do [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || :; done
}
echo "=== STEP 1: recover the charger ==="
row "before"
recover
i=0; while [ $i -lt 60 ]; do sleep 20; i=$((i+20)); row "+${i}s"; done
ICL0=$(cat $U/current_max); ON0=$(cat $U/online)
if [ "${ICL0:-0}" -lt 500000 ] || [ "$ON0" != 1 ]; then
  echo "RESULT: could not get the charger back (icl=$ICL0 online=$ON0). Cannot test the re-kick."
  exit 0
fi
echo "charger healthy at icl=$ICL0"
echo
echo "=== STEP 2: fire ONLY a re-kick. Nothing else. ==="
for f in $U/apsd_rerun $B/rerun_aicl; do [ -w "$f" ] && { echo 1 > "$f" 2>/dev/null; echo "  kicked $f"; }; done
i=0; while [ $i -lt 90 ]; do sleep 15; i=$((i+15)); row "+${i}s"; done
ICL1=$(cat $U/current_max); ON1=$(cat $U/online)
echo
echo "icl $ICL0 -> $ICL1 , online $ON0 -> $ON1"
if [ "${ICL1:-0}" -lt $(( ICL0 / 2 )) ] || [ "$ON1" != 1 ]; then
  echo "VERDICT: the re-kick ALONE collapsed the charge. This is the cause."
else
  echo "VERDICT: the charge survived the re-kick. The re-kick is NOT the cause."
fi
echo "=== restoring ==="
recover
sleep 30; row "final"
