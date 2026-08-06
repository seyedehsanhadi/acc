#!/system/bin/sh
# Does ACC cut a healthy charge to hunt for a switch it does not need yet?
#
# Blank the locked switch on a live charge well below the pause level, then watch. Old code runs the
# off/on sweep immediately at any level; probe_due should wait until within 5% of the pause point.
# The evidence is the charge itself: input_suspend flipping, and the battery current going to zero.
DD=/data/adb/vr25/acc-data; TD=/dev/.vr25/acc
rd(){ v=; read -r v < "$1" 2>/dev/null || :; echo "$v"; }
G=/sys/class/power_supply/battery
SWSAVE=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
PAUSE=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
restore(){ [ -n "$SWSAVE" ] && acc -s charging_switch="$SWSAVE" >/dev/null 2>&1
  echo "--- restored switch: $(sed -n 's/^chargingSwitch=//p' $DD/config.txt | cut -c1-52) ---"; }
trap restore EXIT INT TERM HUP

echo "build   : $(sed -n 's/^versionCode=//p' /data/adb/vr25/acc/module.prop)"
echo "level   : $(rd $G/capacity)%   pause at ${PAUSE}%   probe_due fires at $(( PAUSE - 5 ))%"
echo "switch  : $(echo $SWSAVE | cut -c1-52)"
echo "charging: I=$(rd $G/current_now) status=$(rd $G/status) input_suspend=$(rd $G/input_suspend)"
echo
W0=$(wc -l < $TD/.write-ledger 2>/dev/null); W0=${W0:-0}
echo "BLANKING the switch (this is what a fresh install / AccA Automatic reset looks like)"
acc -s charging_switch= >/dev/null 2>&1
sleep 3
echo "config now: chargingSwitch=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt)"
echo
echo "watching 4 minutes - does ACC cut the charge to probe?"
echo "  t   level  I(uA)      suspend  status       cut?"
# Record the level at each cut, not just a count. The question is not "did ACC ever cut" - it must
# cut eventually, that is how a switch is found - but "did it cut BEFORE the probe threshold".
THRESH=$(( PAUSE - 5 ))
EARLY=0; LATE=0; i=0
while [ $i -lt 24 ]; do
  i=$((i+1)); sleep 10
  s=$(rd $G/input_suspend); c=$(rd $G/current_now)
  cf=$(tail -1 $DD/logs/flight.log 2>/dev/null | cut -d, -f7)
  if [ "$s" = 1 ]; then
    _l=$(rd $G/capacity)
    if [ "${_l:-0}" -lt "$THRESH" ] 2>/dev/null; then EARLY=$((EARLY+1)); else LATE=$((LATE+1)); fi
  fi
  printf '%4ds  %3s%%  %-10s %-8s %-12s %s\n' $((i*10)) "$(rd $G/capacity)" "$c" "$s" "$(rd $G/status)" "$cf"
done
echo
echo "cuts BEFORE the ${THRESH}% probe threshold : $EARLY   <- these are the bug"
echo "cuts at or after ${THRESH}%                  : $LATE   <- these are correct, a switch is needed"
echo "switch discovered? chargingSwitch=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | cut -c1-52)"
echo "ledger lines added: $(( $(wc -l < $TD/.write-ledger 2>/dev/null || echo 0) - W0 ))"
echo
# Three outcomes, and the middle one is the goal. Comparing against PAUSE instead of PAUSE-5 is what
# made an earlier run of this script report correct behaviour as a failure.
_sw=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
if [ "$EARLY" -gt 0 ]; then
  echo "VERDICT: ACC cut the charge $EARLY times BELOW ${THRESH}%, where no switch is needed yet."
  echo "         probe_due did not hold it back - bug 25 reproduces."
elif [ -z "$_sw" ] && [ "$LATE" -eq 0 ]; then
  echo "VERDICT: REGRESSION - no cut at all and no switch discovered. probe_due is gating too hard;"
  echo "         a phone that never probes never gets a switch and ACC can never control it."
else
  echo "VERDICT: correct. No cut below ${THRESH}% (${EARLY}), the sweep ran once needed (${LATE}),"
  echo "         and a switch was locked: ${_sw:-none}."
  echo "         Old code would have swept immediately at any level."
fi
