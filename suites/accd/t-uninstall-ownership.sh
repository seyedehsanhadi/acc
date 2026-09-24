#!/system/bin/sh
execDir=${execDir:-/data/adb/vr25/acc}
AWKF=${AWKF:-${0%/*}/../xf.awk}
W=${W:-/data/local/tmp/uninstall-ownership-$$}
mkdir -p "$W"
P=0; F=0
check(){ if "$@"; then P=$((P+1)); echo "PASS $*"; else F=$((F+1)); echo "FAIL $*"; fi; }
refuses(){ "$@"; [ $? != 0 ]; }
eval "$(awk -v fn=accd_pid -f "$AWKF" "$execDir/uninstall.sh")"
domain=vr25; id=acc; TMPDIR=/dev/.vr25/acc
for pid in '' 0 1 -1 bad; do check refuses accd_pid "$pid"; done
check refuses accd_pid $$
tr(){ printf '%s\n' /system/bin/sh /data/adb/vr25/acc/accd.sh; }
check accd_pid $$
readlink(){ return 1; }
tr(){ printf '%s\n' /system/bin/sh '' /unrelated/accd.sh; }
check refuses accd_pid $$
unset -f readlink
unset -f tr
cat > "$W/mounts" <<'EOF'
debugfs /dev/.vr25/acc/.debugfs debugfs rw 0 0
tracefs /dev/.vr25/acc/.debugfs/tracing tracefs rw 0 0
debugfs /sys/kernel/debug debugfs rw 0 0
debugfs /dev/.vr25/acc/.debugfs-other debugfs rw 0 0
EOF
body=$(sed -n '/^  for _mount in /,/^  done/p' "$execDir/uninstall.sh" | sed "s@/proc/mounts@$W/mounts@g")
umount(){ case "$1" in -l) shift; [ "${LAZY_OK:-1}" = 1 ] || return 1; echo "lazy:$1" >> "$W/unmounted"; return 0;; esac
  echo "$1" >> "$W/unmounted"; [ "${FAIL_UNMOUNT:-0}" = 0 ]; }
_mfm=$TMPDIR/.debugfs
: > "$W/unmounted"
( eval "$body" )
check test "$(cat "$W/unmounted")" = "$_mfm/tracing
$_mfm"
# A cleanup step that runs BEFORE the charge-node restore must never abort the uninstall:
# the daemon is already dead by here, so an exit leaves the phone capped with nothing running.
FAIL_UNMOUNT=1
: > "$W/unmounted"
( eval "$body" )
check test $? = 0
check test "$(cat "$W/unmounted")" = "$_mfm/tracing
lazy:$_mfm/tracing
$_mfm
lazy:$_mfm"
LAZY_OK=0
: > "$W/unmounted"
out=$( eval "$body" 2>&1 ); rc=$?
check test "$rc" = 0
check test -n "$out"
FAIL_UNMOUNT=0; LAZY_OK=1

# The domain bin dir is ACC's own; it must go with ACC, but only when no other
# module of the same domain is still installed.
bin_body=$(sed -n '/^  # ACC created/,/^  rmdir /p' "$execDir/uninstall.sh" | sed "s@/data/adb/\$domain@$W/adb@g")
[ -n "$bin_body" ] || { echo "FAIL could not lift the domain-dir cleanup from uninstall.sh"; F=$((F+1)); }
mkdir -p "$W/adb/bin"; : > "$W/adb/busybox"; : > "$W/adb/bin/busybox"
( eval "$bin_body" )
check test ! -e "$W/adb/bin"
check test ! -e "$W/adb"
mkdir -p "$W/adb/bin" "$W/adb/othermod"; : > "$W/adb/bin/busybox"
( eval "$bin_body" )
check test -e "$W/adb/bin/busybox"
check test -e "$W/adb/othermod"
echo "$P passed, $F failed"
[ "$F" = 0 ]
