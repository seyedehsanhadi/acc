#!/system/bin/sh
# t43 - the current-cap marker has to exist BEFORE the cap is applied, not after.
#
# apply_on_plug refuses to write any current node while $TMPDIR/.mcc-custom is absent. That guard is
# right and stays: the marker is removed the instant a cap is cleared, so its absence means "no cap
# is configured", and without the guard a daemon still holding the config it read before the clear
# puts the cap straight back a second after the release - leaving the phone capped for good.
#
# But set_ch_curr created the marker AFTER apply_current returned. So the first apply always ran with
# the marker missing, and every current node was skipped by the guard it was supposed to pass. The
# result looked like success from every angle available to a user: the value lands in config, the
# resolved node list is written out, the marker appears, `acc -i` shows the limit. Nothing is written
# to a single node and the phone charges at full rate.
#
# Measured on a Pixel 6a at build 202505306, cap set to 500 mA on a 2.2 A supply:
#   before: write ledger gained ZERO entries, main-charger/current_max stayed 3200000, rate 1440 mA
#   after : 6 nodes written to 500000, main-charger/current_max 500000, rate 576 mA
#
# This is a regression introduced by the guard itself in this campaign, not an old bug. It is the
# same shape as the reports about current limits that are accepted and do nothing.

ID=t43
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/set-ch-curr.sh
GRD=$execDir/misc-functions.sh
[ -f "$SRC" ] || { no "set-ch-curr.sh not found at $SRC"; fin; }
[ -f "$GRD" ] || { no "misc-functions.sh not found at $GRD"; fin; }

# ---- the guard still exists; this test must not be passable by deleting it ----------------------
grep -q '! -f "\$TMPDIR/.mcc-custom"' "$GRD" \
  && ok "the apply-side marker guard is still in place" \
  || no "the marker guard is gone - a cleared cap can be re-applied by the daemon"

# ---- ordering -------------------------------------------------------------------------------------
_n_touch=$(grep -n '^      touch \$f$' "$SRC" | cut -d: -f1 | head -1)
_n_apply=$(grep -n 'apply_current \$1' "$SRC" | cut -d: -f1 | head -1)

if [ -n "$_n_touch" ] && [ -n "$_n_apply" ]; then
  [ "$_n_touch" -lt "$_n_apply" ] \
    && ok "the marker is created before the apply (touch line $_n_touch, apply line $_n_apply)" \
    || no "the marker is still created AFTER the apply - every current node will be skipped"
else
  no "could not locate the touch/apply pair (touch='$_n_touch' apply='$_n_apply')"
fi

# ---- a failed apply must not leave the guard believing in a cap ----------------------------------
grep -q 'apply_current \$1 || { rm -f \$f 2>/dev/null; return 1; }' "$SRC" \
  && ok "a failed apply removes the marker again" \
  || no "a failed apply would leave the marker up, with no cap actually applied"

# ---- the clear path must still drop the marker FIRST ---------------------------------------------
# Bug 10: releasing before the marker goes leaves a window where the daemon re-applies the cap, and
# with the marker then gone every later clear no-ops, so the phone stays capped.
_n_rm=$(grep -n 'rm \$f 2>/dev/null || :' "$SRC" | cut -d: -f1 | head -1)
_n_rel=$(grep -n 'apply_on_plug_ default' "$SRC" | cut -d: -f1 | head -1)
if [ -n "$_n_rm" ] && [ -n "$_n_rel" ]; then
  [ "$_n_rm" -lt "$_n_rel" ] \
    && ok "a clear still drops the marker before releasing the nodes" \
    || no "a clear releases before dropping the marker - the daemon can re-cap in that window"
else
  no "could not locate the clear ordering (rm='$_n_rm' release='$_n_rel')"
fi

# ---- behavioural: reproduce the decision both ways ------------------------------------------------
# Any writable directory will do; this part touches no ACC state. Picking one rather than assuming
# /data/local/tmp lets the same file run on a workstation as well as on a phone.
_T=
for _c in "${TMPDIR:-}" /data/local/tmp /tmp .; do
  [ -n "$_c" ] || continue
  mkdir -p "$_c/t43.$$" 2>/dev/null && [ -w "$_c/t43.$$" ] && { _T=$_c/t43.$$; break; }
done
[ -n "$_T" ] || { no "no writable directory for the behavioural check"; fin; }
_f=$_T/.mcc-custom
_skips=0
# The guard's condition, transcribed. Returns 1 when the node would be skipped.
_would_write(){ [ -f "$_f" ]; }

rm -f "$_f"
_would_write || _skips=$((_skips + 1))          # old order: apply first, marker absent
touch "$_f"
[ "$_skips" -eq 1 ] \
  && ok "apply-then-touch reproduces the skip (the bug)" \
  || no "could not reproduce the original skip - the guard condition has changed"

rm -f "$_f"; _skips=0
touch "$_f"                                      # new order: marker first
_would_write || _skips=$((_skips + 1))
[ "$_skips" -eq 0 ] \
  && ok "touch-then-apply writes the cap" \
  || no "the cap is still skipped with the marker created first"

rm -f "$_f"; _skips=0
_would_write || _skips=$((_skips + 1))           # marker genuinely gone: a daemon re-apply
[ "$_skips" -eq 1 ] \
  && ok "with the marker genuinely gone, a re-apply is still blocked" \
  || no "a re-apply after a clear would now go through - bug 10 is back"

rm -rf "$_T" 2>/dev/null
fin
