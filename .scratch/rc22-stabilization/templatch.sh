#!/system/bin/sh
# Does a THERMAL pause latch on a generic-switch phone? Capacity resumes fine; temperature did not.
B=/sys/class/power_supply/battery
DD=/data/adb/vr25/acc-data
row(){ printf '%-8s sw=%-3s kernel=%-12s temp=%-4s cfg_t=%-18s cur=%s\n' "$1" \
  "$(cat $B/input_suspend 2>/dev/null)" "$(cat $B/status)" "$(( $(cat $B/temp) / 10 ))" \
  "$(sed -n 's/^temperature=//p' $DD/config.txt)" "$(cat $B/current_now)"; }
ST=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
trap 'acc -s cooldown_temp=$(echo $ST|cut -d" " -f1) max_temp=$(echo $ST|cut -d" " -f2) resume_temp=$(echo $ST|cut -d" " -f3) >/dev/null 2>&1; echo restored; exit 0' EXIT INT TERM HUP
[ "$(cat $B/status)" = Charging ] || { echo "not charging, cannot test"; exit 0; }
T=$(( $(cat $B/temp) / 10 ))
echo "pack=${T}C  saved temperature=($ST)"
echo "=== 1. pause it: max_temp 2C BELOW the pack ==="
acc -s cooldown_temp=$((T-4)) max_temp=$((T-2)) resume_temp=$((T-8)) >/dev/null 2>&1
i=0; while [ $i -lt 60 ]; do sleep 20; i=$((i+20)); row "+${i}s"; done
echo "=== 2. raise it well ABOVE the pack. Charging must resume. ==="
acc -s cooldown_temp=$((T+12)) max_temp=$((T+15)) resume_temp=$((T+8)) >/dev/null 2>&1
i=0; while [ $i -lt 180 ]; do sleep 20; i=$((i+20)); row "+${i}s"; done
K=$(cat $B/status); SW=$(cat $B/input_suspend 2>/dev/null)
echo
if [ "$K" = Charging ] && [ "$SW" != 1 ]; then echo "RESULT: resumed"; else
  echo "RESULT: LATCHED - kernel=$K switch=$SW after 180s"
  echo "--- daemon ledger ---"; tail -8 /dev/.vr25/acc/.write-ledger 2>/dev/null
  echo "--- is the loop alive? ---"
  a=$(wc -l < $DD/logs/flight.log); sleep 20; b=$(wc -l < $DD/logs/flight.log)
  echo "flight.log $a -> $b"
  echo "--- what the daemon thinks ---"
  echo "acc -i status=[$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)]"
  echo "level=$(cat $B/capacity) cfg_capacity=$(sed -n 's/^capacity=//p' $DD/config.txt)"
fi
