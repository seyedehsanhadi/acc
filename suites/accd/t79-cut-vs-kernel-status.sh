#!/system/bin/sh
# t79 - when ACC ITSELF cut charging, the kernel's stale "Charging" must not veto the current sign.
#
# THE FIELD REPORT (Pixel 6 Pro, raven, rc22). The user's 90% limit was enforced by nothing. His
# config carried capacity=(5 0 89 90 false) but state.json read
# "native":{"stopLevel":100,"startLevel":99} with chargingSwitch="" - no limit anywhere. The native
# path was gone (charge_stop_level blacklisted after an unrelated kernel panic) and the switch path
# was empty because `acc -t` had REJECTED a switch that demonstrably works:
#
#     off (0, 0, 0)   -1012mA   Charging
#     ...
#     Switch doesn't work
#
# Current went +912mA -> -1012mA with polarity normal. The pack was visibly draining; the cut
# worked. AMPS graded the identical four nodes class=cut ok=1. Only acc -t disagreed.
#
# WHY. not_charging() decides on $_status, which idle_discharging() computes. On raven all three
# arbiters line up badly:
#   sign      -> Discharging  (correct: -1012mA, _DPOL=-)
#   coulomb   -> abstains     (state.json "ccDir":"unknown"; charge_counter too coarse to rule)
#   kernel    -> Charging     (this SoC does not update battery/status when the input is cut)
# and the rc21 tie-break then promotes Discharging to Charging because the counter could not rule.
# ACC concludes charging never stopped, so its own working switch is graded broken.
#
# THE TIE-BREAK IS NOT WRONG, ITS PRECONDITION IS. It exists for the sweet (Redmi Note 10 Pro),
# where current reads NEGATIVE while genuinely charging: the sign says Discharging, every limit
# goes blind, and the pack cooks at 41C against max_temp 40. There the kernel is an INDEPENDENT
# witness and deserves to win. When ACC has just commanded the cut itself, the kernel is not
# independent - it is reporting a state ACC deliberately ended - so its vote is stale by
# construction. Gating on that restores the tie-break's own premise rather than weakening it.
#
# The dangerous direction is unchanged. Believing "discharging" while the pack fills is what blinds
# the limits; this test pins that case (case B) as hard as the bug case.
#
# NO HARDWARE. idle_discharging is extracted and executed against stubbed sensors.

ID=t79
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=$execDir/batt-interface.sh
[ -f "$BI" ] || { no "batt-interface.sh not found at $BI"; fin; }

_FN=$(sed -n '/^idle_discharging() {/,/^}/p' "$BI")
[ -n "$_FN" ] || { no "could not extract idle_discharging()"; fin; }

# Run idle_discharging with every sensor pinned. Echoes the verdict it lands on.
#   $1 _DPOL   $2 curNow   $3 kernel status   $4 present rc (0=cable in)
#   $5 switch ("off" = ACC commanded this cut, "" = not an ACC cut)
#   $6 chDisabledByAcc
_run(){
  ( eval "$_FN"
    cc_now(){ echo 0; }                 # coulomb abstains, as on raven (ccDir unknown)
    eval "present(){ return $4; }"
    _DPOL=$1
    curNow=$2
    curThen=null
    idleThreshold=10000
    _kstatus=$3
    switch=$5
    chDisabledByAcc=$6
    _status=
    TMPDIR=${TMPDIR:-/data/local/tmp}
    idle_discharging
    echo "$_status" ) 2>/dev/null
}

# ---- A: THE BUG. raven, ACC cut it, pack draining, kernel still says Charging ---------------------
# _DPOL=- means negative is discharging (raven reads +912mA while charging).
_a=$(_run - -1012000 Charging 0 off false)
[ "$_a" = Discharging ] \
  && ok "ACC's own cut is seen as stopped (verdict $_a) - acc -t can grade the switch" \
  || no "ACC cut charging, pack draining at -1012mA, and the verdict is $_a - a working switch is graded broken (the shipped bug)"

# ---- B: THE PROTECTION THAT MUST SURVIVE. sweet, nobody cut anything ------------------------------
# Sign says Discharging (wrong polarity), counter cannot rule, kernel says Charging, no ACC cut.
# The tie-break MUST still fire here or the limits go blind and the pack cooks.
_b=$(_run + 2410000 Charging 0 "" false)
[ "$_b" = Charging ] \
  && ok "with no ACC cut, the kernel still overrides a wrong sign (verdict $_b) - limits stay armed" \
  || no "the sweet protection regressed: verdict $_b, so max_temp and pause_capacity would go blind"

# ---- C: a cut that did NOT work must still read as charging ----------------------------------------
# ACC commanded off, but current still says charging. acc -t must keep reporting the switch broken.
_c=$(_run - 912187 Charging 0 off false)
[ "$_c" = Charging ] \
  && ok "a cut that did nothing still reads Charging - a broken switch is still graded broken" \
  || no "a failed cut reported $_c - ACC would accept a switch that does not stop charging"

# ---- D: the daemon's steady pause counts as an ACC cut too ------------------------------------------
# Same situation as A but reached through the daemon holding the switch, not through acc -t.
_d=$(_run - -1012000 Charging 0 "" true)
[ "$_d" = Discharging ] \
  && ok "the daemon's own held pause is seen as stopped (verdict $_d)" \
  || no "while the daemon holds its own pause the verdict is $_d - the resume watchdog cannot see its own cut"

# ---- E: the physical gate still has the last word ----------------------------------------------------
# No cable. Nothing above may leave Charging standing, ACC cut or not.
_e=$(_run + 2410000 Charging 1 "" false)
[ "$_e" = Discharging ] \
  && ok "unplugged still forces Discharging regardless of the kernel" \
  || no "unplugged verdict is $_e - the rc22 physical gate regressed"

# ---- F: idle is untouched -----------------------------------------------------------------------------
_f=$(_run - -500 Charging 0 off false)
[ "$_f" = Idle ] \
  && ok "a current under the idle threshold is still Idle" \
  || no "idle verdict changed to $_f"

# ---- G: the gate reads a signal that actually exists at the call site ---------------------------------
# $switch is not_charging()'s local, visible to idle_discharging by dynamic scope; chDisabledByAcc is
# the daemon's. If either name is wrong the gate silently never fires and A only passes by accident.
grep -q 'local switch=\${flip-}' "$BI" \
  && ok "not_charging still exports \$switch, so the acc -t path can be detected" \
  || no "not_charging no longer sets \$switch - the gate cannot see an acc -t cut"
grep -q 'chDisabledByAcc=true' $execDir/accd.sh $execDir/misc-functions.sh 2>/dev/null \
  && ok "chDisabledByAcc is still set when the daemon holds its own pause" \
  || no "chDisabledByAcc is no longer set - the gate cannot see a daemon pause"

fin
