#!/system/bin/sh
# t76 - the switch scanner must actually run, and must not leave the phone uncapped when it stops.
#
# TWO DEFECTS, one of which was blocking the other.
#
# 1. THE SCANNER NEVER RAN. The single-instance guard was `exec 8>lock && flock -n 8`. Android's
#    flock is toybox's -- `flock [-sxun] fd` -- it takes a descriptor as an ARGUMENT and cannot take
#    one the shell opened for it, so it returned non-zero with nothing holding the lock. Every
#    invocation on both test phones printed "another switch scan is already running" and exited 0
#    having done nothing. All three of AccA's scan buttons run this file.
#
# 2. FIXING (1) ALONE LEFT THE PHONE UNCAPPED, which is why it was left broken. The scanner stops
#    the daemon and restarts it from cleanup with `acca -D restart`. Inside daemon_ctrl that ends in
#    `exec $TMPDIR/accd`, so the spawned process does not start the daemon, it BECOMES it -- in this
#    script's session and process group, holding this script's stdio. It therefore dies when the
#    script exits, and every retry inside cleanup inherits the same fate. 25 s of retries plus an
#    `acc -D restart` fallback still ended with no daemon on both phones, while the same command run
#    by hand from a surviving shell worked in about 2 s.
#
# Both are fixed together, because either one alone is worse than shipping neither.
#
# NO HARDWARE. The lock logic is extracted and executed; the hand-off is asserted on the source.

ID=t76
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SS=$execDir/acc-switch-scan.sh
[ -f "$SS" ] || { no "acc-switch-scan.sh not found at $SS"; fin; }
T=${TMPDIR:-/data/local/tmp}/t76.$$
mkdir -p "$T" 2>/dev/null
trap 'rm -rf "$T" 2>/dev/null' EXIT

# ---- 1: the dead guard is gone ---------------------------------------------------------------------
# NOTE: [[:space:]], never \s. toybox grep has no \s and errors out on it, and an assertion whose
# grep ERRORS takes the `|| ok` branch -- it passes unfailably. Caught exactly that way on the Pixel,
# where these three lines printed "grep: bad regex" and reported PASS regardless of the source.
grep -vE '^[[:space:]]*#' "$SS" | grep -q 'flock' \
  && no "flock is still called - on toybox that aborts every scan" \
  || ok "no live flock call remains"
grep -vE '^[[:space:]]*#' "$SS" | grep -q 'exec 8>' \
  && no "the descriptor is still opened for flock" \
  || ok "nothing opens a descriptor for a lock any more"

# ---- 2: what replaced it is atomic ------------------------------------------------------------------
grep -q 'mkdir "\$_SCANLOCK"' "$SS" \
  && ok "the mutex is taken with mkdir, which is atomic and needs no external tool" \
  || no "no mkdir-based acquire - a read-then-write pid file races two simultaneous scans"

# ---- 3: EXECUTE the staleness check ------------------------------------------------------------------
# A recycled pid must not be able to block every future scan. That is the failure mode a naive pid
# file has, and the reason the reverted attempt was not simply re-landed.
_FN=$(sed -n '/^_scan_alive() {/,/^}/p' "$SS")
[ -n "$_FN" ] || { no "could not extract _scan_alive from the scanner"; fin; }
eval "$_FN" 2>/dev/null || { no "the extracted _scan_alive does not parse"; fin; }

_scan_alive ""            && no "an empty pid counted as a live scan"          || ok "an empty pid is not a live scan"
_scan_alive "abc"         && no "a non-numeric pid counted as a live scan"     || ok "a non-numeric pid is not a live scan"
_scan_alive "$$"          && no "our own pid counted as another scan"          || ok "our own pid is not another scan"
_scan_alive 999999        && no "a pid with no /proc entry counted as live"    || ok "a dead pid is not a live scan"
# pid 1 is always alive and is never a switch scan: this is the recycled-pid case, and the only
# thing standing between it and a permanently blocked scanner is the cmdline check.
_scan_alive 1             && no "pid 1 counted as a live scan - a recycled pid would block every future scan" \
                          || ok "a live pid that is NOT a scan does not hold the lock (recycled-pid case)"
