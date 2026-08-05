#!/system/bin/sh
# t44 - a binary limit must hold even when a throttle has already stopped the charge.
#
# Both binary limits live inside `if is_charging`. That is right for the normal case: a pause is a
# response to current flowing. But a current or voltage cap tight enough to stop the charge makes the
# pack net-negative, is_charging goes false, and that whole branch - including both limits - is
# skipped. Reproduced on an A3 grid row: level 71 against pause 71, pack 34C against max_temp 32,
# both limits reached, switch left ON, because a 381 mA cap had starved the phone.
#
# Nothing is overcharged while it holds, because nothing is charging. The defect is that the hold
# depends on the throttle rather than on the limit: relax the cap and the pack charges above the
# limit until a later loop notices.
#
# The guard is deliberately additive rather than a re-gating of the charging branch. That branch also
# performs idle-mode avoidance, switch cycling and force_off, all written assuming current flows;
# running it dry would be a far larger change than the window it closes.

ID=t44
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/accd.sh
[ -f "$SRC" ] || { no "accd.sh not found"; fin; }

_g=$(sed -n '/O1: assert a binary limit/,/^        fi$/p' "$SRC")
[ -n "$_g" ] || { no "the O1 guard is not present"; fin; }

printf '%s' "$_g" | grep -q 'present 2>/dev/null' \
  && ok "gated on present -- a cable is physically attached" \
  || no "not gated on present; it could cut with no cable"

printf '%s' "$_g" | grep -qE '^\s*if online' \
  && no "gated on online -- an input-cut switch reads offline while still plugged" \
  || ok "not gated on online, which lies while the input is suspended"

printf '%s' "$_g" | grep -q 'chDisabledByAcc:-false' \
  && ok "skips when the switch is already held by ACC (no churn)" \
  || no "no already-held check; it would rewrite the node every loop"

printf '%s' "$_g" | grep -q 'mt_reached' && printf '%s' "$_g" | grep -q '_ge_pause_cap' \
  && ok "uses the same two limit terms as the charging branch, not a second opinion" \
  || no "the limit terms differ from the charging branch"

printf '%s' "$_g" | grep -q 'disable_charging' \
  && ok "asserts the pause through disable_charging, not a raw node write" \
  || no "it does not go through disable_charging"

printf '%s' "$_g" | grep -q '_wlog' \
  && ok "logs when it fires, so it is visible in a diagnostic bundle" \
  || no "fires silently"

# It must live in the NOT-charging branch: in the charging branch the existing block already handles
# this, and a duplicate assert there would fight it.
_ln=$(grep -n 'O1: assert a binary limit' "$SRC" | cut -d: -f1 | head -1)
_el=$(grep -n '^      else$' "$SRC" | cut -d: -f1 | head -1)
if [ -n "$_ln" ] && [ -n "$_el" ]; then
  [ "$_ln" -gt "$_el" ] \
    && ok "sits in the not-charging branch (line $_ln, after else at $_el)" \
    || no "sits in the charging branch, where the existing block already acts"
else
  no "could not locate the guard relative to the else branch"
fi

fin
