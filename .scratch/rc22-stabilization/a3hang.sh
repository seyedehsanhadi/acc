#!/system/bin/sh
P=$(cat /dev/.vr25/acc/acc.lock)
F=/data/adb/vr25/acc-data/logs/flight.log
echo "pid=$P state=$(awk '{print $3}' /proc/$P/stat 2>/dev/null) wchan=$(cat /proc/$P/wchan 2>/dev/null)"
a=$(wc -l < $F); sleep 25; b=$(wc -l < $F)
echo "flight.log $a -> $b in 25s"
if [ "$b" = "$a" ]; then
  echo "*** NOT LOOPING ***"
  echo "--- children ---"
  for c in /proc/[0-9]*; do
    pp=$(awk '{print $4}' $c/stat 2>/dev/null); [ "$pp" = "$P" ] || continue
    echo "  child ${c#/proc/} state=$(awk '{print $3}' $c/stat 2>/dev/null) wchan=$(cat $c/wchan 2>/dev/null)"
    echo "     cmd=$(tr '\0' ' ' < $c/cmdline 2>/dev/null)"
    echo "     fd0=$(readlink $c/fd/0 2>/dev/null)"
    for g in /proc/[0-9]*; do
      gp=$(awk '{print $4}' $g/stat 2>/dev/null); [ "$gp" = "${c#/proc/}" ] || continue
      echo "     grandchild ${g#/proc/} state=$(awk '{print $3}' $g/stat 2>/dev/null) cmd=$(tr '\0' ' ' < $g/cmdline 2>/dev/null)"
    done
  done
  echo "--- daemon log tail ---"
  tail -14 /dev/.vr25/acc/accd-*.log 2>/dev/null
else
  echo "loop alive (grew $((b-a)))"
fi
echo "--- config ---"
grep -E "^capacity=|^temperature=|^maxCharging" /data/adb/vr25/acc-data/config.txt
echo "level=$(cat /sys/class/power_supply/battery/capacity) icl=$(cat /sys/class/power_supply/usb/current_max) status=$(cat /sys/class/power_supply/battery/status)"
