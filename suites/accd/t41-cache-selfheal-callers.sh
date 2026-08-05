#!/system/bin/sh
# t41 - the cache self-heal has to reach every caller, not just a daemon that is starting up.
#
# t40 fixed the rebuild decision inside accd's init. That is one of four ways into the cache, and it
# is the one that matters least in the field: a daemon restart was already the workaround. The other
# three -- `acc` on the command line, AccA (which reads through `acc`), and acc-switch-scan -- all
# hit the same branch in batt-interface.sh, and that branch did this:
#
#     touch $TMPDIR/.batt-interface.sh
#     . $TMPDIR/.batt-interface.sh
#
# touch CREATES the file when it is missing. So the caller sourced an empty file, every learned fact
# came back unset -- no gauge, no current node, no temperature -- and it carried on regardless.
#
# Caught on the Pixel: the cache was truncated with the daemon left running. The daemon stayed up
# and kept enforcing from the variables already in its memory, so every liveness check passed, while
# `acc -i` answered with nothing at all. AccA reads that. A phone in this state looks dead to the app
# and healthy to itself, and stays that way until the daemon happens to restart -- which is why the
# same test passed on the A3, where it restarted by chance mid-run.
#
# Two more things checked here, both introduced by the fix rather than found in the field:
#   - the cache write is now atomic, because a CLI call rebuilding it is a second writer and the old
#     in-place truncate was only ever argued safe on the grounds that accd was the only one.
#   - the guard around the applied-cap record is a real condition. `${_INIT:-false} && { ...; }`
#     evaluates to 1 when _INIT is false, and accd runs under set -eu, so as a bare statement it
#     would abort the daemon at init.
#
# Pure source-level test. The behavioural half -- truncate the cache on a live phone, then require
# `acc -i` to answer and the cache to come back - is L3 of suites/harness.sh.

ID=t41
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/batt-interface.sh
[ -f "$SRC" ] || { no "batt-interface.sh not found at $SRC"; fin; }

# ---- the branch now covers an unusable cache, not just an init ---------------------------------
grep -q '|| ! _cache_usable; then' "$SRC" \
  && ok "the build branch fires on an unusable cache as well as on init" \
  || no "only _INIT still triggers a rebuild - CLI callers cannot self-heal"

grep -q '_cache_usable()' "$SRC" \
  && ok "usability is one named test, shared by every caller" \
  || no "no shared usability test"

_body=$(sed -n '/_cache_usable()/,/^}/p' "$SRC")

printf '%s' "$_body" | grep -q '\-s \$TMPDIR/.batt-interface.sh' \
  && ok "usable requires non-empty (an empty file passes -f)" \
  || no "an empty cache would still count as usable"

printf '%s' "$_body" | grep -q 'battCapacity=' \
  && ok "usable requires the gauge line" \
  || no "a cache with no gauge would count as usable"

printf '%s' "$_body" | grep -q 'currFile=' \
  && ok "usable requires the current node too" \
  || no "a cache with no current node would count as usable"

# ---- the dead end is actually gone --------------------------------------------------------------
grep -q '^  touch \$TMPDIR/.batt-interface.sh$' "$SRC" \
  && no "touch-then-source is still there - it creates the empty file it then sources" \
  || ok "the touch-then-source dead end is gone"

# ---- the write is atomic -------------------------------------------------------------------------
grep -q 'batt-interface.sh.\$\$' "$SRC" \
  && ok "the cache is written to a temp file" \
  || no "the cache is still truncated in place"

grep -q 'mv -f \$TMPDIR/.batt-interface.sh.\$\$ \$TMPDIR/.batt-interface.sh' "$SRC" \
  && ok "and renamed into place, so a reader never sees it half-built" \
  || no "no rename - a concurrent reader can see a partial cache"

sed -n '/batt-interface.sh.\$\$/,/^$/p' "$SRC" | grep -q 'rm -f' \
  && ok "a failed write cleans up its temp file" \
  || no "a failed write would leave a temp file behind"

# ---- set -eu safety ------------------------------------------------------------------------------
grep -q 'if \${_INIT:-false}; then rm \$curThen' "$SRC" \
  && ok "the applied-cap record is dropped only on a genuine init" \
  || no "the cap record guard is missing or is not an init-only condition"

grep -qE '^[[:space:]]*\$\{_INIT:-false\} &&' "$SRC" \
  && no "bare '\${_INIT:-false} &&' as a statement - returns 1 and set -eu aborts the daemon" \
  || ok "the init guard is a condition, not a bare && statement"

fin
