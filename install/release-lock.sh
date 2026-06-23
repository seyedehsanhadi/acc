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
