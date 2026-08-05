#!/system/bin/sh
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
echo "acc daemon : $(cat /dev/.vr25/acc/acc.lock 2>/dev/null || echo none)"
echo "accd procs : $(ps -A -o ARGS 2>/dev/null | grep -c '[a]ccd.sh')"
echo "disable    : $([ -f /data/adb/modules/acc/disable ] && echo present || echo ABSENT)"
printf 'vbus=%s icl=%s online=%s ibat=%s status=%s level=%s type=%s\n' \
  "$(cat $U/voltage_now)" "$(cat $U/current_max)" "$(cat $U/online)" \
  "$(cat $B/current_now)" "$(cat $B/status)" "$(cat $B/capacity)" "$(cat $U/real_type)"
