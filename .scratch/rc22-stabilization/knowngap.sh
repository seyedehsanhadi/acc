#!/system/bin/sh
# Is the "KNOWN GAP" at accd.sh:1547 still real?
#
# The note says: raising pause while the firmware is latched does NOT resume charging. Reproduced
# as "pause 72 at 72% latches, raising to 80 writes charge_stop_level=80 and the phone stays at 0mA
# until it drains to resume_capacity".
#
# Suspicion: that was the daemon freeze (the generic switch prober on a native phone), not a
# firmware latch. Reproduce at the documented conditions -- pause EQUAL to the level, which is the
# exact wording -- and watch whether the loop is alive throughout.
G=/sys/devices/platform/google,charger
C=/data/adb/vr25/acc-data/config.txt
L=/sys/class/power_supply/maxfg/capacity
F=/data/adb/vr25/acc-data/logs/flight.log
row(){ printf '%-8s stop=%-4s start=%-4s level=%-3s kernel=%-12s cur=%-9s loop=%s\n' "$1" \
  "$(cat $G/charge_stop_level)" "$(cat $G/charge_start_level)" "$(cat $L)" \
  "$(cat /sys/class/power_supply/battery/status)" "$(cat /sys/class/power_supply/battery/current_now)" "$2"; }
SR=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f3)
SP=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f4)
trap 'acc -s resume_capacity=$SR pause_capacity=$SP >/dev/null 2>&1; echo "restored $SR/$SP"; exit 0' EXIT INT TERM HUP

LV=$(cat $L)
echo "build=$(sed -n 's/^commit=//p' /data/adb/vr25/acc/.build-id) level=${LV}% saved=$SR/$SP"
echo "=== latch it: pause EXACTLY at the level (the note's wording) ==="
acc -s resume_capacity=$((LV - 4)) pause_capacity=$LV >/dev/null 2>&1
i=0; while [ $i -lt 60 ]; do sleep 20; i=$((i+20)); row "+${i}s" "-"; done
echo "  latched? kernel=$(cat /sys/class/power_supply/battery/status) stop=$(cat $G/charge_stop_level)"
echo "=== now RAISE pause well above, as the note describes ==="
a=$(wc -l < $F)
acc -s resume_capacity=$((LV + 6)) pause_capacity=$((LV + 8)) >/dev/null 2>&1
i=0
while [ $i -lt 150 ]; do
  sleep 25; i=$((i+25))
  b=$(wc -l < $F); lp=$([ "$b" -gt "$a" ] && echo alive || echo DEAD); a=$b
  row "+${i}s" "$lp"
done
S=$(cat $G/charge_stop_level); K=$(cat /sys/class/power_supply/battery/status)
echo
if [ "$S" = "$((LV + 8))" ] && [ "$K" = Charging ]; then
  echo "RESULT: the gap is GONE - stop rose to $S and charging resumed without draining to resume"
else
  echo "RESULT: the gap is REAL - stop=$S (wanted $((LV+8))) kernel=$K"
fi
