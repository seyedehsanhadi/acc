#!/system/bin/sh
# The switch scanner's lock must be mkdir-based, and must never be gated on flock.
#
# rc23 shipped `exec 8>"$TMPDIR/.scan.lock" && flock -n 8` and it ABORTED EVERY RUN on Android:
# toybox's flock is `flock [-sxun] fd`, it takes a descriptor as an ARGUMENT and cannot adopt one
# the shell opened, so `flock -n 8` always failed and the scanner concluded another scan held the
# lock. `exec 8>` also truncates the file, destroying the pid it would have needed to diagnose
# that. The replacement is a mkdir - atomic everywhere, present on every ROM - plus a pid file so
# a lock left by a crashed scan is recognised as stale.
#
# The mega2 mutation phase reinstates an flock guard ahead of the mkdir. Note its injected form
# is `if ...; then :; fi`, which is INERT - it aborts nothing - so the mutant does not actually
# reproduce the rc23 symptom. What is worth guarding is the shape itself: no flock may sit in the
# scanner's lock path, because the moment its result gates the run, every scan dies again.

ID=t-scan-lock-contract
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
SS=${SS:-$execDir/acc-switch-scan.sh}
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AWKF=${AWKF:-$SELF/../xf.awk}
[ -f "$SS" ]   || { no "missing $SS"; fin; exit $?; }
[ -f "$AWKF" ] || { no "missing $AWKF"; fin; exit $?; }

_TMPD0=${TMPDIR:-}
[ -d "${_TMPD0:-/nonexistent}" ] || _TMPD0=/data/local/tmp
[ -d "$_TMPD0" ] || _TMPD0=/tmp
[ -d "$_TMPD0" ] || _TMPD0=.

_src=$(sed 's/^[[:space:]]*#.*//' "$SS")   # the rationale mentions flock; the code must not use it

# --- 1: no flock anywhere in the scanner --------------------------------------------------------
if printf '%s\n' "$_src" | grep -qE '(^|[^[:alnum:]_])flock([^[:alnum:]_]|$)'; then
  no "flock appears in the scanner's code - toybox flock cannot take a shell-opened fd, and gating on it aborted every scan in rc23"
else
  ok "no flock in the scanner's code, so no ROM can fail its lock acquisition"
fi

# --- 2: the lock is a mkdir, which is atomic on every filesystem --------------------------------
printf '%s\n' "$_src" | grep -qE 'mkdir "\$_SCANLOCK"' \
  && ok "the lock is taken with mkdir, atomic and available everywhere" \
  || no "the scan lock is not a mkdir - it has no portable atomic acquisition"

# --- 3: nothing may truncate the lock file that holds the owner pid -----------------------------
if printf '%s\n' "$_src" | grep -qE 'exec [0-9]+>"?\$TMPDIR/\.scan\.lock'; then
  no "something re-opens the lock path with exec >, which truncates the pid needed to tell a live scan from a stale one"
else
  ok "nothing truncates the lock path, so the owner pid survives to be read back"
fi

# --- 4: behaviour. The three states that matter -------------------------------------------------
_a=$(grep -n '^_SCANLOCK=' "$SS" 2>/dev/null | head -1 | cut -d: -f1)
_b=$(grep -n 'echo \$\$ > "\$_SCANLOCK/pid"' "$SS" 2>/dev/null | head -1 | cut -d: -f1)
case "${_a:-x}${_b:-x}" in
  *x*) no "could not locate the scan-lock region - the behavioural cases cannot run"; fin; exit $?;;
esac
BLOCK=$(sed -n "${_a},${_b}p" "$SS")
ALIVE=$(awk -v fn=_scan_alive -f "$AWKF" "$SS" 2>/dev/null)
[ -n "$ALIVE" ] || { no "could not lift _scan_alive - the behavioural cases cannot run"; fin; exit $?; }

attempt() {   # $1 = pid to plant, empty for no lock at all
  _plant=$1
  _W=$(TMPDIR=$_TMPD0 mktemp -d) || { echo MKTEMP-FAILED; return; }
  _out=$(
    TMPDIR=$_W
    if [ -n "$_plant" ]; then mkdir -p "$_W/.scan.lock.d"; printf '%s' "$_plant" > "$_W/.scan.lock.d/pid"; fi
    warn(){ :; }
    eval "$ALIVE" >/dev/null 2>&1 || :
    ( eval "$BLOCK" >/dev/null 2>&1; echo RAN ) 2>/dev/null
  )
  rm -rf "$_W"
  case "$_out" in *RAN*) echo RAN;; *) echo ABORTED;; esac
}

_r=$(attempt "")
case "$_r" in MKTEMP-FAILED) no "could not create a scratch dir - no verdict"; fin; exit $?;; esac
[ "$_r" = RAN ] \
  && ok "with no lock present the scan proceeds" \
  || no "the scan aborted with no lock present - the switch finder could never run"

# A live OWNER must abort us. _scan_alive requires the pid's cmdline to name the scanner and to
# differ from ours, so planting a bare shell pid is rejected by design - the process has to carry
# the name.
_W2=$(TMPDIR=$_TMPD0 mktemp -d)
_fake=$_W2/acc-switch-scan-fake
# sleep is a toybox MULTICALL binary: copied under another name toybox refuses it outright
# ("Unknown command"). A script carries the name in its cmdline just as well.
printf '#!/system/bin/sh
sleep 30
' > "$_fake"
chmod 0755 "$_fake"
"$_fake" &
_fpid=$!
sleep 1
if grep -qa acc-switch-scan "/proc/$_fpid/cmdline" 2>/dev/null; then
  [ "$(attempt "$_fpid")" = ABORTED ]     && ok "a lock owned by a LIVE scan aborts the second one"     || no "a live owner did not abort the second scan - two scans could write the tree at once"
else
  no "could not stage a process whose cmdline names the scanner - case not run"
fi
kill "$_fpid" 2>/dev/null || :
rm -rf "$_W2"

[ "$(attempt 999999)" = RAN ] \
  && ok "a stale lock from a dead scan is cleared and the scan proceeds" \
  || no "a stale lock blocked the scan - one crash would disable the switch finder until reboot"

fin
