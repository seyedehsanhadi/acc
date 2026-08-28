#!/system/bin/sh
# t-verdict-honesty - AMPS must not tell you the wrong thing about which switch to lock.
#
# WHY THIS EXISTS. AMPS 7.2.4 carries 37 marked fix sites and shipped with 5 suites. An A/B that
# planted each pre-fix defect back and required a suite to fail found 13 caught and 23 undetected,
# identically on a Mi A3 and a Pixel 6a. This suite closes the six gaps where the consequence is the
# worst kind: the run completes, looks clean, and hands the user or AccA a WRONG ANSWER.
#
#   L499   a finalist adopted from ACC's own config printed "enforcement was measured ... CONFIRMED"
#          when lvl_enf was never set and no engage measurement existed.
#   L1953  classify_held returning NOT-HELD was filed under CUT -- a switch that demonstrably does
#          not stop charging recorded as one that does.
#   L2909  the ACC-defer SUGGEST truncated a GROUPED chargingSwitch to its first triplet. ACC ships
#          real grouped lines (the Pixel five-node current group, a three-triplet OnePlus sequence),
#          so this handed ACC a config naming one node out of five.
#   L2947  the verdict headline ranked CUT above an unverified BYPASS while RECOMMENDED, SUGGEST and
#          the artifact all named the bypass -- one report, two answers.
#   L3174  a line announced as an ACC-confirmed BYPASS shipped class=throttle to AccA.
#   L3409  a level node adopted only because ACC's config already named it was written as
#          conf=verified.
#
# NO HARDWARE. Every check is on the shipped source, and each one is paired with the exact mutation
# that reinstates the defect, so a future edit that undoes the fix fails here.

ID=t-verdict-honesty
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

# acc-compat.sh is NOT installed at that path - the module keeps it under acc-data/backup and the
# repo ships it in suites/. A single hardcoded default made three of these abort with
# "acc-compat.sh not found" on every installed phone, which reads as a product failure and is not.
# t-layer-crash already had a two-step fallback; give every suite the same search.
_amps_find(){
  for _ac in "${AMPS:-}" /data/adb/vr25/acc/acc-compat.sh              /data/adb/vr25/acc-data/backup/acc-compat.sh              /data/local/tmp/suites/acc-compat.sh /data/local/tmp/amps.sh; do
    [ -n "$_ac" ] && [ -f "$_ac" ] && { echo "$_ac"; return 0; }
  done
  return 1
}
AMPS=$(_amps_find)
[ -f "$AMPS" ] || { no "acc-compat.sh not found (set AMPS=)"; fin; }

# ---- L1953: NOT-HELD must never be filed as a working CUT --------------------------------------
# The mutation that reinstates it: s#k0" = NOT-HELD ]; then#k0" = NOT-HELD-NEVER ]; then#
grep -q '= NOT-HELD \]; then' "$AMPS" \
  && ok "NOT-HELD is tested for explicitly before a result is filed" \
  || no "nothing tests for NOT-HELD - a switch that does not stop charging can be recorded as a CUT"
sed -n '/= NOT-HELD \]; then/,/^        fi/p' "$AMPS" | grep -qiE 'restore|stop here|return' \
  && ok "  and a NOT-HELD result restores and stops rather than falling through to the CUT case" \
  || no "  NOT-HELD is detected but does not stop - route_stab's case will still file it under CUT"

# ---- L2947: the headline must agree with reco_pick ------------------------------------------------
# Pre-fix: `elif [ -n "$BYPASS" ]; then` came AFTER the CUT branch, so with both lists non-empty the
# headline described a CUT while RECOMMENDED/SUGGEST/artifact named the bypass.
_hb=$(grep -n '^elif \[ -n "$BYPASS" \]; then$' "$AMPS" | head -1 | cut -d: -f1)
_hc=$(grep -n '^elif \[ -n "$CUT" \]' "$AMPS" | head -1 | cut -d: -f1)
if [ -n "$_hb" ] && [ -n "$_hc" ]; then
  [ "$_hb" -lt "$_hc" ] 2>/dev/null \
    && ok "the headline tests BYPASS before CUT ($_hb < $_hc), matching reco_pick's ranking" \
    || no "the headline tests CUT at $_hc before BYPASS at $_hb - the report will contradict its own recommendation"