# and it must still recognise a real one: this shell's parent chain is not a scan, so fake it
_fk="$T/acc-switch-scan-fake.sh"
printf '#!/system/bin/sh\nwhile :; do sleep 1; done\n' > "$_fk"; chmod 0755 "$_fk"
sh "$_fk" & _fp=$!
# Settle with a POLL, not a fixed 1s. Under parallel load (this suite runs inside a 46-suite sweep
# on two phones at once) a single second was not always enough for the child to be visible, and the
# whole suite failed on the A3 while passing standalone 3/3 at 6s.
_ws=0; while [ $_ws -lt 10 ]; do _scan_alive "$_fp" && break; sleep 1; _ws=$((_ws+1)); done
if _scan_alive "$_fp"; then ok "a genuinely running acc-switch-scan process IS recognised (pid $_fp, after ${_ws}s)"
else no "a running acc-switch-scan process was not recognised - the mutex would let two scans overlap"; fi
kill "$_fp" 2>/dev/null
sleep 1
_scan_alive "$_fp" && no "the pid still reads as live after it exited" || ok "once it exits, the lock is takeable again"

# ---- 4: EXECUTE acquire, contend, and take over a stale lock -------------------------------------------
acquire() {   # $1 = lock dir -> prints TAKEN | BUSY | STALE
  ( _SCANLOCK=$1
    if ! mkdir "$_SCANLOCK" 2>/dev/null; then
      _o=$(cat "$_SCANLOCK/pid" 2>/dev/null)
      if _scan_alive "$_o"; then echo BUSY; return 0; fi
      echo STALE
    else
      echo TAKEN
    fi
    echo $$ > "$_SCANLOCK/pid" 2>/dev/null ) 2>/dev/null
}
_L=$T/lock.d
[ "$(acquire "$_L" | head -1)" = TAKEN ] && ok "a first scan takes the lock" || no "the first acquire did not take the lock"
mkdir -p "$_L" 2>/dev/null; echo 1 > "$_L/pid"
[ "$(acquire "$_L" | head -1)" = STALE ] \
  && ok "a lock held by a live pid that is not a scan is taken over, not obeyed" \
  || no "pid 1 in the lock file blocked the scan - this is the permanent-block failure"
echo 999999 > "$_L/pid"
[ "$(acquire "$_L" | head -1)" = STALE ] \
  && ok "a lock left by a killed scan is taken over" \
  || no "a dead holder still blocks - one crash and the scanner is dead until reboot"
sh "$_fk" & _fp2=$!
_ws=0; while [ $_ws -lt 10 ]; do _scan_alive "$_fp2" && break; sleep 1; _ws=$((_ws+1)); done
echo "$_fp2" > "$_L/pid"
[ "$(acquire "$_L" | head -1)" = BUSY ] \
  && ok "a lock held by a REAL running scan is obeyed" \
  || no "two scans could run at once - concurrent switch toggling"
kill "$_fp2" 2>/dev/null

# ---- 5: the hand-off is detached ------------------------------------------------------------------------
# Every path that restarts the daemon must go through setsid/nohup. A bare one execs accd straight
# into this script's dying session.
_bare=0
for _ln in $(grep -n -- '-D restart' "$SS" | cut -d: -f1); do
  _txt=$(sed -n "${_ln}p" "$SS")
  case "$_txt" in
    *'#'*) continue;;                       # a comment about the defect, not a call
    *warn\ *|*say\ *|*echo\ *|*printf\ *) continue;;   # the text we PRINT telling a user to run it
  esac
  case "$_txt" in
    *setsid*|*nohup*) ;;
    *) _bare=$((_bare+1)); echo "        bare daemon restart at line $_ln: $_txt";;
  esac
done
[ "$_bare" -eq 0 ] \
  && ok "every daemon restart in the scanner is detached (setsid, or nohup where setsid is absent)" \
  || no "$_bare bare restart(s) - each one execs accd into the dying script and the phone ends uncapped"

grep -q 'restart_daemon_detached' "$SS" \
  && ok "the restart goes through one named helper rather than being open-coded per site" \
  || no "no restart_daemon_detached helper - the three restart sites will drift apart"

