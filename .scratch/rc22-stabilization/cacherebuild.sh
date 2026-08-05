#!/system/bin/sh
# Does ACC rebuild its battery-interface cache after it is lost?
# The cache holds the resolved gauge nodes, the current unit and the polarity. Everything -- the
# daemon and every CLI call -- sources it. If it is never rebuilt, a tmpfs wipe or a corrupt write
# leaves acc -i blind and a restarted daemon running on fail-safe defaults.
IF=/dev/.vr25/acc/.batt-interface.sh
st(){ echo "  cache: $([ -f $IF ] && echo "$(wc -l < $IF) lines" || echo MISSING)   acc -i status=[$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)]"; }
echo "--- now ---"; st
echo "--- after acc -D restart ---"
acc -D restart >/dev/null 2>&1 &
sleep 45; st
echo "--- after a second restart ---"
acc -D restart >/dev/null 2>&1 &
sleep 45; st
echo "--- after accd --init (the path that builds it) ---"
if [ -x /data/adb/vr25/acc/accd.sh ]; then
  ( cd /sys/class/power_supply 2>/dev/null; sh /data/adb/vr25/acc/accd.sh --init >/dev/null 2>&1 ) || :
  sleep 20; st
else
  echo "  accd.sh not found"
fi
echo "--- daemon still ok? ---"
P=$(cat /dev/.vr25/acc/acc.lock 2>/dev/null)
echo "  pid=$P alive=$([ -d /proc/$P ] && echo yes || echo NO)"
echo "  level=$(cat /sys/class/power_supply/maxfg/capacity) status=$(cat /sys/class/power_supply/battery/status)"
