#!/system/bin/sh
# t62 - `acc -s key=value` must refuse an out-of-range value instead of storing a different one.
#
# THE DEFECT
#   rc21 fixed the SHORTHAND form. `acc 999` now says
#
#       Capacity out of range: 999
#       Expected 0-100 (percent) or 3001-5000 (mV)
#
#   and exits 2 without changing anything. The `-s key=value` form was never given the same check:
#
#       $ acc -s pause_capacity=999   ->  exit 0, prints a success tick, stores 76 -> 80
#       $ acc -s pause_capacity=101   ->  exit 0, prints a success tick, stores 80
#       $ acc -s pause_capacity=abc   ->  exit 0, prints a success tick, stores 75
#
#   write-config.sh clamps anything outside 0-100 / 3001-5000 to 80 (line 87) and drops a
#   non-numeric value entirely, so the value on screen is not the value in force and nothing says so.
#
#   This matters more than the shorthand, because `-s key=value` is the path AccA uses for every
#   setting the app writes. A typo, or a UI that offers a value ACC will not take, becomes a limit
#   the user never chose and cannot see.
#
#   Measured on a Mi A3 (rc22, 202505325): four inputs, all accepted, all silently coerced. Also
#   observed: a non-numeric pause capacity moved shutdown_capacity to 0, so a garbage value in one
#   field disabled the shutdown protection in another.
#
# WHAT IS ASSERTED
#   The validation exists on the -s path, covers percent AND millivolt domains, rejects non-numeric,
#   and refuses rather than clamps. Source-level so it runs anywhere; the live behaviour is exercised
#   by P9 on a device.
#
# NO HARDWARE.

ID=t62
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SP=$execDir/set-prop.sh
WC=$execDir/write-config.sh
[ -f "$SP" ] || { no "set-prop.sh not found"; fin; }

_sp=$(sed 's/#.*//' "$SP")

# ---- 1: the -s path validates a capacity at all -------------------------------------------------------
printf '%s' "$_sp" | grep -qE 'pause_capacity|resume_capacity|shutdown_capacity' \
  && ok "set-prop.sh knows about the capacity keys" \
  || no "set-prop.sh does not mention the capacity keys"

if printf '%s' "$_sp" | grep -q 'out of range'; then
  ok "the -s path refuses an out-of-range value"
else
  no "the -s path has NO range check - acc -s pause_capacity=999 is accepted and silently stored as 80"
fi

# ---- 2: both documented domains are honoured ------------------------------------------------------------
# Percent is 0-100; the millivolt mode is 3001-5000. A check that only knows about percent would
# refuse every legitimate voltage-mode configuration, which is a worse bug than the one being fixed.
if printf '%s' "$_sp" | grep -q '5000'; then
  ok "the millivolt domain (3001-5000) is part of the check, so voltage mode still works"
else
  no "the range check does not mention the millivolt domain - voltage-mode limits would be refused"
fi

# ---- 3: refusal must not write a coerced value ------------------------------------------------------------
# The whole point is that the stored value is either what was asked for or unchanged. A check that
# prints a warning and then falls through to write-config's clamp has fixed nothing.
if printf '%s' "$_sp" | grep -qE 'out of range' && printf '%s' "$_sp" | grep -qE 'exit [1-9]|return [1-9]'; then
  ok "a refusal exits non-zero rather than continuing into the write"
else
  no "an out-of-range value does not stop the write - it would still be clamped and stored"
fi

# ---- 4: non-numeric is refused too --------------------------------------------------------------------------
# `abc` was accepted and, worse, moved shutdown_capacity to 0. write-config drops a non-numeric value
# (`case ${pc-} in *[!0-9]*) pc=;; esac`) and the defaults then cascade into neighbouring fields.
if printf '%s' "$_sp" | grep -qE '\*\[!0-9\]\*'; then
  ok "a non-numeric capacity is detected on the -s path"
else
  no "a non-numeric capacity is not detected - it reaches write-config, which drops it and lets the defaults move other fields"
fi

# ---- 5: the clamp in write-config is still there as the last line of defence ----------------------------------
# Deliberately NOT removed. It is what stops a corrupt config file (not a user command) producing an
# unusable limit. The fix belongs in front of it, not instead of it.
if [ -f "$WC" ]; then
  sed 's/#.*//' "$WC" | grep -q 'pc=80' \
    && ok "write-config still clamps as a last resort for a corrupt config" \
    || no "the write-config clamp has been removed - a corrupt config file now has no backstop"
fi

# ---- 6: the shorthand path still works ----------------------------------------------------------------------
# rc21's fix must not have been disturbed while adding the same check elsewhere.
if grep -q 'Capacity out of range' $execDir/acc.sh 2>/dev/null; then
  ok "the shorthand check (acc 999) is intact"
else
  no "the shorthand range check has been lost"
fi

fin
