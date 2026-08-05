#!/system/bin/sh
# Reproduce: does a native-limit pause LATCH, so raising pause_capacity never resumes charging?
G=/sys/devices/platform/google,charger
C=/data/adb/vr25/acc-data/config.txt
L=/sys/class/power_supply/maxfg/capacity
row(){ printf '%-6s stop=%-4s start=%-4s cfg=%-22s level=%-3s kernel=%s\n' "$1" "$(cat $G/charge_stop_level)" "$(cat $G/charge_start_level)" "$(sed -n 's/^capacity=//p' $C)" "$(cat $L)" "$(cat /sys/class/power_supply/battery/status)"; }
SR=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f3)
SP=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f4)
trap 'acc -s resume_capacity=$SR pause_capacity=$SP >/dev/null 2>&1; echo "restored $SR/$SP"; exit 0' EXIT INT TERM HUP
LV=$(cat $L)
echo "level=$LV  saved=$SR/$SP"
echo "=== STEP 1: pause it, by putting the limit BELOW the level ==="
acc -s resume_capacity=$((LV - 3)) pause_capacity=$((LV - 1)) >/dev/null 2>&1
i=0; while [ $i -lt 60 ]; do row "+${i}s"; i=$((i+20)); sleep 20; done
echo "=== STEP 2: raise the limit well ABOVE the level. Charging must resume. ==="
acc -s resume_capacity=$((LV + 20)) pause_capacity=$((LV + 25)) >/dev/null 2>&1
i=0; while [ $i -lt 180 ]; do row "+${i}s"; i=$((i+20)); sleep 20; done
S=$(cat $G/charge_stop_level); K=$(cat /sys/class/power_supply/battery/status)
echo
if [ "$S" = "$((LV + 25))" ] && [ "$K" = Charging ]; then
  echo "RESULT: recovered - the limit rose to $S and charging resumed"
else
  echo "RESULT: LATCHED - stop=$S (wanted $((LV + 25))), kernel=$K"
  echo "        The phone is not charging and the config says it should be."
fi
