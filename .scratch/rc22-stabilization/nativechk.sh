#!/system/bin/sh
G=/sys/devices/platform/google,charger
C=/data/adb/vr25/acc-data/config.txt
show(){ echo "$1 stop=$(cat $G/charge_stop_level 2>/dev/null) start=$(cat $G/charge_start_level 2>/dev/null) cfg=$(sed -n 's/^capacity=//p' $C) level=$(cat /sys/class/power_supply/maxfg/capacity) kernel=$(cat /sys/class/power_supply/battery/status)"; }
show "t0 "
acc -s resume_capacity=60 pause_capacity=65 >/dev/null 2>&1
sleep 45; show "t1 "
acc -s resume_capacity=70 pause_capacity=74 >/dev/null 2>&1
sleep 45; show "t2 "
echo "daemon=$(cat /dev/.vr25/acc/acc.lock) alive=$([ -d /proc/$(cat /dev/.vr25/acc/acc.lock) ] && echo yes || echo NO)"
