#!/system/bin/sh
F=/data/adb/vr25/acc-data/logs/flight.log
P=$(cat /dev/.vr25/acc/acc.lock)
G=/sys/devices/platform/google,charger/charge_stop_level
echo "pid=$P exists=$([ -d /proc/$P ] && echo yes || echo NO) state=$(awk '{print $3}' /proc/$P/stat 2>/dev/null)"
echo "stop=$(cat $G) cfg=$(sed -n 's/^capacity=//p' /data/adb/vr25/acc-data/config.txt) level=$(cat /sys/class/power_supply/maxfg/capacity)"
a=$(wc -l < $F); sleep 30; b=$(wc -l < $F)
echo "flight.log: $a -> $b in 30s  (delta $((b-a)))"
if [ "$b" = "$a" ]; then
  echo "*** LOOP IS DEAD ***"
  echo "wchan   : $(cat /proc/$P/wchan 2>/dev/null)"
  echo "utime/stime: $(awk '{print $14"/"$15}' /proc/$P/stat 2>/dev/null)"
  echo "--- fds ---"; ls -l /proc/$P/fd 2>/dev/null
  echo "--- stack ---"; cat /proc/$P/stack 2>/dev/null || echo "(not readable)"
  echo "--- children ---"
  for c in /proc/[0-9]*; do
    pp=$(awk '{print $4}' $c/stat 2>/dev/null); [ "$pp" = "$P" ] || continue
    echo "  child ${c#/proc/} state=$(awk '{print $3}' $c/stat 2>/dev/null) wchan=$(cat $c/wchan 2>/dev/null) cmd=$(tr '\0' ' ' < $c/cmdline 2>/dev/null)"
    ls -l $c/fd 2>/dev/null | sed 's/^/      /'
  done
else
  echo "loop is alive"
fi
