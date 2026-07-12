# usage: . $0
id=acc
(pid=
exec 2>/dev/null
set +euo sh || :
if ! flock -n 0; then
  # rc6 (B6): the holder writes its PID just AFTER taking the lock, so a release racing a fresh
  # acquire can read it empty. Retry a few times so we kill the real daemon instead of leaving
  # it running (AccA stop/restart silently no-op). Never kill an empty PID.
  i=0; while [ -z "$pid" ] && [ "$i" -lt 5 ]; do read pid || sleep 1; i=$((i+1)); done
  # rc6 (F3): only ever signal a real positive PID -- a blank/0/negative/garbage first line
  # (corrupt or racing lock file) must NOT become `kill 0` (whole process group) or `kill -1`.
  case "$pid" in ''|0|*[!0-9]*) pid=;; esac
  [ -z "$pid" ] || kill $pid >/dev/null
  timeout 10 flock 0
  [ -z "$pid" ] || kill -KILL $pid >/dev/null
  flock 0
fi) <>$TMPDIR/${id}.lock || :

# rc15: the flock gate above is FOOLED under AccA. libsu keeps ONE persistent root shell, and
# a leaked/inherited fd on this lock file makes `flock -n 0` wrongly SUCCEED even while the
# daemon holds it -> the PID-kill above is skipped and the Stop button silently no-ops (field
# report: "AccA didn't stop acc, I had to use the terminal"). Kill the daemon by its exact
# command line too, which does not depend on the lock/fd state at all. SIGTERM first so accd's
# EXIT trap runs and RESTORES NATIVE charging (releases the switch/cut); SIGKILL only a survivor.
# The pattern is the full daemon-script path -> matches ONLY acc's own accd.sh, never the acca
# caller (whose cmdline is ".../acca -D stop"), and pkill never signals its own pid.
if command -v pkill >/dev/null 2>&1; then
  _accd="${execDir:-/data/adb/${domain:-vr25}/${id}}/${id}d.sh"
  pkill -f "$_accd" 2>/dev/null && { sleep 2; pkill -KILL -f "$_accd" 2>/dev/null || :; } || :
  unset _accd
fi
