#!/system/bin/sh
# Does an EMPTY cache now self-heal on a plain daemon restart?
IF=/dev/.vr25/acc/.batt-interface.sh
st(){ echo "  cache=$([ -f $IF ] && wc -l < $IF || echo MISSING) lines  battCapacity=[$(sed -n 's/^battCapacity=//p' $IF 2>/dev/null)]  acc -i=[$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)]"; }
echo "--- healthy baseline ---"; st
echo "--- now truncate it, exactly as a crash mid-write would ---"
: > $IF
st
echo "--- plain daemon restart ---"
acc -D restart >/dev/null 2>&1 &
sleep 50
st
_bc=$(sed -n 's/^battCapacity=//p' $IF 2>/dev/null)
_ai=$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)
if [ -n "$_bc" ] && [ -n "$_ai" ]; then
  echo "RESULT: SELF-HEALED - the cache was rebuilt and acc -i answers again"
else
  echo "RESULT: STILL BROKEN - battCapacity=[$_bc] acc -i=[$_ai]"
fi
P=$(cat /dev/.vr25/acc/acc.lock 2>/dev/null)
echo "daemon pid=$P alive=$([ -d /proc/$P ] && echo yes || echo NO)"
echo "level=$(cat /sys/class/power_supply/maxfg/capacity) status=$(cat /sys/class/power_supply/battery/status)"
