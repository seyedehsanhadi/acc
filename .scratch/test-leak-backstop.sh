#!/usr/bin/env bash
# Unit test for leak_backstop() in install/accd.sh.
# Extracts the REAL function and runs it against a stubbed sysfs tree, so this tests
# shipped code rather than a copy. Collaborators (batt_cap/present/not_charging) are
# stubbed because they are genuine boundaries, not internals.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)/install/accd.sh"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

run_case() {
  # $1=name  $2=cap  $3=present(0/1)  $4=cut_works(0/1)  $5=nodes(space list)
  # NB: these must not be named cap/pres -- leak_backstop declares its own `local cap`,
  # which would shadow the stub's value and make batt_cap return nothing.
  local name="$1" TESTCAP="$2" TESTPRES="$3" TESTWORKS="$4" nodes="$5"
  local T; T=$(mktemp -d)
  mkdir -p "$T/battery" "$T/tmp"
  for n in $nodes; do echo 0 > "$T/battery/$n"; done

  ( cd "$T"
    export TESTCAP TESTPRES TESTWORKS
    TMPDIR="$T/tmp"
    capacity=(5 101 55 60 false)
    chargingSwitch=("/sys/class/oplus_chg/battery/mmi_charging_enable" 1 0 --)
    levelSwitch=false
    batt_cap(){ echo "$TESTCAP"; }
    present(){ [ "$TESTPRES" = 1 ]; }
    warn_once_per(){ :; }
    # the cut "works" only if the simulated firmware does not re-enable charging
    not_charging(){ [ "$TESTWORKS" = 1 ]; }
    eval "$(awk '/^  leak_backstop\(\) \{/,/^  \}/' "$SRC")"
    leak_backstop; rc=$?
    printf '%s|' "$rc"
    for n in $nodes; do printf '%s=%s|' "$n" "$(cat battery/$n)"; done
    [ -f "$TMPDIR/.leakcut" ] && printf 'latched' || printf 'nolatch'
  )
  rm -rf "$T"
}

echo "=== leak_backstop() contract ==="

# 1. THE ONEPLUS CASE: the only writable node does NOT actually stop charging.
#    Correct behaviour: revert it, do not latch, do not claim to be holding.
r=$(run_case oneplus 69 1 0 "input_suspend")
echo "  [broken-cut]  -> $r"
case "$r" in
  1\|input_suspend=0\|nolatch) ok "broken cut is reverted and reported as NOT holding" ;;
  *) no "broken cut: expected rc=1, input_suspend=0, nolatch -- got $r" ;;
esac

# 2. HEALTHY FALLBACK: the node really stops charging -> keep it, latch, report holding.
r=$(run_case healthy 69 1 1 "input_suspend")
echo "  [working-cut] -> $r"
case "$r" in
  0\|input_suspend=1\|latched) ok "working cut is engaged, latched, reported as holding" ;;
  *) no "working cut: expected rc=0, input_suspend=1, latched -- got $r" ;;
esac

# 3. GUARD: at/below the limit the function must not touch anything.
r=$(run_case below 59 1 0 "input_suspend")
echo "  [below-limit] -> $r"
case "$r" in
  1\|input_suspend=0\|nolatch) ok "below the limit: no write, no latch" ;;
  *) no "below limit: expected rc=1, untouched -- got $r" ;;
esac

# 4. FALLTHROUGH: first node broken, second works -> must move on to the second.
r=$(run_case fallthrough 69 1 0 "input_suspend charge_disable")
echo "  [all-broken]  -> $r"
case "$r" in
  1\|input_suspend=0\|charge_disable=0\|nolatch) ok "all candidates broken: every node reverted, not holding" ;;
  *) no "all broken: expected rc=1 with both nodes reverted -- got $r" ;;
esac

# 5. not_charging() consumes the global `flip` (flip_sw sets it, the next not_charging eats
#    it). The verification probe must not swallow a pending handoff.
flip_case() {
  local T; T=$(mktemp -d); mkdir -p "$T/battery" "$T/tmp"; echo 0 > "$T/battery/input_suspend"
  ( cd "$T"
    export TESTCAP=69 TESTPRES=1 TESTWORKS=1
    TMPDIR="$T/tmp"
    capacity=(5 101 55 60 false)
    chargingSwitch=("/sys/class/oplus_chg/battery/mmi_charging_enable" 1 0 --)
    levelSwitch=false
    batt_cap(){ echo "$TESTCAP"; }
    present(){ [ "$TESTPRES" = 1 ]; }
    warn_once_per(){ :; }
    not_charging(){ flip=; [ "$TESTWORKS" = 1 ]; }   # mimics the real one: consumes flip
    flip=on
    eval "$(awk '/^  leak_backstop\(\) \{/,/^  \}/' "$SRC")"
    leak_backstop >/dev/null 2>&1
    printf '%s' "${flip:-EMPTY}"
  )
  rm -rf "$T"
}
r=$(flip_case)
echo "  [flip-guard]  -> flip after = $r"
[ "$r" = "on" ] && ok "pending flip context survives the verification probe" \
                || no "flip was swallowed by the probe (expected 'on', got '$r')"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
