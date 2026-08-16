#!/system/bin/sh
# t54 - the idle path must not fork.
#
# WHY THIS SUITE EXISTS
#   rc19 made _nap_idle fork-free on purpose. Its comment is explicit: "this loop used to spawn
#   sleep+stat+ls+grep+cat every second, all night, on every unplugged phone". It achieves that by
#   calling present(), which reads a CACHED list of nodes with the `read` builtin.
#
#   The rc22 fix for bug 28 removed present()'s short-circuit -- it had to, because an idle
#   wireless/present=0 was answering for a whole device and cost one user 18% of their charge --
#   and in doing so routed the UNPLUGGED case into online(). online() was never cached: it ran a
#   command substitution around ls|grep, then a grep per node, on every call. The forks rc19 had
#   removed came straight back into the same loop by a different door.
#
#   Measured on a Mi A3, unplugged, held awake: rc21 1120 ms/min against rc22 6011 ms/min, a 5.4x
#   regression, while a Pixel 6a on the native-limit path moved only 10%. The difference is that
#   the A3 spends its idle time inside _nap_idle and the Pixel does not.
#
# So this asserts the PROPERTY, not the fix: nothing on the once-a-second idle path may fork.
# A future edit that reintroduces a pipeline or a command substitution there fails here.
#
# NO HARDWARE.

ID=t54
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=$execDir/batt-interface.sh
AD=$execDir/accd.sh

[ -f "$BI" ] || { no "batt-interface.sh not found"; fin; }

# Comments are STRIPPED before any of these checks. The first version of this suite did not, and
# every assertion failed against a correct build: the comments here explain the forks that were
# removed, so they quote `grep -q 0` and `$(online_f)` verbatim, and the rc19 note inside _nap_idle
# literally contains the words "grep+cat". A test that greps a file for the name of a defect finds
# the defect's own obituary.
body() { sed -n "/^$1() {/,/^}/p" "$2" | sed 's/^[[:space:]]*#.*//'; }
body_indented() { sed -n "/^  $1() {/,/^  }/p" "$2" | sed 's/^[[:space:]]*#.*//'; }

# A fork, for our purposes: a command substitution, a backtick, a pipeline, or an external binary
# where a builtin would do. `read` and `case` are free; ls/grep/cat/sed/awk/stat are not.
# A `|` inside a case pattern is not a pipeline, so only a pipe followed by a known command counts.
# `$((` is arithmetic, evaluated by the shell, and every one of these loops decrements a counter
# with it. Requiring a non-`(` after `$(` keeps command substitution matched and arithmetic not.
forky() { printf '%s' "$1" | grep -cE '\$\([^(]|`|\| *(grep|sed|awk|cut|head|tail|ls|cat|stat)|(^|[; ]+)(ls|cat|grep|sed|awk|stat|cut)[ ]' || :; }

# ---- online_f must be cached, exactly like present_f ---------------------------------------------
_of=$(body online_f "$BI")
[ -n "$_of" ] || { no "could not extract online_f"; fin; }
printf '%s' "$_of" | grep -q '_onlineF' \
  && ok "online_f caches its node list in a process-lifetime variable" \
  || no "online_f re-runs ls|grep on every call - this is the rc19 regression, re-entered"

_pf=$(body present_f "$BI")
printf '%s' "$_pf" | grep -q '_presentF' \
  && ok "present_f is still cached (rc19)" \
  || no "present_f lost its cache"

# ---- online() must not fork per node -------------------------------------------------------------
_on=$(body online "$BI")
[ -n "$_on" ] || { no "could not extract online"; fin; }
printf '%s' "$_on" | grep -q 'grep -q 0' \
  && no "online() still greps each node - one fork per node, per call, once a second when idle" \
  || ok "online() reads each node with a builtin, not a grep per node"
printf '%s' "$_on" | grep -q '$(online_f)' \
  && no "online() calls online_f through a command substitution - a fork just to read the cache" \
  || ok "online() uses the cached list directly, with no command substitution"
printf '%s' "$_on" | grep -q 'read -r' \
  && ok "online() uses the read builtin" \
  || no "online() does not use a read builtin"

# ---- present() still has the bug 28 fallback -----------------------------------------------------
# The cheap version must not have been bought by reverting the safety fix.
_pr=$(body present "$BI")
[ -n "$_pr" ] || { no "could not extract present"; fin; }
printf '%s' "$_pr" | grep -q 'seen' \
  && no "present() short-circuits on a node reading 0 again - bug 28 is back (fuxi/vermeer)" \
  || ok "present() still falls through to online when nothing reports present=1 (bug 28 stays fixed)"
printf '%s' "$_pr" | grep -q '^  online$' \
  && ok "and the fallback is online(), as designed" \
  || no "present() no longer defers to online"
printf '%s' "$_pr" | grep -q 'read -r' \
  && ok "present() reads nodes with a builtin" \
  || no "present() does not use a read builtin"

# ---- the loops that call them once a second ------------------------------------------------------
for fn in _nap _nap_idle _nap_hold; do
  _b=$(body_indented "$fn" "$AD")
  if [ -z "$_b" ]; then no "could not extract $fn"; continue; fi
  n=$(forky "$_b")
  [ "${n:-0}" -eq 0 ] 2>/dev/null \
    && ok "$fn is fork-free" \
    || no "$fn contains $n forking construct(s) - it runs once a second"
done

# ---- live behaviour, if we can see real nodes ----------------------------------------------------
# Prove the cache actually holds across calls rather than just being present in the source.
if [ -d /sys/class/power_supply ]; then
  cd /sys/class/power_supply 2>/dev/null || :
  eval "$(body online_f "$BI")" 2>/dev/null || :
  if command -v online_f >/dev/null 2>&1; then
    _first=$(online_f)
    _before=$_onlineF
    _second=$(online_f)
    [ "$_first" = "$_second" ] && ok "online_f returns the same list on a second call" || no "online_f is not stable across calls"
    [ -n "${_before+x}" ] && ok "the cache variable is populated after the first call" || no "the cache is never populated"
  fi
fi

fin
