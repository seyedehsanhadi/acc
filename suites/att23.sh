#!/system/bin/sh
# Phase 2 needs the 9V brick; phase 3 needs >62% and only the 9V charge gets it there in
# reasonable time. Rather than make the operator come back for the second one, run phase 2,
# then WAIT for the level to arrive and fire phase 3 on its own.
P=/data/local/tmp/plug
L=$P/ATT23.log
exec > $L 2>&1
PS=/sys/class/power_supply
lvl(){ cat $PS/battery/capacity 2>/dev/null; }

echo "== phase 2 (9V) $(date '+%H:%M:%S')"
PHASES="2" sh $P/rc24-attended.sh
sed -n '/9V ATTACHED/,$p' $P/ATTENDED.log
cp $P/ATTENDED.log $P/ATTENDED.p2.log 2>/dev/null

echo
echo "== waiting for >62% to run phase 3 (currently $(lvl)%)"
w=0
while [ $w -lt 10800 ]; do
  l=$(lvl)
  [ "${l:-0}" -gt 62 ] 2>/dev/null && break
  [ "$(cat $PS/usb/present 2>/dev/null)" = 1 ] || { echo "  cable removed at ${l}% - phase 3 cannot run"; exit 0; }
  sleep 60; w=$((w+60))
done
l=$(lvl)
[ "${l:-0}" -gt 62 ] 2>/dev/null || { echo "  gave up at ${l}% after ${w}s"; exit 0; }

echo "== phase 3 at ${l}% $(date '+%H:%M:%S')"
PHASES="3" sh $P/rc24-attended.sh
sed -n '/IDLE-AVOIDANCE/,$p' $P/ATTENDED.log
echo "== ATT23 DONE"
