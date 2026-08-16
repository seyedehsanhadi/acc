#!/system/bin/sh
# t83 - `acc -t` must put every switch back, on every exit path.
#
# THE FIELD FAULT, on a Mi A3 (laurus). Hours after an `acc -t` run, the phone was plugged in and
# would not charge at all:
#     pmi632_charger: battery over-voltage vbat_fg = 3905196uV, fv = 3600000uV
# battery/voltage_max was sitting at 3600000 against a pack at 3.9V, so the charger declared
# over-voltage and refused. acc -t had tested three voltage switches on that phone -
#     battery/voltage_max 4400000 3600mV | bms/voltage_max ... | main/voltage_max ...
# - and left one at its OFF value. Writing 4400000 back restored charging instantly (2.27A).
#
# WHY NOTHING RECOVERED IT. The daemon never set that node, so the daemon never restores it. A
# current switch left off makes charging slow; a VOLTAGE switch left off stops it dead, silently,
# and survives reboots because it is re-applied from nothing - the node simply stays where acc -t
# put it until something writes it back.
#
# THE HOLE. test_charging_switch_ restores with `flip_sw on` on the normal path, but the blacklisted
# branch returns before reaching it:
#     ${blacklisted:-false} && { print_blacklisted; return 10; }
# Any early return between `flip_sw off` and `flip_sw on` leaves the phone in the off state.
#
# This test walks the function and requires that no return can be reached from the OFF write without
# a restore in between.
ID=t83
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AS=$execDir/acc.sh
[ -f "$AS" ] || { no "acc.sh not found"; fin; }

_fn=$(sed -n '/^test_charging_switch_() {/,/^}/p' "$AS" | sed 's/^[[:space:]]*#.*//')
[ -n "$_fn" ] || { no "could not extract test_charging_switch_()"; fin; }

# ---- 1: the off write exists and is the anchor ---------------------------------------------------
_off=$(printf '%s' "$_fn" | grep -n 'flip_sw off' | head -1 | cut -d: -f1)
[ -n "$_off" ] && ok "the switch is written OFF at line $_off of the function" \
               || { no "no 'flip_sw off' in the function"; fin; }

# ---- 2: every return after that must be preceded by a restore -------------------------------------
# Walk forward from the off write. Track whether a restore has been seen since. A `return` reached
# with no restore in between is a path that strands the phone.
# FAIL CLOSED on the scratch write. If it fails, the read loop below never runs, _bad stays 0, and the
# suite reports "every return restores the switch first" having examined nothing. That shape - a PASS
# gated on a count from a file that may not exist - is why several suites reported green against builds
# carrying the fault. Honour $TMPDIR so a runner can place scratch somewhere writable.
_tmp=${TMPDIR:-/data/local/tmp}/.t83.$$
printf '%s\n' "$_fn" > $_tmp 2>/dev/null
if [ ! -s "$_tmp" ]; then
  no "scratch not writable at ${_tmp} - refusing to report a verdict from an empty walk"
  rm -f "$_tmp" 2>/dev/null
  fin
fi
# Redirect, not a pipe: a pipeline would run the loop in a subshell and the counters would not
# survive it.
_seen_on=0; _i=0; _bad=0; _last=
while IFS= read -r _l; do
  _i=$((_i+1))
  [ "$_i" -le "$_off" ] && continue
  case "$_l" in *flip_sw\ on*) _seen_on=1;; esac
  case "$_l" in
    *return*) [ "$_seen_on" = 0 ] && { _bad=$((_bad+1)); _last="$_l"; } ;;
  esac
done < $_tmp
rm -f $_tmp
if [ "${_bad:-0}" -eq 0 ]; then
  ok "every return after the OFF write restores the switch first"
else
  no "${_bad} return path(s) leave the switch OFF - e.g.[$(printf '%s' "${_last:-}" | sed 's/^ *//')] - a voltage switch left off stops charging entirely (the shipped fault)"
fi

# ---- 3: the blacklisted branch specifically -------------------------------------------------------
_bl=$(printf '%s' "$_fn" | grep -n 'blacklisted' | head -1 | cut -d: -f1)
if [ -n "$_bl" ]; then
  # Take the WHOLE block, from the guard to its closing brace, not a fixed window. Comments are
  # stripped above but leave blank lines behind, so a restore placed after an explanatory comment
  # sits well past any small offset - which made an earlier version of this check fail a fix that
  # was actually present.
  _blk=$(printf '%s' "$_fn" | sed -n "${_bl},/^  }/p")
  case "$_blk" in
    *flip_sw*on*) ok "the blacklisted branch restores before returning" ;;
    *) no "the blacklisted branch returns without flip_sw on - the OFF value stays applied, and a voltage switch left off stops charging entirely" ;;
  esac
else
  ok "(no blacklisted branch in this build)"
fi

# ---- 4: acc.sh parses ------------------------------------------------------------------------------
sh -n "$AS" 2>/dev/null && ok "acc.sh parses" || no "acc.sh does not parse"
fin
