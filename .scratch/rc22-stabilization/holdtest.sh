#!/system/bin/sh
# Does the limit stop cleanly and HOLD, without overshoot or churn?
# Gate criteria: never exceeds pause+2, the switch does not sawtooth, the loop stays alive.
G=/sys/devices/platform/google,charger
C=/data/adb/vr25/acc-data/config.txt
F=/data/adb/vr25/acc-data/logs/flight.log
LNODE=/sys/class/power_supply/maxfg/capacity
[ -r "$LNODE" ] || LNODE=/sys/class/power_supply/battery/capacity
SR=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f3)
SP=$(sed -n 's/^capacity=(//p' $C | tr -d ')' | cut -d' ' -f4)
trap 'acc -s resume_capacity=$SR pause_capacity=$SP >/dev/null 2>&1; echo "restored $SR/$SP"; exit 0' EXIT INT TERM HUP

LV=$(cat $LNODE); PAUSE=$((LV + 3)); RES=$((LV - 1))
echo "build=$(sed -n 's/^commit=//p' /data/adb/vr25/acc/.build-id) level=${LV}% -> limit ${PAUSE}% (resume ${RES}%)"
acc -s resume_capacity=$RES pause_capacity=$PAUSE >/dev/null 2>&1
MAXSEEN=$LV; FLIPS=0; PREV=; DEAD=0; QUIET=0
a=$(wc -l < $F)
i=0
while [ $i -lt 900 ]; do
  sleep 30; i=$((i+30))
  lv=$(cat $LNODE); st=$(cat /sys/class/power_supply/battery/status)
  sw=$(cat $G/charge_stop_level 2>/dev/null || cat /sys/class/power_supply/battery/input_suspend 2>/dev/null)
  # A quiet flight.log is EXPECTED while holding: plugged and above resume, the daemon takes
  # _nap_hold 30 on purpose (the overnight-on-charger standby optimisation). Only count a stall
  # when it stays quiet across two consecutive samples, which is longer than that hold.
  b=$(wc -l < $F)
  if [ "$b" -gt "$a" ]; then QUIET=0; else QUIET=$((QUIET+1)); [ "$QUIET" -lt 2 ] || DEAD=$((DEAD+1)); fi
  a=$b
  [ "$lv" -gt "$MAXSEEN" ] 2>/dev/null && MAXSEEN=$lv
  [ -n "$PREV" ] && [ "$st" != "$PREV" ] && FLIPS=$((FLIPS+1))
  PREV=$st
  printf '%-6s level=%-3s max=%-3s status=%-12s sw=%-5s flips=%-3s loopstalls=%s\n' "+${i}s" "$lv" "$MAXSEEN" "$st" "$sw" "$FLIPS" "$DEAD"
done
echo
echo "limit=${PAUSE}%  highest level seen=${MAXSEEN}%  status flips=${FLIPS}  loop stalls=${DEAD}"
P=0; F2=0
[ "$MAXSEEN" -le $((PAUSE + 2)) ] && { echo "  PASS  never went past limit+2"; P=$((P+1)); } || { echo "  FAIL  overshot to ${MAXSEEN}% (limit ${PAUSE}%)"; F2=$((F2+1)); }
[ "$FLIPS" -le 4 ] && { echo "  PASS  no sawtooth (${FLIPS} status changes)"; P=$((P+1)); } || { echo "  FAIL  charging churned ${FLIPS} times"; F2=$((F2+1)); }
[ "$DEAD" -eq 0 ] && { echo "  PASS  loop never stalled"; P=$((P+1)); } || { echo "  FAIL  loop stalled ${DEAD} times"; F2=$((F2+1)); }
echo "holdtest: $P passed, $F2 failed"
