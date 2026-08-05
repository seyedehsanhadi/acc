#!/system/bin/sh
L=/dev/.vr25/acc/accd-bluejay.log
echo "sampling the probe's progress over 90s"
for i in 1 2 3 4; do
  sw=$(grep -o "chargingSwitch\[0\]='[^']*'" $L 2>/dev/null | tail -1)
  it=$(grep -o "'\[' [0-9]* '=' 35 ']'" $L 2>/dev/null | tail -1)
  echo "t+$(( (i-1)*30 ))s  loglines=$(wc -l < $L)  iter=${it:-?}  cand=${sw:-?}"
  [ $i -lt 4 ] && sleep 30
done
echo "--- candidate list size ---"
wc -l < /dev/.vr25/acc/ch-switches 2>/dev/null || echo "(deleted - it is the child's stdin)"
echo "--- how many distinct candidates has it tried this session? ---"
grep -c "read -A chargingSwitch" $L 2>/dev/null
echo "--- flight.log still frozen? ---"
a=$(wc -l < /data/adb/vr25/acc-data/logs/flight.log); sleep 10; b=$(wc -l < /data/adb/vr25/acc-data/logs/flight.log)
echo "flight $a -> $b"