elif [ -n "$_hb" ]; then
  ok "the BYPASS headline branch is present and unguarded by an empty-CUT condition"
else
  no "could not find the BYPASS headline branch"
fi
# and it must not have been re-guarded on CUT being empty, which is the same bug wearing a hat
grep -q 'elif \[ -n "$BYPASS" \] && \[ -z "$CUT" \]' "$AMPS" \
  && no "the BYPASS headline is gated on CUT being empty - a phone with both goes back to announcing the CUT" \
  || ok "the BYPASS headline is not gated on CUT being empty"

# ---- L2909: a grouped chargingSwitch must reach SUGGEST whole ---------------------------------------
grep -q 'SUGGEST="$ACC_SW_NOW_FULL"' "$AMPS" \
  && ok "SUGGEST carries the FULL chargingSwitch line" \
  || no "SUGGEST no longer uses ACC_SW_NOW_FULL - a grouped line will be truncated to its first node"
grep -qE 'SUGGEST=.*cut -d" " -f1-3' "$AMPS" \
  && no "SUGGEST is cut to the first triplet - a Pixel five-node group becomes one node" \
  || ok "  and it is not cut down to three fields"

# ---- L3174: an announced BYPASS must not ship class=throttle -----------------------------------------
grep -q 'ACC_DEFER:-0}" = 1 \] && RECO_CLS=bypass' "$AMPS" \
  && ok "an ACC-deferred BYPASS sets RECO_CLS=bypass for the artifact" \
  || no "the ACC-defer path no longer sets RECO_CLS=bypass - AccA receives class=throttle for a line announced as BYPASS"

# ---- L3409: adopted-from-ACC is not the same as verified ----------------------------------------------
grep -q 'LVL_BY_ACC:-0}" = 1 \] && aconf=from-ACC-history' "$AMPS" \
  && ok "a level node adopted from ACC's config is labelled from-ACC-history, not verified" \
  || no "the LVL_BY_ACC adoption no longer sets aconf=from-ACC-history - it will ship as conf=verified"
# belt and braces: the artifact must never call an adopted node verified
sed -n '/LVL_BY_ACC:-0}" = 1 \]/,+3p' "$AMPS" | grep -q 'conf=verified' \
  && no "the adopted-level branch still writes conf=verified" \
  || ok "  and that branch does not write conf=verified"

# ---- L499: no CONFIRMED claim without a measurement ----------------------------------------------------
_fs=$(grep -n 'if \[ "${LVL_BY_ACC:-0}" = 1 \]; then' "$AMPS" | head -1 | cut -d: -f1)
[ -n "$_fs" ] \
  && ok "the finalist stress-test special-cases the ACC-adopted pick (line $_fs)" \
  || no "the finalist stress-test no longer distinguishes the ACC-adopted pick - it will claim CONFIRMED for an unmeasured level"
if [ -n "$_fs" ]; then
  sed -n "${_fs},$((_fs+8))p" "$AMPS" | grep -qiE 'not independently confirmed|no engage|not measured' \
    && ok "  and it says so plainly instead of claiming enforcement was measured" \
    || no "  the branch exists but does not state the pick was never measured"
fi

# ---- the standing rule these all serve -------------------------------------------------------------------
# Every one of the six is the same failure: the run reports something it did not establish. Anything
# that prints CONFIRMED, verified or a recommendation has to be traceable to a measurement.
grep -qiE 'not independently confirmed' "$AMPS" \
  && ok "the source carries an explicit 'not independently confirmed' path" \
  || no "there is no way for AMPS to say a pick was not independently confirmed"

fin
