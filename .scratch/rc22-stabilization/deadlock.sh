#!/system/bin/sh
D=/data/adb/vr25/acc-data
P=$(cat /dev/.vr25/acc/acc.lock)
echo "allowIdleAbovePcap = $(sed -n 's/^allowIdleAbovePcap=//p' $D/config.txt)"
echo "prioritizeBattIdleMode = $(sed -n 's/^prioritizeBattIdleMode=//p' $D/config.txt)"
echo "capacity = $(sed -n 's/^capacity=//p' $D/config.txt)  level=$(cat /sys/class/power_supply/maxfg/capacity)"
echo "daemon=$P"
kids(){ for c in /proc/[0-9]*; do pp=$(awk '{print $4}' $c/stat 2>/dev/null); [ "$pp" = "$1" ] || continue; echo "${c#/proc/}"; done; }
for k in $(kids $P); do
  echo "--- child $k state=$(awk '{print $3}' /proc/$k/stat 2>/dev/null) wchan=$(cat /proc/$k/wchan 2>/dev/null)"
  echo "    cmd=$(tr '\0' ' ' < /proc/$k/cmdline 2>/dev/null)"
  for g in $(kids $k); do
    echo "    --- grandchild $g state=$(awk '{print $3}' /proc/$g/stat 2>/dev/null) wchan=$(cat /proc/$g/wchan 2>/dev/null)"
    echo "        cmd=$(tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null)"
    echo "        fds:"; ls -l /proc/$g/fd 2>/dev/null | sed 's/^/          /'
    echo "        stack:"; cat /proc/$g/stack 2>/dev/null | sed 's/^/          /'
    for gg in $(kids $g); do
      echo "        --- great-grandchild $gg state=$(awk '{print $3}' /proc/$gg/stat 2>/dev/null) wchan=$(cat /proc/$gg/wchan 2>/dev/null) cmd=$(tr '\0' ' ' < /proc/$gg/cmdline 2>/dev/null)"
      cat /proc/$gg/stack 2>/dev/null | sed 's/^/            /'
    done
  done
done
echo "--- last daemon log lines ---"
tail -20 /dev/.vr25/acc/accd-bluejay.log 2>/dev/null
