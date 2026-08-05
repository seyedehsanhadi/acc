#!/system/bin/sh
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
G=/sys/class/power_supply/maxfg; [ -r $G/capacity ] || G=$B
echo "watching the supply settle (90s)"
i=0
while [ $i -lt 90 ]; do
  icl=""
  for f in /sys/class/power_supply/*/current_max; do
    v=$(cat $f 2>/dev/null); case "${v:-x}" in ''|*[!0-9]*) continue;; esac
    [ "$v" -gt 0 ] && icl="$icl ${f##*power_supply/}=$v"
  done
  printf '+%-4ss ibat=%-10s kernel=%-12s level=%-3s icl:%s\n' "$i" "$(cat $B/current_now)" "$(cat $B/status)" "$(cat $G/capacity)" "${icl:- none}"
  i=$((i+15)); sleep 15
done
