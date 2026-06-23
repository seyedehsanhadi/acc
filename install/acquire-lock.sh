# usage: . $0
id=acc
set +o sh 2>/dev/null || :
exec 4<>$TMPDIR/${id}.lock || exit 13
flock -n 0 <&4 || exit 13
echo $$ >$TMPDIR/${id}.lock   # rc6 (F1): write via O_TRUNC (not >&4) so a shorter new PID can't leave stale trailing bytes of a longer previous PID -> release-lock reads a clean PID
print_hang >/dev/null 2>&1 && print_hang 2>&1 || :