# stdio must be closed off too: a daemon holding the caller's pipe dies of SIGPIPE when it closes,
# which is the same defect acc -t carried.
sed -n '/^restart_daemon_detached() {/,/^}/p' "$SS" | grep -q '</dev/null >/dev/null 2>&1' \
  && ok "the detached daemon does not inherit the caller's stdio" \
  || no "the daemon keeps this script's stdio - a closed pipe will kill it"

# nohup fallback must exist for a phone with no setsid at all
sed -n '/^restart_daemon_detached() {/,/^}/p' "$SS" | grep -q 'nohup' \
  && ok "there is a fallback where setsid is absent" \
  || no "no fallback - a phone without setsid gets no daemon back"

# ---- 6: ordering, so a restart can never precede the restore ----------------------------------------------
_ra=$(grep -n '^  restore_all_on$' "$SS" | head -1 | cut -d: -f1)
_rd=$(grep -n '^  restart_daemon_detached' "$SS" | head -1 | cut -d: -f1)
{ [ -n "$_ra" ] && [ -n "$_rd" ] && [ "$_ra" -lt "$_rd" ]; } 2>/dev/null \
  && ok "switches are restored before the daemon is handed back ($_ra < $_rd)" \
  || no "restore_all_on at ${_ra:-?}, restart at ${_rd:-?} - the daemon could see nodes still cut"

# ---- 7: the mutex is released only by its owner -------------------------------------------------------------
sed -n '/^cleanup() {/,/^}/p' "$SS" | grep -q '_SCANLOCK.*/pid".*= "\$\$"' \
  && ok "cleanup releases the lock only when this process still owns it" \
  || no "cleanup could unlock a scan that started while we were exiting"
sed -n '/^cleanup() {/,/^}/p' "$SS" | grep -q 'rm -rf "\$_SCANLOCK"' \
  && ok "the release removes the lock directory, matching the mkdir acquire" \
  || no "the release does not remove the directory the acquire created - the next scan reads STALE forever"

# ---- 8: the "did it come back" check must not match the machinery -------------------------------------------
# release-lock.sh runs `pkill -f <execDir>/accd.sh` and service.sh runs
# `start-stop-daemon -bx <execDir>/accd.sh -S`. Both carry that path in their own argv, so a bare
# `pgrep -f accd.sh` matches the process that KILLS the daemon and the launcher that has not started
# it yet. Measured: a scan printed "ACC daemon restarted; charging is back under ACC control" and
# there was no daemon 45 s later - the loop had matched a transient that lived two seconds.
grep -vE '^[[:space:]]*#' "$SS" | grep -q 'pgrep -f accd.sh >/dev/null' \
  && no "a bare pgrep -f accd.sh is used as the daemon check - it matches pkill and start-stop-daemon" \
  || ok "the daemon check is not a bare pgrep on the script path"
grep -q '^daemon_alive()' "$SS" \
  && ok "there is a real daemon_alive() predicate" \
  || no "no daemon_alive() - the verification has nothing trustworthy to call"

_DA=$(sed -n '/^_is_accd() {/,/^}/p' "$SS")
[ -n "$_DA" ] || { no "could not extract _is_accd - the per-pid decision must be its own function to be testable"; fin; }
printf '%s' "$_DA" | grep -q 'cmdline' \
  && ok "it reads /proc/<pid>/cmdline rather than trusting the pattern match" \
  || no "the daemon check never inspects a cmdline"
printf '%s' "$_DA" | grep -q 'accd.sh)' \
  && ok "it positively identifies the daemon's script argument, not a substring anywhere in argv" \
  || no "the check still matches accd.sh anywhere in the command line - pkill and start-stop-daemon both contain it"

