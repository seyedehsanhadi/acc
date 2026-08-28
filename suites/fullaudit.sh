#!/system/bin/sh
# Everything provable with NO charger attached, in one detached run.
# Sequential on purpose: rc24-unplugged-auto kills strays matching "rc24-", so a concurrent
# rc24-* suite would be killed mid-restore - which is how a phone lost its switch earlier.
P=/data/local/tmp/suites
L=/data/local/tmp/FULLAUDIT.log
exec > $L 2>&1
PS=/sys/class/power_supply
DD=/data/adb/vr25/acc-data

hr(){ echo; echo "################ $* ################"; }
say(){ echo "$*"; }

hr "0  PRECONDITION"
say "started : $(date '+%Y-%m-%d %H:%M:%S')"
say "device  : $(getprop ro.product.device)"
say "uptime  : $(cut -d. -f1 /proc/uptime)s"
say "level   : $(cat $PS/battery/capacity)%   present=$(cat $PS/usb/present)   status=$(cat $PS/battery/status)"
say "module  : $(grep -E '^version=|^versionCode=' /data/adb/modules/acc/module.prop | tr '\n' ' ')"
say "config  : $(grep '^capacity=' $DD/config.txt)"
say "switch  : $(grep '^chargingSwitch=' $DD/config.txt)"
say "logs    : $([ -d $DD/logs ] && echo EXISTS || echo ABSENT)"
say "fixes   : logs-ensure=$(grep -c 'mkdir -p "$dataDir/logs"' /data/adb/vr25/acc/accd.sh) pcap=$(grep -c _fsLvl /data/adb/vr25/acc/misc-functions.sh) missed-unplug=$(grep -c _pgLast /data/adb/vr25/acc/accd.sh)"

run(){   # run <suite-path> <label>
  s=$1; lbl=$2
  [ -f "$s" ] || { say "  => $lbl: NOT STAGED"; return 0; }
  o=/data/local/tmp/.fa.$(basename "$s").out
  execDir=/data/adb/vr25/acc timeout ${T:-1800} sh "$s" > "$o" 2>&1
  rc=$?
  [ "$rc" = 124 ] && say "  !! $lbl TIMED OUT after ${T:-1800}s"
  grep -E '^  (FAIL|SKIP)|^ABORT|ABORT:' "$o" | head -8
  v=$(grep -E '[a-zA-Z0-9_-]+: [0-9]+ passed' "$o" | tail -1)
  if [ -z "$v" ]; then
    if [ -f /dev/.vr25/acc/.preflight-done ] && [ "$lbl" = preflight ]; then
      v="markers: $(cat /dev/.vr25/acc/.preflight-done)"
    else
      _p=$(grep -cE '^  (PASS|ok  )' "$o" 2>/dev/null); _f=$(grep -cE '^  FAIL' "$o" 2>/dev/null)
      [ "${_p:-0}" -gt 0 ] 2>/dev/null && v="counted: ${_p} passed, ${_f} failed"
    fi
  fi
  say "  => $lbl: ${v:-(no summary, rc=$rc)}"
}

hr "1  FULL UNIT ROUND (92 suites + rc24-unplugged + heartbeat)"
rm -f /data/local/tmp/UNPLUGGED.log /data/local/tmp/.unplugged_round.lock
T=2700 sh /data/local/tmp/rc24-unplugged-auto.sh >/dev/null 2>&1
grep -E '^=>|^  FAIL|ROUND:|^heartbeat' /data/local/tmp/UNPLUGGED.log | head -20

hr "2  rc24 DELTA COVERAGE"
run $P/rc24-coverage.sh rc24-coverage

hr "3  INSTALL / BOOT VERIFY"
run $P/rc24-install-verify.sh install-verify

hr "4  PREFLIGHT (units, invariants, idle cost)"
T=2400 run $P/preflight.sh preflight

hr "5  HARNESS (abuse + recovery)"
T=2400 run $P/harness.sh harness

hr "6  SNAPSHOT"
run $P/snapshot.sh snapshot

hr "7  MEGA2 SET"
for f in $P/mega2/*.sh; do [ -f "$f" ] || continue; run "$f" "mega2/$(basename $f)"; done

hr "8  AMPS SET"
for f in $P/amps/*.sh; do [ -f "$f" ] || continue; run "$f" "amps/$(basename $f)"; done

hr "9  FINAL STATE"
say "level   : $(cat $PS/battery/capacity)%   present=$(cat $PS/usb/present)   status=$(cat $PS/battery/status)"
say "config  : $(grep '^capacity=' $DD/config.txt)"
say "switch  : $(grep '^chargingSwitch=' $DD/config.txt)"
say "mcv/mcc : $(grep -E '^maxCharging' $DD/config.txt | tr '\n' ' ')"
say "logs    : $([ -d $DD/logs ] && echo EXISTS || echo ABSENT)"
n=0
for p in $(pgrep -f accd 2>/dev/null); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null); set -f; set -- $c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh) ;; *) continue;; esac
  case "${2:-}" in */accd.sh) ;; *) continue;; esac
  pp=$(awk '{print $4}' /proc/$p/stat 2>/dev/null)
  if [ -n "$pp" ] && [ -r "/proc/$pp/cmdline" ]; then
    pc=$(tr '\0' ' ' < /proc/$pp/cmdline 2>/dev/null)
    case "$pc" in *accd.sh*) continue;; esac
  fi
  n=$((n+1))
done
say "daemons : $n (children excluded)"
F=$DD/logs/flight.log
# wc -l on a missing file prints nothing and exits non-zero, so `|| echo 0` is safe here in a way
# `grep -c ... || echo 0` is not - but coerce anyway rather than rely on the difference.
a=$(wc -l < $F 2>/dev/null); case ${a:-x} in ''|*[!0-9]*) a=0;; esac
sleep 40
b=$(wc -l < $F 2>/dev/null); case ${b:-x} in ''|*[!0-9]*) b=0;; esac
say "heartbeat: flight $a -> $b in 40s"
say "finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "FULLAUDIT DONE"
