# usage: . $0
id=acc
set +o sh 2>/dev/null || :
# rc21 (tmpfs): $TMPDIR (/dev/.vr25/acc) is tmpfs -- wiped every reboot, recreated only by service.sh at
# boot. A cold entry (KernelSU/APatch clean-flash before service.sh runs, or a boot where it never
# reached its own `mkdir`) otherwise dies on the next line opening the lock inside a non-existent
# dir (exit 13), BEFORE accd.sh's init mkdir -- so no /dev links get made and there is no recovery
# path (`accd --init` and the front-end both dead-end here). Self-bootstrap the dir so any entry can
# rebuild it. Idempotent; a no-op on every normal boot where service.sh already made it.
mkdir -p $TMPDIR 2>/dev/null || :
# rc22: fail CLOSED when the lock cannot be opened. This file is SOURCED, and in mksh a redirection
# error on `exec` (a special builtin) aborts only the dot script -- the `|| exit 13` on the next line
# never runs and the CALLER carries straight on with NO lock held, admitting a second daemon (two
# daemons then fight over the charging switch). Probe the path first with a non-special command,
# whose redirection failure is an ordinary non-zero status the `||` can actually see.
true 2>/dev/null >>$TMPDIR/${id}.lock || exit 13
exec 4<>$TMPDIR/${id}.lock || exit 13
flock -n 0 <&4 || exit 13
echo $$ >$TMPDIR/${id}.lock   # rc6 (F1): write via O_TRUNC (not >&4) so a shorter new PID can't leave stale trailing bytes of a longer previous PID -> release-lock reads a clean PID
print_hang >/dev/null 2>&1 && print_hang 2>&1 || :
