#!/system/bin/sh
# Is the daemon actually looping, and where is it?
P=$(cat /dev/.vr25/acc/acc.lock)
LOG=$(ls -t /data/adb/vr25/acc-data/logs/acc-daemon*.log 2>/dev/null | head -1)
echo "daemon=$P alive=$([ -d /proc/$P ] && echo yes || echo NO)"
echo "log=$LOG size=$(du -k "$LOG" 2>/dev/null | cut -f1)k"
echo "--- wchan/state ---"
cat /proc/$P/stat 2>/dev/null | awk '{print "state="$3" utime="$14" stime="$15}'
echo "--- log grows? ---"
a=$(wc -l < "$LOG" 2>/dev/null); sleep 20; b=$(wc -l < "$LOG" 2>/dev/null)
echo "lines $a -> $b in 20s (delta $((b - a)))"
echo "--- last 25 log lines ---"
tail -25 "$LOG" 2>/dev/null
