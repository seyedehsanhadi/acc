#!/system/bin/sh
# Prove that ACC's shutdown() really does leave a trace, so its ABSENCE on a phone means ACC did
# not power that phone off. Runs the LOGGING half of shutdown() only -- never the power-off.
DD=/data/adb/vr25/acc-data
L=$DD/logs/shutdown-trace.log
echo "logs dir writable : $([ -w $DD/logs ] && echo yes || echo NO)"
echo "trace before      : $([ -f $L ] && echo "exists, $(wc -l < $L) lines" || echo absent)"
_pre=$([ -f $L ] && wc -l < $L || echo 0)
# byte-for-byte the block from accd.sh shutdown(), minus the reboot
. $DD/../acc/batt-interface.sh 2>/dev/null || :
{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') accd shutdown [TRACECHECK - no power-off performed]"
  echo "    level=$(batt_cap 2>/dev/null) temp=$(temp_now 2>/dev/null) status=$(cat $battStatus 2>/dev/null)"
  echo "    capacity=($(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')) temperature=($(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')'))"
} >> $L 2>/dev/null || :
sync 2>/dev/null || :
_post=$([ -f $L ] && wc -l < $L || echo 0)
echo "trace after       : $([ -f $L ] && echo "exists, $_post lines" || echo STILL ABSENT)"
if [ "$_post" -gt "$_pre" ]; then
  echo "RESULT: the trace IS written and survives a sync."
  echo "        So on a phone where this file does not exist, ACC's shutdown() never ran."
  echo "--- what it recorded ---"; tail -3 $L
else
  echo "RESULT: the trace was NOT written -- absence would prove nothing."
fi
# leave the phone as we found it
[ "$_pre" = 0 ] && rm -f $L 2>/dev/null || { head -n "$_pre" $L > $L.t 2>/dev/null && mv -f $L.t $L; }
echo "restored: $([ -f $L ] && wc -l < $L || echo 0) lines"
