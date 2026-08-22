#!/system/bin/sh
# t116 - `acc -t` must exit with a status, not die from a signal it arranged itself.
#
# THE DEFECT, measured on a Pixel 6a, unplugged, with no outer timeout of any kind:
#
#     ACC_T_WAIT=30 acc -t   ->  printed "Giving up after 30s", restored the daemon, exit 143
#     ACC_T_WAIT=15 acc -t   ->  same, exit 137
#
# 143 is 128+15 (SIGTERM) and 137 is 128+9 (SIGKILL). Nothing external was killing it. A watcher
# sampling once a second showed the mechanism:
#
#     t=0    lock=[18323]  accd=[18323]      the old daemon holds acc.lock
#     t=10   lock=[22840]  accd=[]           acc -t stopped it and wrote ITS OWN pid into the lock
#     t=59   acc=no        accd=[24120]      acc -t dies at the instant the new daemon appears
#
# acquire-lock.sh records the holder by writing `echo $$` into acc.lock. On the way out, exxit
# starts the daemon again - and the daemon's startup releases the lock by killing whatever pid it
# finds in that file. That pid is `acc -t` itself. release-lock.sh sends SIGTERM, waits two seconds
# and sends SIGKILL, which is exactly the 143-then-137 pair observed.
#
# WHY IT MATTERS. The command does its whole job first: the message prints, the daemon comes back,
# the switch is restored. Only the status is wrong - and a status of 143 tells every script, wrapper
# and CI step that the command was killed. It also masks the real exit code, which carries meaning
# (10 = nothing to test).
#
# WHY IT WAS INVISIBLE UNTIL NOW. The give-up branch was unreachable before rc24: the wait counted
# loop iterations rather than seconds, so on an unplugged phone the loop exited for other reasons
# long before the ceiling. Fixing the ceiling made this path run for the first time. See t114.
#
# THIS TEST NEEDS A PHONE, UNPLUGGED. It runs the real `acc -t`, which stops and restarts the real
# daemon. It refuses to run rather than score anything if a cable is attached, and it verifies the
# daemon is back before it finishes.

ID=t116
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
M=$execDir
PS=/sys/class/power_supply
W=${W:-/data/local/tmp/t116}
WAIT=${ACC_T_WAIT:-15}
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
daemon_pid(){ pgrep -f "$M/accd.sh" 2>/dev/null | head -1; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null
[ "$(id -u)" = 0 ] || { no "not root"; fin; }
[ -f "$M/acc.sh" ] || { no "no acc.sh at $M"; fin; }

# ---- preflight: unplugged, and a daemon to restore --------------------------------------------------
_plug=no
for _n in $PS/*/present $PS/*/online; do
  [ -f "$_n" ] || continue
  case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac
  [ "$(rd "$_n")" = 1 ] && _plug=yes
done
if [ "$_plug" = yes ]; then
  echo "  ABORT: a cable is attached. acc -t behaves differently when it can actually test a switch;"
  echo "         this suite grades the give-up path, which needs an unplugged phone."
  echo "$ID: no verdict"
  exit 0
fi
ok "no cable attached, so acc -t will reach its give-up path"

_pid0=$(daemon_pid)
[ -n "$_pid0" ] && ok "a daemon is running before the test (pid $_pid0)" \
                || sk "no daemon running beforehand - the restore check below will be weaker"

# ---- the grader must be able to see a signal death ---------------------------------------------------
# If this cannot distinguish a killed process from a clean one, every result below is meaningless.
( sh -c 'kill -TERM $$' ) >/dev/null 2>&1
_selfrc=$?
case "$_selfrc" in
  143|137) ok "grader can see a signal death (a self-TERMed shell reported $_selfrc)" ;;
  *) no "grader cannot detect a signal death (got $_selfrc) - the assertions below prove nothing"; fin ;;
esac

# ---- run the real thing, with NO outer timeout ------------------------------------------------------
# An outer timeout would be indistinguishable from the defect. Nothing here may send a signal.
echo "  running acc -t with ACC_T_WAIT=$WAIT and no backstop..."
_t0=$(date +%s)
ACC_T_WAIT=$WAIT $M/acc.sh -t </dev/null > $W/out.txt 2>&1
_rc=$?
_el=$(( $(date +%s) - _t0 ))
echo "  (ran ${_el}s, exit $_rc)"

# ---- 1: THE DEFECT ------------------------------------------------------------------------------------
case "$_rc" in
  143) no "acc -t died from SIGTERM (143) - it is killing itself through its own lock file" ;;
  137) no "acc -t died from SIGKILL (137) - it is killing itself through its own lock file" ;;
  129|130|131|134|139) no "acc -t died from a signal (exit $_rc)" ;;
  *)   ok "acc -t exited with a status rather than a signal ($_rc)" ;;
esac

# ---- 2: and the status must be the one the code chose --------------------------------------------------
# exitCode is set to 10 unconditionally and exxit ends with `exit $exitCode`, so the give-up path has
# exactly one correct answer. Anything else means something still overrode it.
if [ "$_rc" = 10 ]; then
  ok "the status is 10, which is what the give-up path sets"
else
  no "the status is $_rc, but the give-up path sets exitCode=10"
fi

# ---- 3: the work must still have happened ---------------------------------------------------------------
# A clean exit achieved by skipping the handover would be a worse bug than the one being fixed.
grep -qi 'giving up' $W/out.txt \
  && ok "it still reached its give-up message" \
  || no "no give-up message - the run did not reach the path under test: $(tail -2 $W/out.txt | tr '\n' ' ')"

_w=0; _pid1=
while [ $_w -lt 30 ]; do _pid1=$(daemon_pid); [ -n "$_pid1" ] && break; sleep 2; _w=$((_w + 2)); done
if [ -n "$_pid1" ]; then
  ok "the daemon was restored (pid $_pid1)"
else
  no "NO DAEMON after acc -t - charging is uncapped; run: acc -D restart"
fi

# ---- 4: the lock must not still name a dead process -------------------------------------------------------
# The handover is only correct if the lock ends up owned by the daemon, not by the corpse of acc -t.
_lock=$(rd /dev/.vr25/acc/acc.lock)
if [ -n "$_pid1" ] && [ "$_lock" = "$_pid1" ]; then
  ok "acc.lock names the running daemon ($_lock)"
elif [ -n "$_lock" ] && kill -0 "$_lock" 2>/dev/null; then
  ok "acc.lock names a live process ($_lock)"
else
  no "acc.lock names '$_lock', which is not a running process - the next release will signal a stale pid"
fi

fin
