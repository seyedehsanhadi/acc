#!/system/bin/sh
# t34 - the kernel tie-break must survive a fuel gauge too coarse to rule.
#
# idle_discharging arbitrates charge direction in three stages:
#   1. the current sign, through the cached per-device polarity _DPOL
#   2. COULOMB: charge_counter delta over a 3-90s window, |delta| >= 150 uAh overrides the sign
#   3. TIE-BREAK: still Discharging while the kernel says Charging -> Charging
#
# Stage 3 stands down when the coulomb block "already decided", and it tested that by asking whether
# _ccd was set. But _ccd was assigned the RAW delta unconditionally, including 0. A flat counter
# therefore set _ccd=0, which is not a verdict, and silently disabled the tie-break.
#
# On a gauge too coarse to move within the window the delta is ALWAYS 0, so stages 2 and 3 stood
# down together and an unchallenged current sign decided everything. If that sign is wrong the
# daemon believes Discharging with the cable in, is_charging is false, and EVERY limit is skipped:
# max_temp, pause_capacity, current and voltage caps all go blind at once.
#
# Device-proven on a Mi A3: charge_counter flat across 120s, _DPOL latched to the wrong sign,
# `acc -i` reporting Discharging while battery/status said Charging. Same signature as the sweet
# field report - Discharging at 41C against max_temp 40, charging never paused.
#
# Fix: _ccd is set ONLY when the counter actually ruled. Pure unit test, no device state touched.

ID=t34
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/batt-interface.sh
[ -f "$SRC" ] || { no "batt-interface.sh not found"; fin; }

# ---- source level --------------------------------------------------------------------------------
grep -q '_ccraw=$(( _cc - _ccp ))' "$SRC" \
  && ok "the raw delta is computed into its own variable" \
  || no "the raw delta is gone - _ccd may be assigned unconditionally again"

grep -q '_status=Charging; _ccd=$_ccraw' "$SRC" \
  && ok "_ccd is set only on a decisive positive delta" \
  || no "_ccd is not gated on the counter having ruled"

grep -q '_status=Discharging; _ccd=$_ccraw' "$SRC" \
  && ok "_ccd is set only on a decisive negative delta" \
  || no "_ccd is not gated on the counter having ruled"

grep -q '\[ -z "${_ccd-}" \]' "$SRC" \
  && ok "the tie-break still keys on _ccd being unset" \
  || no "the tie-break no longer stands down when the counter ruled"

# ---- behavioural ---------------------------------------------------------------------------------
# Reproduce the decision chain. $1 raw counter delta, $2 sign verdict, $3 kernel status.
verdict() {
  _raw=$1; _status=$2; _kstatus=$3; _ccd=
  if   [ "$_raw" -ge 150 ]; then _status=Charging;    _ccd=$_raw
  elif [ "$_raw" -le -150 ]; then _status=Discharging; _ccd=$_raw
  fi
  if [ "$_status" = Discharging ] && [ "$_kstatus" = Charging ] && [ -z "${_ccd-}" ]; then
    _status=Charging
  fi
  echo "$_status"
}

# THE BUG: flat counter, wrong sign, kernel knows better.
[ "$(verdict 0 Discharging Charging)" = Charging ] \
  && ok "flat counter + wrong sign + kernel Charging -> Charging (the A3/sweet case)" \
  || no "flat counter still leaves the wrong sign unchallenged - every limit stays blind"

[ "$(verdict 0 Charging Charging)" = Charging ] \
  && ok "flat counter with an agreeing sign is undisturbed" || no "an agreeing verdict was changed"

# The counter must still WIN when it genuinely rules, in both directions.
[ "$(verdict 5000 Discharging Charging)" = Charging ] \
  && ok "a rising counter rules over a Discharging sign" || no "the counter lost to the sign"
[ "$(verdict -5000 Charging Discharging)" = Discharging ] \
  && ok "a falling counter rules over a Charging sign" || no "the counter lost to the sign"

# And the tie-break must NOT fire when the counter proved the pack is draining, even if the kernel
# claims Charging. This is the case the -z guard exists for: a lying status node.
[ "$(verdict -5000 Charging Charging)" = Discharging ] \
  && ok "a counter-proven drain is not overridden by a kernel claiming Charging" \
  || no "the tie-break overrode a decisive counter - the lying-status protection is gone"

# Boundaries: 150 rules, 149 does not.
[ "$(verdict 150 Discharging Discharging)" = Charging ] \
  && ok "exactly +150 uAh rules" || no "the +150 boundary does not rule"
[ "$(verdict 149 Discharging Charging)" = Charging ] \
  && ok "+149 does not rule, so the tie-break gets its turn" || no "+149 wrongly counted as a verdict"
[ "$(verdict -149 Discharging Charging)" = Charging ] \
  && ok "-149 does not rule, so the tie-break gets its turn" || no "-149 wrongly counted as a verdict"

# One-way only: never Charging -> Discharging.
[ "$(verdict 0 Charging Discharging)" = Charging ] \
  && ok "the tie-break never flips Charging to Discharging" || no "the tie-break went the wrong way"

fin
