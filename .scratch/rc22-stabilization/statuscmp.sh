#!/system/bin/sh
# Do the two status nodes disagree while the firmware limit is holding?
G=/sys/devices/platform/google,charger
C=/data/adb/vr25/acc-data/config.txt
L=/sys/class/power_supply/maxfg/capacity
row(){ printf '%-6s stop=%-4s battery/status=%-14s maxfg/status=%-14s acc=%-12s level=%s cur=%s\n' \
  "$1" "$(cat $G/charge_stop_level)" "$(cat /sys/class/power_supply/battery/status)" \
  "$(cat /sys/class/power_supply/maxfg/status)" \
  "$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)" "$(cat $L)" "$(cat /sys/class/power_supply/battery/current_now)"; }
SR=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f3)
SP=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f4)
trap 'acc -s resume_capacity=$SR pause_capacity=$SP >/dev/null 2>&1; echo "restored $SR/$SP"; exit 0' EXIT INT TERM HUP
LV=$(cat $L)
row "start"
echo "=== force a firmware pause (limit below level $LV) ==="
acc -s resume_capacity=$((LV - 3)) pause_capacity=$((LV - 1)) >/dev/null 2>&1
i=0; while [ $i -lt 60 ]; do sleep 20; i=$((i+20)); row "+${i}s"; done
echo "=== now raise it well above; charging must resume ==="
acc -s resume_capacity=$((LV + 20)) pause_capacity=$((LV + 25)) >/dev/null 2>&1
i=0; while [ $i -lt 100 ]; do sleep 20; i=$((i+20)); row "+${i}s"; done
