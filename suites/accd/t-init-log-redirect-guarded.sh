#!/system/bin/sh
# The daemon's init log redirect must be guarded by a writability probe.
#
# accd redirects its own stdout into $dataDir/logs/init.log. If /data is not writable - an
# encrypted-but-not-yet-unlocked boot, a full partition, a read-only remount - then `exec >` on
# that path FAILS, and a failed exec redirect kills a non-interactive shell outright. The daemon
# dies before it has written a single word explaining why. The guard exists so that case falls
# back to /dev/null and the daemon keeps running with the limit held but no log.
#
# The mega2 mutation phase removes the probe:
#   if : > $dataDir/logs/init.log 2>/dev/null; then   ->   if true; then
# and reported "NO suite fails with the defect present. This is a real coverage hole."
#
# Nothing writes to stdout here, so the proof is a sentinel file written AFTER the redirect: if
# the shell survived, the sentinel exists.

ID=t-init-log-redirect-guarded
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=${AD:-$execDir/accd.sh}
[ -f "$AD" ] || { no "missing $AD"; fin; exit $?; }

_TMPD0=${TMPDIR:-}
[ -d "${_TMPD0:-/nonexistent}" ] || _TMPD0=/data/local/tmp
[ -d "$_TMPD0" ] || _TMPD0=/tmp
[ -d "$_TMPD0" ] || _TMPD0=.

# Lift the redirect block. Anchor on the `exec >` line, which BOTH arms keep - anchoring on the
# probe itself would miss the mutant and report "could not lift" instead of a failure.
_n=$(grep -n 'exec > \$dataDir/logs/init\.log' "$AD" 2>/dev/null | head -1 | cut -d: -f1)
case "${_n:-x}" in
  ''|*[!0-9]*) no "could not locate the init.log redirect in accd.sh - no verdict"; fin; exit $?;;
esac
BLOCK=$(sed -n "$(( _n - 1 )),$(( _n + 3 ))p" "$AD")
case "$BLOCK" in
  *if*exec*else*) : ;;
  *) no "lifted block is not the guarded redirect - no verdict"; fin; exit $?;;
esac

# Run the block with $dataDir pointing somewhere unwritable, and see whether the shell survives.
survives() {
  _W=$(TMPDIR=$_TMPD0 mktemp -d) || { echo MKTEMP-FAILED; return; }
  _sent=$_W/sentinel
  # A path that cannot be created: logs/ is a regular FILE, so logs/init.log can never open.
  mkdir -p "$_W/dd"; : > "$_W/dd/logs"
  printf '%s\n' "dataDir=$_W/dd" "$BLOCK" "printf survived > $_sent" > "$_W/run.sh"
  ( sh "$_W/run.sh" ) >/dev/null 2>&1 || :
  if [ -s "$_sent" ]; then echo SURVIVED; else echo DIED; fi
  rm -rf "$_W"
}

_r=$(survives)
case "$_r" in
  MKTEMP-FAILED) no "could not create a scratch dir - no verdict"; fin; exit $?;;
esac

# --- 1: THE POINT ---------------------------------------------------------------------------
if [ "$_r" = SURVIVED ]; then
  ok "an unwritable log path falls back to /dev/null and the daemon keeps running"
else
  no "an unwritable log path kills the shell - the daemon aborts silently on a read-only or full /data, with nothing logged to say why"
fi

# --- 2: control. With a writable path the log must actually be used, not discarded ------------
_W2=$(TMPDIR=$_TMPD0 mktemp -d)
mkdir -p "$_W2/dd/logs"
printf '%s\n' "dataDir=$_W2/dd" "$BLOCK" "echo hello-from-init" > "$_W2/run.sh"
( sh "$_W2/run.sh" ) >/dev/null 2>&1 || :
if grep -q hello-from-init "$_W2/dd/logs/init.log" 2>/dev/null; then
  ok "control: with a writable path the output really lands in init.log"
else
  no "control: writable path produced no init.log content - the redirect is not happening at all"
fi
rm -rf "$_W2"

fin
