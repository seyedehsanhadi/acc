#!/system/bin/sh
G=/sys/devices/platform/google,charger/charge_stop_level
C=/data/adb/vr25/acc-data/config.txt
F=/data/adb/vr25/acc-data/logs/flight.log
echo "cfg=$(sed -n 's/^capacity=//p' $C)  stop=$(cat $G)  daemon=$(cat /dev/.vr25/acc/acc.lock)"
a=$(wc -l < $F); sleep 20; b=$(wc -l < $F)
echo "flight.log grew $((b-a)) lines in 20s (daemon IS looping if >0)"
echo "stop after 20s = $(cat $G)  <- config wants 74"
echo "=== restarting daemon ==="
acc -D restart >/dev/null 2>&1 &
sleep 45
echo "new daemon=$(cat /dev/.vr25/acc/acc.lock)  stop=$(cat $G)  kernel=$(cat /sys/class/power_supply/battery/status)"
echo "level=$(cat /sys/class/power_supply/maxfg/capacity) main-charger/online=$(cat /sys/class/power_supply/main-charger/online 2>/dev/null)"
