#!/system/bin/sh
# rc24-acc-vs-thermal.sh - does ACC slow charging, or does the pack temperature?
#
#   su -c 'sh /data/local/tmp/rc24-acc-vs-thermal.sh'
#
# START IT PLUGGED AND CHARGING, with no cap configured.
#
# THE CLAIM UNDER TEST
#   "Turn ACC off and it charges fast again." Observed twice on a Mi A3, and it is a fair thing to
#   suspect: ACC is the only software touching those nodes.
#
# WHY A NAIVE ON/OFF TEST CANNOT ANSWER IT
#   The vendor thermal driver on this phone steps charge current down as the pack warms and back up
#   as it cools, writing charge_control_limit itself -- measured stepping 5 -> 3 as the pack fell
#   from 45.1C to 42.7C with nothing from ACC in between. Any single ON-then-OFF comparison is
#   therefore confounded: the phone is always either warming or cooling, so whichever state came
#   second gets credit for the trend.
#
# THE DESIGN
#   Alternate ON / OFF / ON / OFF, several minutes each, sampling every 10s. Then compare current
#   ON vs OFF *within the same 1C temperature bin*, so the trend cancels. Alternating twice also
#   cancels a monotonic drift in battery level.
#
#   If ACC throttles, OFF beats ON inside the same bin, repeatably.
#   If it is thermal, current tracks temperature and the ACC state does not matter.

ID=rc24-acc-vs-thermal
PS=/sys/class/power_supply
W=/data/local/tmp/acctherm
WIN=${WIN:-150}
rm -rf $W 2>/dev/null; mkdir -p $W

t(){ cat $PS/battery/temp 2>/dev/null; }
i(){ cat $PS/battery/current_now 2>/dev/null; }
ccl(){ cat $PS/battery/charge_control_limit 2>/dev/null || echo -; }
ccc(){ cat $PS/battery/constant_charge_current 2>/dev/null || echo -; }
lvl(){ cat $PS/battery/capacity 2>/dev/null; }
st(){ cat $PS/battery/status 2>/dev/null; }

echo "=== $ID ==="
echo "device: $(getprop ro.product.device)  level $(lvl)%  temp $(( $(t) / 10 ))C  status $(st)"
[ "$(cat $PS/usb/present 2>/dev/null)" = 1 ] || { echo "ABORT: start this PLUGGED."; exit 1; }
[ "$(st)" = Charging ] || { echo "ABORT: status is $(st), not Charging."; exit 1; }
_c=$(sed -n "s/^maxChargingCurrent=//p" /data/adb/vr25/acc-data/config.txt)
[ "$_c" = "()" ] || { echo "ABORT: a current cap is configured ($_c). Clear it first."; exit 1; }
echo "no cap configured - good"

restore(){ trap - EXIT INT TERM HUP; acc -D start >/dev/null 2>&1; sleep 5
  echo; echo "daemon at exit: $(pgrep -f accd.sh | head -1)"; }
trap restore EXIT INT TERM HUP

sample(){  # $1 = state label, $2 = seconds
  _e=0
  while [ $_e -lt $2 ]; do
    echo "$1 $(t) $(i) $(ccl) $(ccc) $(lvl)" >> $W/samples
    sleep 10; _e=$((_e+10))
  done
}

: > $W/samples
for round in 1 2; do
  echo "-- round $round: ACC ON for ${WIN}s"
  acc -D start >/dev/null 2>&1; sleep 20
  sample ON $WIN
  echo "-- round $round: ACC OFF for ${WIN}s"
  acc -D stop >/dev/null 2>&1; sleep 20
  sample OFF $WIN
done
acc -D start >/dev/null 2>&1

echo
echo "===== samples by 1C temperature bin ====="
awk '
{ state=$1; temp=int($2/10); cur=$3; if (cur<0) cur=-cur
  key=state" "temp; sum[key]+=cur; n[key]++; bins[temp]=1 }
END {
  printf "  %-6s %10s %10s %10s\n", "tempC", "ON mA", "OFF mA", "diff"
  agree=0; disagree=0
  for (b in bins) {
    on = (n["ON "b]  ? sum["ON "b] /n["ON "b] /1000 : -1)
    of = (n["OFF "b] ? sum["OFF "b]/n["OFF "b]/1000 : -1)
    if (on<0 || of<0) continue
    d = of-on
    printf "  %-6s %10.0f %10.0f %+10.0f\n", b, on, of, d
    if (d > 150) disagree++; else agree++
  }
  print ""
  if (disagree==0 && agree>0)
    print "  VERDICT: inside every shared temperature bin, ACC off is NOT meaningfully faster."
  else if (disagree>0 && agree==0)
    print "  VERDICT: ACC off is faster in EVERY shared bin - ACC is implicated."
  else if (disagree>0)
    printf "  VERDICT: mixed - ACC off faster in %d bin(s), not in %d. Needs a longer run.\n", disagree, agree
  else
    print "  VERDICT: no temperature bin was visited in both states - run it longer."
}' $W/samples

echo
echo "===== raw ====="
echo "  state temp(dC) current ccl ccc level"
cat $W/samples
restore
