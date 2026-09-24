#!/system/bin/sh
# t160 - a bundle must answer "did the daemon ever stop, and who stopped it", and carry unit evidence.
# 28 field bundles all read "daemon UP" because users collect while it runs; none could say whether it
# had died earlier or what stopped it. Units were captured once, usually idle, which could not settle
# the OnePlus mixed mA/uA question.
ID=t160; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }; no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; exit $?; }
execDir=${execDir:-/data/adb/vr25/acc}
has(){ sed 's/^[[:space:]]*#.*//' < "$1" | grep -qF -e "$2"; }
has $execDir/release-lock.sh 'stop-request daemon=$pid by=' && ok "a stop request records who asked" || no "stop requests leave no trace"
has $execDir/accd.sh ' start pid=$$ args=' && ok "daemon start is recorded" || no "daemon start not recorded"
has $execDir/accd.sh ' exit pid=$$ code=$exitCode' && ok "daemon exit code is recorded" || no "daemon exit not recorded"
has $execDir/accd.sh 'tail -200 $_dev' && ok "event log is bounded" || no "event log can grow without bound"
for a in acc-logs/daemon-events.log acc-state.txt charging/units-sample.txt; do
  has $execDir/diag-collect.sh " $a" && ok "quick tier collects $a" || no "quick tier misses $a"
done
L=/data/adb/vr25/acc-data/logs/daemon-events.log
if [ "$(id -u)" = 0 ] && [ -s $L ]; then
  tail -1 $L | grep -qE '^[0-9]+ [0-9_:-]+ (start|exit|stop-request) ' && ok "live log line is well formed" || no "live log line malformed: $(tail -1 $L)"
fi
fin
