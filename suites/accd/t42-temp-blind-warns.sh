#!/system/bin/sh
# t42 - an unreadable temperature sensor has to be audible.
#
# temp_now() coerces an empty or garbage read to 250, meaning 25.0C. That coercion is deliberate and
# stays: without it, `[ $(temp_now) -lt N ]` becomes a syntax error on a blip, and accd runs under
# set -eu, so the daemon exits. Raising the fallback instead would be worse -- a dead sensor would
# fabricate a permanent thermal pause and strand the phone.
#
# What was wrong is that nothing said it had happened. While 250 is in force every max_temp test
# passes, the temperature limit is not enforced at all, and the phone looks completely healthy: the
# daemon loops, the log fills, `acc -i` answers, and it reports a plausible 25C. There is no way for
# a user or for us to tell that reading apart from a real one.
#
# That is the same shape as the cache bug: a fail-safe default indistinguishable from a real value.
# The value is unchanged here; the outage is now recorded in the flight log, which acc-diag already
# bundles, so it arrives with the next report instead of having to be guessed at.
#
# Logged on the transition only. temp_now runs every loop, so logging per-call would bury the flight
# log in a few hours on a phone whose sensor is permanently gone -- which is exactly the phone whose
# log we would most want to read.

ID=t42
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/accd.sh
[ -f "$SRC" ] || { no "accd.sh not found at $SRC"; fin; }

_fn=$(sed -n '/^  temp_now() {/,/^  }/p' "$SRC")
[ -n "$_fn" ] || { no "temp_now not found"; fin; }

# ---- the fallback itself must not have moved ----------------------------------------------------
printf '%s' "$_fn" | grep -q '_t=250' \
  && ok "the fallback is still the benign 250 (a high one would fabricate a pause)" \
  || no "the fallback value changed - a dead sensor may now strand the phone"

# ---- the outage is recorded ----------------------------------------------------------------------
printf '%s' "$_fn" | grep -q 'temp-sensor-unreadable' \
  && ok "an unreadable sensor is written to the flight log" \
  || no "an unreadable sensor is still silent"

printf '%s' "$_fn" | grep -q 'limit-not-enforced' \
  && ok "the log line says what it costs, not just that it happened" \
  || no "the log line does not say the limit stopped being enforced"

printf '%s' "$_fn" | grep -q 'temp-sensor-readable-again' \
  && ok "recovery is recorded too, so an outage has a start and an end" \
  || no "recovery is not recorded - an outage would look permanent"

# ---- once per outage, not once per loop ----------------------------------------------------------
printf '%s' "$_fn" | grep -q '\.temp-blind' \
  && ok "a marker makes it log on the transition only" \
  || no "no marker - temp_now runs every loop and would flood the log"

printf '%s' "$_fn" | grep -q 'if \[ ! -f \$TMPDIR/.temp-blind \]' \
  && ok "the outage line is guarded by the marker being absent" \
  || no "the outage line is not guarded"

printf '%s' "$_fn" | grep -q 'rm -f \$TMPDIR/.temp-blind' \
  && ok "the marker is cleared on recovery, so a second outage logs again" \
  || no "the marker is never cleared - only the first outage would ever log"

# ---- it must not be able to kill the daemon -------------------------------------------------------
printf '%s' "$_fn" | grep -q 'flight.log" 2>/dev/null || :' \
  && ok "every log write is guarded (set -eu, and logging must never affect charging)" \
  || no "an unguarded write in temp_now can abort the daemon under set -eu"

printf '%s' "$_fn" | grep -qE '\$\(.*flight_rec|flight_rec ' \
  && no "temp_now calls flight_rec - that path can lead back into temp_now" \
  || ok "it writes the log line directly, with no call that could recurse"

fin
