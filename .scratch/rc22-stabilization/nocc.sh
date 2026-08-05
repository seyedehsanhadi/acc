#!/system/bin/sh
# Charging behaviour with ACC completely out of the picture.
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
echo "uptime      : $(cut -d' ' -f1 /proc/uptime)s"
echo "disable file: $([ -f /data/adb/modules/acc/disable ] && echo present || echo ABSENT)"
echo "acc daemon  : $(cat /dev/.vr25/acc/acc.lock 2>/dev/null || echo none)"
echo "accd procs  : $(ps -A -o ARGS 2>/dev/null | grep -c '[a]ccd.sh')"
echo "acc binary  : $(command -v acc >/dev/null 2>&1 && echo present || echo gone)"
echo "input_suspend=$(cat $B/input_suspend 2>/dev/null)"
echo
printf '%-7s %-10s %-10s %-9s %-7s %-12s %s\n' "t" "vbus_uV" "ibat_uA" "icl" "online" "status" "type"
i=0
MIN=99999999
while [ $i -lt 600 ]; do
  v=$(cat $U/voltage_now); ib=$(cat $B/current_now); ic=$(cat $U/current_max)
  on=$(cat $U/online); st=$(cat $B/status); ty=$(cat $U/real_type)
  printf '%-7s %-10s %-10s %-9s %-7s %-12s %s\n' "+${i}s" "$v" "$ib" "$ic" "$on" "$st" "$ty"
  case "$ic" in ''|*[!0-9]*) : ;; *) [ "$ic" -lt "$MIN" ] && MIN=$ic;; esac
  i=$((i+30)); sleep 30
done
echo
echo "lowest icl seen over 10 min with NO ACC: $MIN"
[ "$MIN" -eq 0 ] && echo "VERDICT: the input still collapsed to 0 with ACC absent." \
                 || echo "VERDICT: the input never collapsed with ACC absent (floor ${MIN})."
