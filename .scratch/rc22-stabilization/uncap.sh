#!/system/bin/sh
# Does writing the input nodes HIGH recover a charger the driver has left at ICL=0?
# This is exactly what the rc22 restore fix writes instead of the 500000 snapshot.
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
show(){ printf '%-6s icl=%-9s online=%-3s vbus=%-6s cur=%-10s kernel=%-12s level=%s\n' "$1" \
  "$(cat $U/current_max)" "$(cat $U/online)" "$(cat $U/voltage_now)" "$(cat $B/current_now)" \
  "$(cat $B/status)" "$(cat $B/capacity)"; }
show "before"
echo "--- writing 5000000 to the input nodes (driver clamps to what the charger can give) ---"
for f in /sys/class/power_supply/*/current_max /sys/class/power_supply/*/input_current_settled; do
  [ -w "$f" ] || continue
  echo 5000000 > "$f" 2>/dev/null && echo "  wrote $f now=$(cat $f)"
done
echo "--- re-running input detection ---"
for f in $U/apsd_rerun $B/rerun_aicl; do [ -w "$f" ] && echo 1 > "$f" 2>/dev/null && echo "  kicked $f"; done
i=0; while [ $i -lt 60 ]; do sleep 15; i=$((i+15)); show "+${i}s"; done
