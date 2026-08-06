#!/system/bin/sh
# t46 - switch discovery must not slow or stop a healthy charge.
#
# Steady state was never the problem: with a switch locked, ACC charges FASTER than unmanaged,
# because it releases input ceilings the vendor left low (measured 247 mA on a Mi A3). Everything
# below lives in the DISCOVERY window instead - a fresh install, an AccA "Automatic" reset,
# .rediscover, an auto-lock blacklist, or a manual scan - which no steady-state measurement covers.
#
# Three separate defects, found by auditing every path that could reduce charging speed with nothing
# configured, and each one surviving an adversarial refutation pass.
#
#   1. A REJECTED candidate was left latched OFF for the rest of the session. cycle_switches' reject
#      arm wrote flip_sw off and continued, with no restore anywhere: not in the arm, not in
#      cycle_switches_off's second pass (whose `not_charging ||` guard skips exactly when the
#      abandoned node is the thing cutting), and not in enable_charging, which only touches the
#      ACCEPTED switch. The values are hostile - */current_max 0, */constant_charge_current 0,
#      charge_stop_level 5, siop_level 0 - so a probe on a healthy charge could leave the phone at
#      zero current while ACC reported everything normal.
#
#      The failure arm immediately below already had this right: keep a candidate cut only when at
#      or above the level the user asked to pause at, because below that it protects nothing. They
#      were separate copies of the same decision and only one had the check.
#
#   2. A scan's restore replayed a probe-time SNAPSHOT over ACC's own release. $SW carries two lines
#      for the same node - the deliberate HIGH release from ctrl-files.sh and a snapshot appended at
#      probe time - and awk '!seen[$0]++' keeps first-occurrence order, so the snapshot came second
#      and a top-to-bottom sweep made it the final value. On an A3 that ends a scan with
#      usb/current_max at 2.2A after ACC had negotiated 2.8A.
#
#   3. Discovery cut a healthy charge at ANY battery level. An empty chargingSwitch is the shipped
#      default, so a fresh install stopped a 40% charge to find a switch it would not need until 80%.
#
# Source-level. The behavioural halves are: a discovery run on a live charge (see the plan in
# .scratch), and fastcharge-audit.sh for the steady-state claim.

ID=t46
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
AD=$execDir/accd.sh
SC=$execDir/acc-switch-scan.sh
for f in "$MF" "$AD" "$SC"; do [ -f "$f" ] || { no "missing $f"; fin; }; done

# ---- 1. the reject arm hands the node back below the pause level --------------------------------
grep -q '^at_or_above_pause() {' "$MF" \
  && ok "at_or_above_pause exists as one shared decision" \
  || no "no shared helper - the two arms can drift apart again"

_n=$(grep -c 'at_or_above_pause || flip_sw on' "$MF")
[ "${_n:-0}" -eq 2 ] \
  && ok "both the reject and the failure arm use it ($_n call sites)" \
  || no "expected 2 call sites, found ${_n:-0} - one arm is not covered"

_rej=$(sed -n '/if \$_rej; then/,/continue/p' "$MF")
printf '%s' "$_rej" | grep -q 'at_or_above_pause' \
  && ok "the reject arm consults the pause level before latching" \
  || no "the reject arm still latches unconditionally"

printf '%s' "$_rej" | grep -qE '^\s*flip_sw off' \
  && no "the reject arm still has a bare 'flip_sw off' with no level check" \
  || ok "no unconditional cut left in the reject arm"

# Both domains must be handled, and an unreadable value must hand the node BACK, never latch it.
_h=$(sed -n '/^at_or_above_pause() {/,/^}/p' "$MF")
printf '%s' "$_h" | grep -q 'volt_now' && printf '%s' "$_h" | grep -q 'batt_cap' \
  && ok "handles both the millivolt and percent domains" \
  || no "one of the two pause-setting domains is unhandled"

printf '%s' "$_h" | grep -q "case \"\${capacity\[3\]-}\" in ''|\*\[!0-9\]\*) return 1" \
  && ok "an unparseable pause setting answers no, so the node is handed back" \
  || no "an unparseable pause setting does not fail toward handing the node back"

# ---- 2. the scan does not replay negotiation snapshots -------------------------------------------
_ra=$(sed -n '/^restore_all_on() {/,/^}/p' "$SC")
printf '%s' "$_ra" | grep -q 'current_max' \
  && ok "restore_all_on filters the negotiation-owned nodes" \
  || no "restore_all_on still sweeps every line, replaying probe-time snapshots"

for _pat in 'current_max' 'input_current' 'constant_charge_current' 'restrict_cur'; do
  printf '%s' "$_ra" | grep -q "$_pat" \
    && ok "  skips $_pat" \
    || no "  does NOT skip $_pat - a snapshot for it would be replayed"
done

# The binary switches must still be restored; that is what the sweep is for.
printf '%s' "$_ra" | grep -q 'restore_on' \
  && ok "binary switches are still restored (the sweep still does its job)" \
  || no "the sweep no longer restores anything"

# ---- 3. discovery waits until a cut is nearly needed ----------------------------------------------
grep -q 'chargingSwitch\[0\]-}" \] && probe_due; then' "$AD" \
  && ok "the discovery sweep is gated on probe_due" \
  || no "discovery still runs at any battery level"

_pd=$(sed -n '/^  probe_due() {/,/^  }/p' "$AD")
[ -n "$_pd" ] || { no "probe_due is not defined"; fin; }

printf '%s' "$_pd" | grep -q 'capacity\[3\]' \
  && ok "probe_due measures against the pause level" \
  || no "probe_due does not reference the pause level"

# Failing OPEN is the whole safety argument: a device whose values cannot be parsed must still be
# able to discover a switch, or ACC can never control it at all.
_open=0
printf '%s' "$_pd" | grep -q "in ''|\*\[!0-9\]\*) return 0" && _open=$((_open + 1))
printf '%s' "$_pd" | grep -q '\-le 100 \] 2>/dev/null || return 0' && _open=$((_open + 1))
printf '%s' "$_pd" | grep -q "case \"\${_c:-x}\" in ''|x|\*\[!0-9-\]\*) return 0" && _open=$((_open + 1))
[ "$_open" -eq 3 ] \
  && ok "fails OPEN on all three unparseable cases (empty, mV domain, unreadable gauge)" \
  || no "only $_open of 3 fail-open paths present - a device could lose discovery entirely"

fin
