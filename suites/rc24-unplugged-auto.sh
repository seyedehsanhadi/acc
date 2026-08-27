#!/system/bin/sh
# Everything that can be proven with no charger attached, on the flashed rc24.
# Detached and logged to one file, so an adb drop cannot lose the result.
D=/data/adb/vr25/acc-data
A=/dev/.vr25/acc
OUT=/data/local/tmp/UNPLUGGED.log

# SINGLE INSTANCE. Every start truncates $OUT, so two rounds running at once overwrite each
# other's log and interleave their suite runs -- which looks exactly like a stall: no suite
# executing, a log that stopped advancing, and several round processes alive. Refuse to start
# instead of producing a result nobody can trust.
LOCK=/data/local/tmp/.unplugged_round.lock
# toybox flock cannot see an fd the shell opened with `exec 9>>file`; it answers "Bad file
# descriptor" and the guard then reports a phantom second round forever. The fd has to reach
# flock as a REDIRECT, which is the same form acquire-lock.sh uses (`flock -n 0 <&4`). Proven on
# laurus: holder rc=0, a second attempt rc=1, and rc=0 again once the holder exits.
exec 9<>"$LOCK" 2>/dev/null || :
if ! flock -n 0 <&9 2>/dev/null; then
  echo "another unplugged round holds $LOCK; refusing to start a second"
  exit 3
fi

exec > "$OUT" 2>&1

say(){ echo "$*"; }
hr(){ echo; echo "################ $* ################"; }

hr "0  PRECONDITION"
say "started    : $(date '+%Y-%m-%d %H:%M:%S')"
say "level      : $(cat /sys/class/power_supply/battery/capacity)%"
say "present    : $(cat /sys/class/power_supply/usb/present 2>/dev/null)"
say "status     : $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
say "module     : $(grep -E '^versionCode=' /data/adb/modules/acc/module.prop)"
say "config     : $(grep '^capacity=' $D/config.txt)"
say "build fingerprint:"
for f in accd.sh acc.sh acca.sh misc-functions.sh strings.sh cfg-guard.sh state-export.sh; do
  say "  $(md5sum /data/adb/vr25/acc/$f 2>/dev/null)"
done
# Anything still running would both distort this and be distorted by it.
for pat in runall2 rc24- preflight cpumeas; do
  for p in $(pgrep -f "$pat" 2>/dev/null); do [ "$p" = "$$" ] || kill -9 "$p" 2>/dev/null; done
done
say "strays cleared"

hr "1  UNIT SUITES (all of suites/accd)"
cd /data/local/tmp/suites/accd || { say "suites not staged"; exit 1; }
SUITEOUT=/data/local/tmp/.suite-out.$$
P=0; F=0; FL=""
for f in t*.sh; do
  # Read the suite through a FILE, never a command substitution. `out=$(sh "$f" 2>&1)` builds a
  # pipe and blocks until every writer closes it -- including any process the suite backgrounded,
  # which inherits that pipe as its stdout. t113 backgrounds a watcher loop; interrupt the suite
  # before it clears the loop's flag and the orphan holds the pipe open forever. The runner then
  # sits in pipe_read with no children and a log that never advances, which reads as a hang and
  # was diagnosed as one twice. A file has no writer to wait on.
  sh "$f" >"$SUITEOUT" 2>&1
  out=$(cat "$SUITEOUT" 2>/dev/null)
  line=$(echo "$out" | grep -E "^t[0-9]+: " | tail -1)
  case "$line" in
    *" 0 failed"*) P=$((P+1));;
    "") F=$((F+1)); FL="$FL $f(nosummary)"; say "---- $f produced no summary line";;
    *) F=$((F+1)); FL="$FL $f"; say "---- $f"; echo "$out" | grep "FAIL" | head -8;;
  esac
done
say "=> $P suites passed, $F failed"
[ -n "$FL" ] && say "=> failing:$FL"

hr "2  rc24-unplugged.sh"
if [ -f /data/local/tmp/suites/rc24-unplugged.sh ]; then
  uout=$(execDir=/data/adb/vr25/acc sh /data/local/tmp/suites/rc24-unplugged.sh 2>&1)
  echo "$uout" | grep -E '^  (FAIL|SKIP)' || :
  uv=$(echo "$uout" | grep -E '^[a-zA-Z0-9_-]+: [0-9]+ passed' | tail -1)
  say "=> ${uv:-NO VERDICT LINE}"
else
  say "=> not staged"
fi

hr "3  DAEMON STILL HEALTHY"
say "daemon procs: $(pgrep -f accd | wc -l)"
for p in $(pgrep -f accd); do say "  $(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')"; done
say "config now  : $(grep '^capacity=' $D/config.txt)"
say "config-good : $(grep '^capacity=' $D/.config-good 2>/dev/null)"
# alive is not the same as looping; flight.log is the only honest heartbeat
h0=$(tail -1 $D/logs/flight.log 2>/dev/null | cut -d, -f1)
i=0
while [ $i -lt 16 ]; do
  sleep 15; i=$((i+1))
  h1=$(tail -1 $D/logs/flight.log 2>/dev/null | cut -d, -f1)
  [ "$h1" != "$h0" ] && break
done
if [ "${h1:-}" != "${h0:-}" ]; then
  say "heartbeat   : LOOPING (advanced after $((i*15))s)"
else
  say "heartbeat   : NOT ADVANCING after 240s"
fi

hr "4  VERDICT"
say "unit suites : $P passed, $F failed"
say "unplugged   : ${uv:-none}"
say "level now   : $(cat /sys/class/power_supply/battery/capacity)%"
if [ "$F" -eq 0 ]; then say "UNPLUGGED ROUND: CLEAN"; else say "UNPLUGGED ROUND: NOT CLEAN"; fi
say "finished    : $(date '+%Y-%m-%d %H:%M:%S')"