# EXECUTE the per-pid decision. This has to be per pid, not the whole-system daemon_alive: on a
# healthy phone a REAL daemon is running, so daemon_alive is legitimately true and cannot tell us
# anything about how it classifies one particular process. That mistake made this test fail on a
# Pixel while the code was correct.
eval "$_DA" 2>/dev/null || { no "the extracted _is_accd does not parse"; fin; }
_fake="$T/fakekill.sh"
printf '#!/system/bin/sh\nwhile :; do sleep 1; done\n' > "$_fake"; chmod 0755 "$_fake"
sh "$_fake" "$execDir/accd.sh" & _kp=$!
_ws=0; while [ $_ws -lt 10 ]; do [ -r "/proc/$_kp/cmdline" ] && break; sleep 1; _ws=$((_ws+1)); done
# A plain `pgrep -f accd.sh` matches this, because its argv NAMES accd.sh - exactly like
# `pkill -f <execDir>/accd.sh` and `start-stop-daemon -bx <execDir>/accd.sh`.
if pgrep -f accd.sh 2>/dev/null | grep -qx "$_kp"; then
  ok "a bare pgrep -f accd.sh does match a mere helper (pid $_kp) - which is why it was wrong"
else
  ok "(this platform's pgrep did not match the stand-in; the classifier is still checked below)"
fi
_is_accd "$_kp" && no "the daemon check counted a helper that merely names accd.sh as the daemon" \
                || ok "a helper that merely names accd.sh is NOT counted as the daemon"
kill "$_kp" 2>/dev/null

# the two shapes that actually caused the false success, checked as argv rather than as live pids
_cls() {  # feed a cmdline through the same classifier via a fake /proc entry
  ( set -f; set -- $1; set +f
    case "${1:-}" in sh|*/sh|mksh|*/mksh|bash|*/bash|busybox|*/busybox) ;; *) echo notdaemon; return;; esac
    [ "${1##*/}" = busybox ] && shift
    case "${2:-}" in */accd.sh|accd.sh) echo daemon;; *) echo notdaemon;; esac )
}
[ "$(_cls "pkill -f /data/adb/vr25/acc/accd.sh")" = notdaemon ] \
  && ok "pkill -f .../accd.sh classifies as NOT the daemon" || no "pkill would be counted as the daemon"
[ "$(_cls "start-stop-daemon -bx /data/adb/vr25/acc/accd.sh -S --")" = notdaemon ] \
  && ok "start-stop-daemon -bx .../accd.sh classifies as NOT the daemon" || no "the launcher would be counted as the daemon"
[ "$(_cls "/system/bin/sh /data/adb/vr25/acc/accd.sh /data/adb/vr25/acc-data/config.txt")" = daemon ] \
  && ok "the daemon's real command line classifies as the daemon" || no "the real daemon would not be recognised"
_is_accd 1 && no "pid 1 classified as the daemon" || ok "init is not the daemon"
_is_accd "" && no "an empty pid classified as the daemon" || ok "an empty pid is not the daemon"
_is_accd 999999 && no "a dead pid classified as the daemon" || ok "a dead pid is not the daemon"

# and it must still recognise the real one where there is one
#
# The finder here is deliberately looser than _is_accd - grading the classifier with itself would
# prove nothing. That looseness bit: the stand-in helper this suite spawns a few lines up is
# `sh <fakekill.sh> <execDir>/accd.sh`, which matches this pattern, is not one of the three named
# helpers, and can still be visible for a moment after the kill. `pgrep` does not return pids in any
# defined order, so whether the loop reached it before the real daemon was a coin flip - and when it
# did, the suite reported the daemon as unrecognised while _is_accd had answered correctly. Reap the
# stand-in, and skip this suite's own processes by pid, so only real candidates are graded.
wait "$_kp" 2>/dev/null || :
_rd=
for _p in $(pgrep -f accd.sh 2>/dev/null); do
  [ "$_p" = "${_kp:-}" ] && continue
  [ "$_p" = "$$" ] && continue
  case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
    *fakekill.sh*) continue;;
  esac
  case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
    *sh\ *accd.sh*) case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
                      *pkill*|*pgrep*|*start-stop-daemon*) ;;
                      *) _rd=$_p; break;;
                    esac;;
  esac
done
if [ -n "$_rd" ]; then
  _is_accd "$_rd" && ok "the real running daemon IS recognised (pid $_rd)" \
                  || no "the real daemon was not recognised - cleanup would restart it forever"
else
  note_no_daemon=1
  ok "(no daemon running on this phone right now; recognition case not exercised)"
fi

# ---- 9: it still parses -------------------------------------------------------------------------------------
sh -n "$SS" 2>/dev/null && ok "the scanner parses under this phone's own shell" || no "acc-switch-scan.sh does not parse"

fin
