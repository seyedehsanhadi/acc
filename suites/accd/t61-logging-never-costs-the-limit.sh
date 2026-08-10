#!/system/bin/sh
# t61 - a log that cannot be written must never stop the limit being enforced.
#
# THE DEFECT
#   accd created its log directory and redirected its own output into a file there, both without
#   tolerating failure:
#
#       mkdir -p $TMPDIR $dataDir/logs
#       exec > $dataDir/logs/init.log 2>&1
#
#   If that directory could not be created or written - a full /data, a corrupted partition, an
#   SELinux denial, a filesystem not fully mounted when the daemon starts - `exec >` failed and the
#   daemon ABORTED before enforcing anything. Charge control was therefore lost because a log file
#   could not be opened, and lost in silence, because the redirect that would have recorded the
#   reason is the thing that failed.
#
#   Not reachable through a normal install: $domain and $id are hardcoded, so $dataDir always
#   resolves to /data/adb/vr25/acc-data. That is why it has never been reported, and it is inherited
#   unchanged from upstream (VR-25's accd, same two lines). It is still the wrong priority. The limit
#   is the product; the log is a convenience.
#
# WHAT IS ASSERTED
#   1. The log directory creation tolerates failure.
#   2. The redirect is CONDITIONAL - it must not be the thing that ends the daemon.
#   3. There is a fallback that discards output, so the daemon proceeds either way.
#   4. $TMPDIR's own mkdir is still NOT suppressed, deliberately: the daemon genuinely cannot run
#      without it (tmpfs is wiped every boot, and a cold `accd --init` died at the lock with exit 13
#      before that mkdir existed), and a failure there surfaces at the lock where it is diagnosable.
#
# NO HARDWARE.

ID=t61
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
LF=$execDir/logf.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }

# The init block, comments stripped: its own commentary quotes the very lines being checked.
_blk=$(sed -n '/# log$/,/set -x/p' "$AD" | sed 's/#.*//')
[ -n "$_blk" ] || { no "could not locate accd's log-init block"; fin; }

# ---- 1: the log directory creation tolerates failure -------------------------------------------------
if printf '%s' "$_blk" | grep -q 'mkdir -p \$dataDir/logs 2>/dev/null'; then
  ok "the log directory is created tolerantly - an unwritable data partition cannot end the daemon here"
else
  no "mkdir of the log directory is still unsuppressed - a full or read-only /data aborts the daemon at startup"
fi

# ---- 2: the redirect is conditional ------------------------------------------------------------------
# The failure mode is specifically `exec >` on an unopenable path, so the fix KEEPS that line and puts
# a writability test in front of it. Asserting the line is absent is therefore wrong - the first
# version of this check did exactly that and failed a correct build, because the redirect still
# appears (indented) inside the guard. What matters is the ORDER: the test must come first.
_gline=$(printf '%s' "$_blk" | grep -n 'if : > \$dataDir/logs/init.log' | head -1 | cut -d: -f1)
_rline=$(printf '%s' "$_blk" | grep -n 'exec > \$dataDir/logs/init.log' | head -1 | cut -d: -f1)
if [ -n "$_gline" ] && [ -n "$_rline" ]; then
  [ "$_gline" -lt "$_rline" ] 2>/dev/null \
    && ok "the writability test runs BEFORE the redirect, so an unopenable log cannot end the daemon" \
    || no "the redirect precedes its own writability test - it would fail first and check afterwards"
else
  no "could not find both the writability test and the redirect in the log-init block"
fi

printf '%s' "$_blk" | grep -q 'if : > \$dataDir/logs/init.log 2>/dev/null' \
  && ok "the file is proven writable before anything is redirected into it" \
  || no "nothing proves the log file is writable before the redirect"

# ---- 3: there is a fallback that keeps the daemon running ----------------------------------------------
printf '%s' "$_blk" | grep -q 'exec > /dev/null' \
  && ok "an unwritable log falls back to discarding output, and the daemon carries on enforcing" \
  || no "there is no fallback - an unwritable log leaves the daemon with nowhere to send output"

# ---- 4: TMPDIR keeps its unsuppressed mkdir ------------------------------------------------------------
# This one MUST stay strict. Suppressing it would hide the failure that the rc22 tmpfs fix exists to
# surface: /dev/.vr25/acc is wiped on every boot, and a daemon that cannot recreate it cannot run at
# all. Better to fail at the lock, where it is diagnosable, than to run without a scratch directory.
if printf '%s' "$_blk" | grep -qE '^ *mkdir -p \$TMPDIR *$'; then
  ok "TMPDIR's mkdir is still strict - the daemon cannot run without it, so that failure must stay visible"
else
  printf '%s' "$_blk" | grep -q 'mkdir -p \$TMPDIR' \
    && no "TMPDIR's mkdir has been suppressed too - a wiped tmpfs would now fail silently at the lock instead of reporting" \
    || no "TMPDIR is no longer created in the log-init block; the cold-start bootstrap fix is gone"
fi

# ---- 5: the same shape in logf.sh -----------------------------------------------------------------------
# Lower stakes - the exit path calls enable_charging BEFORE reaching the log export, so charge state is
# already safe by then - but it is the same construct and the same wrong priority.
if [ -f "$LF" ]; then
  if sed 's/#.*//' "$LF" | grep -qE 'mkdir -p \$dataDir/logs *$'; then
    no "logf.sh still creates the log directory unsuppressed"
  else
    ok "logf.sh tolerates an unwritable log directory too"
  fi
else
  echo "      note  logf.sh not present; skipping"
fi

fin
