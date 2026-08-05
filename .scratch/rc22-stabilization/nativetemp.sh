#!/system/bin/sh
# Both halves of the native_unlatch guard, on one phone.
#  A: a pack over max_temp must NOT be pulsed to stop_level=100
#  B: raising pause_capacity must STILL take effect (the thing the revert feared)
G=/sys/devices/platform/google,charger
C=/data/adb/vr25/acc-data/config.txt
L=/sys/class/power_supply/maxfg/capacity
T=/sys/class/power_supply/maxfg/temp
row(){ printf '%-8s stop=%-5s start=%-5s temp=%-4s level=%-3s kernel=%-12s cur=%s\n' "$1" \
  "$(cat $G/charge_stop_level)" "$(cat $G/charge_start_level)" "$(( $(cat $T) / 10 ))" \
  "$(cat $L)" "$(cat /sys/class/power_supply/battery/status)" "$(cat /sys/class/power_supply/battery/current_now)"; }
SR=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f3)
SP=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f4)
ST=$(sed -n 's/^temperature=(//p' $C | tr -d ')')
trap 'acc -s resume_capacity=$SR pause_capacity=$SP >/dev/null 2>&1; acc -s cooldown_temp=$(echo $ST|cut -d" " -f1) max_temp=$(echo $ST|cut -d" " -f2) resume_temp=$(echo $ST|cut -d" " -f3) >/dev/null 2>&1; echo "restored"; exit 0' EXIT INT TERM HUP

PK=$(( $(cat $T) / 10 )); LV=$(cat $L)
echo "pack=${PK}C level=${LV}%  saved cap=$SR/$SP temp=($ST)"
echo "=== A: max_temp BELOW the pack. Must pause, and stop must never read 100. ==="
acc -s resume_capacity=$((LV + 20)) pause_capacity=$((LV + 25)) >/dev/null 2>&1
acc -s cooldown_temp=$((PK - 4)) max_temp=$((PK - 2)) resume_temp=$((PK - 8)) >/dev/null 2>&1
HUND=0
i=0; while [ $i -lt 100 ]; do sleep 12; i=$((i+12)); row "+${i}s"; [ "$(cat $G/charge_stop_level)" = 100 ] && HUND=$((HUND+1)); done
echo "  samples where stop_level was 100: $HUND"
K=$(cat /sys/class/power_supply/battery/status)
if [ "$HUND" -gt 0 ]; then echo "  RESULT A: FAIL - pulsed to 100 on a hot pack ($HUND samples)"
elif [ "$K" = Charging ]; then echo "  RESULT A: FAIL - still charging over max_temp"
else echo "  RESULT A: PASS - held, never pulsed to 100"; fi

echo "=== B: now lift the temperature limit and RAISE pause. Charging must resume. ==="
acc -s cooldown_temp=$((PK + 12)) max_temp=$((PK + 15)) resume_temp=$((PK + 8)) >/dev/null 2>&1
acc -s resume_capacity=$((LV + 20)) pause_capacity=$((LV + 25)) >/dev/null 2>&1
i=0; while [ $i -lt 90 ]; do sleep 15; i=$((i+15)); row "+${i}s"; done
S=$(cat $G/charge_stop_level); K=$(cat /sys/class/power_supply/battery/status)
if [ "$S" = "$((LV + 25))" ] && [ "$K" = Charging ]; then echo "  RESULT B: PASS - limit rose to $S and charging resumed"
else echo "  RESULT B: FAIL - stop=$S (wanted $((LV+25))) kernel=$K"; fi
