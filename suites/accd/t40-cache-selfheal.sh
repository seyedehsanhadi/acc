#!/system/bin/sh
# t40 - a truncated battery-interface cache must be rebuilt, not sourced.
#
# The cache holds every fact ACC learns about a phone: which nodes are the fuel gauge, what unit the
# current is in, which sign means charging. The daemon and every CLI call source it.
#
# The daemon decided whether to rebuild it by testing -f, which an EMPTY file passes. So a
# zero-length cache left _INIT false, the daemon sourced nothing and ran on fail-safe defaults, and
# nothing ever put it back -- not a restart, only deleting the file or rebooting.
#
# There is a real path to that state: the cache is written with a truncating redirect, so a crash or
# a kill between the truncate and the write leaves it zero-length permanently.
#
# The consequence is not subtle. With battCapacity unset, batt_cap coerces to 100 (its fail-safe),
# _ge_pause_cap is then always true, and a daemon started in that state pauses charging for good.
#
# Found on both test phones simultaneously: acc -i returned nothing on either, while the
# already-running daemons kept working from memory and every health check looked fine.
#
# Pure unit test: the decision is reproduced against fake files. No daemon is started.

ID=t40
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/accd.sh
[ -f "$SRC" ] || { no "accd.sh not found"; fin; }

# ---- source level ----------------------------------------------------------------------------
grep -q '\-s $TMPDIR/.batt-interface.sh' "$SRC" \
  && ok "the rebuild test requires a non-empty cache" \
  || no "the rebuild test still passes on an empty cache"

grep -q "grep -q '\^battCapacity=' \$TMPDIR/.batt-interface.sh" "$SRC" \
  && ok "it also requires the cache to carry battCapacity" \
  || no "an incomplete cache would still be accepted"

_old=$(grep -c '^  \*) \[ -f \$TMPDIR/.batt-interface.sh \] || _INIT=true;;' "$SRC")
[ "${_old:-0}" -eq 0 ] \
  && ok "the bare -f test is gone" || no "the bare -f test is still there"

# ---- behavioural -------------------------------------------------------------------------------
T=$(mktemp -d 2>/dev/null || echo /data/local/tmp/t40.$$)
mkdir -p "$T"
C=$T/.batt-interface.sh

# reproduce the decision: 0 means "rebuild"
needs_init() {
  { [ -s "$C" ] && grep -q '^battCapacity=' "$C" 2>/dev/null; } && return 1 || return 0
}

rm -f "$C"
needs_init && ok "missing cache -> rebuild" || no "a missing cache was not rebuilt"

: > "$C"
needs_init && ok "EMPTY cache -> rebuild (the bug: -f accepted this)" \
           || no "an empty cache is still accepted - the daemon would run blind"

printf 'ampFactor_=1000000\nbatt=battery\n' > "$C"
needs_init && ok "cache without battCapacity -> rebuild (a half-written file)" \
           || no "a half-written cache was accepted"

printf 'ampFactor_=1000000\nbattCapacity=battery/capacity\nbattStatus=battery/status\n' > "$C"
needs_init && no "a complete cache was needlessly rebuilt" \
           || ok "a complete cache is used as-is"

# A cache carrying only a polarity line is still unusable: the nodes are what matter.
printf '_DPOL=+\n' > "$C"
needs_init && ok "a cache with only a polarity line -> rebuild" \
           || no "a cache with no node paths was accepted"

rm -rf "$T" 2>/dev/null
fin
