#!/system/bin/sh
# Does the temperature limit stop charging on the native path, right now?
G=/sys/devices/platform/google,charger
M=/sys/class/power_supply/maxfg
B=/sys/class/power_supply/battery
DD=/data/adb/vr25/acc-data
row(){ printf '%-7s stop=%-4s start=%-4s temp=%-4s level=%-3s kernel=%-12s ibat=%-9s cfg_t=%s\n' "$1" \
  "$(cat $G/charge_stop_level)" "$(cat $G/charge_start_level)" "$(( $(cat $M/temp) / 10 ))" \
  "$(cat $M/capacity)" "$(cat $B/status)" "$(cat $B/current_now)" "$(sed -n 's/^temperature=//p' $DD/config.txt)"; }
SC=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')
ST=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
trap 'acc -s resume_capacity=$(echo $SC|cut -d" " -f3) pause_capacity=$(echo $SC|cut -d" " -f4) >/dev/null 2>&1; acc -s cooldown_temp=$(echo $ST|cut -d" " -f1) max_temp=$(echo $ST|cut -d" " -f2) resume_temp=$(echo $ST|cut -d" " -f3) >/dev/null 2>&1; echo restored; exit 0' EXIT INT TERM HUP
LV=$(cat $M/capacity); T=$(( $(cat $M/temp) / 10 ))
echo "pack=${T}C level=${LV}%  lifting the capacity limit clear first"
acc -s resume_capacity=$((LV+15)) pause_capacity=$((LV+20)) >/dev/null 2>&1
sleep 25; row "base"
echo "=== max_temp 2C BELOW the pack -> must stop ==="
acc -s cooldown_temp=$((T-4)) max_temp=$((T-2)) resume_temp=$((T-8)) >/dev/null 2>&1
i=0; while [ $i -lt 100 ]; do sleep 20; i=$((i+20)); row "+${i}s"; done
K=$(cat $B/status); S=$(cat $G/charge_stop_level); L=$(cat $M/capacity)
echo
if [ "$K" != Charging ] || [ "$S" -le "$L" ] 2>/dev/null; then
  echo "RESULT: stopped (kernel=$K stop=$S level=$L)"
else
  echo "RESULT: STILL CHARGING (kernel=$K stop=$S level=$L) -- the thermal force did not lower stop"
  echo "  temperature config: $(sed -n 's/^temperature=//p' $DD/config.txt)"
  echo "  capacity config   : $(sed -n 's/^capacity=//p' $DD/config.txt)"
fi
