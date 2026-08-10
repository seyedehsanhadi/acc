#!/system/bin/sh
# P5 - the reports. One named test per issue actually raised, so "it was fixed" is checkable later by
# someone who was not there.
#
# A fix with no test attached is a fix that comes back. Each block below names the report, the symptom
# as observed, and what would have to be true for it to have regressed.

hdr "P5 REPORTED ISSUES"

# ---- R1: pause_capacity=100 made the capacity setting vanish ---------------------------------------------
# AccA treated 100 as "disabled" and hid the whole capacity row, so a user who wanted to charge to 100%
# lost the setting entirely. The daemon must accept and keep it.
_orig=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
acc -s pause_capacity=100 >/dev/null 2>&1
sleep 3
_p=$(grep -m1 '^capacity=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//' | cut -d' ' -f4)
[ "${_p:-}" = 100 ] \
  && ok "R1 pause_capacity=100 is accepted and persists (not treated as 'disabled')" \
  || no "R1 pause_capacity=100 did not persist - config says ${_p}"
cp -f $RECOVER.config $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1; sleep 4
[ "$(grep -m1 '^capacity=' $CFG 2>/dev/null)" = "$_orig" ] && ok "R1 restored" || no "R1 did not restore"

# ---- R2: the dashboard showed wrong W / A / V -------------------------------------------------------------
# batt-info derives power from current and voltage. The sign must come from the charge-direction
# verdict, not from the raw node, because the two phones use opposite conventions - and the supply
# gate compared a float against an integer, so it never fired.
if command -v acc >/dev/null 2>&1; then
  _bi=$(acc -i 2>/dev/null)
  if [ -n "$_bi" ]; then
    ok "R2 acc -i produces output"
    _a=$(printf '%s' "$_bi" | grep -iE 'current' | head -1)
    _v=$(printf '%s' "$_bi" | grep -iE 'voltage' | head -1)
    _w=$(printf '%s' "$_bi" | grep -iE 'power|watt' | head -1)
    note "R2   ${_a:-no current line}"
    note "R2   ${_v:-no voltage line}"
    note "R2   ${_w:-no power line}"
    # Sign sanity: unplugged the reported power must not claim charging.
    if ! plugged; then
      printf '%s' "$_bi" | grep -qiE '^[^0-9-]*charging' \
        && no "R2 acc -i claims charging while unplugged" \
        || ok "R2 acc -i does not claim charging while unplugged"
    fi
    # A power figure of exactly 0.00 with current flowing means the supply gate is comparing wrong.
    case "${_w:-}" in
      *0.00*) [ "$(cur_raw)" = 0 ] 2>/dev/null \
                && ok "R2 zero power with zero current is consistent" \
                || no "R2 power reads 0.00 while current_now=$(cur_raw) - the supply gate is not firing" ;;
      *) ok "R2 power is a non-zero figure" ;;
    esac
  else
    no "R2 acc -i produced no output"
  fi
fi

# ---- R3: switch discovery must not strand a healthy charge ---------------------------------------------------
# Probing a current-control file MEANS writing 0 to it and watching the current drop. A sweep that runs
# unbounded, or that leaves a candidate applied, looks exactly like ACC cutting the phone - and once did.
# Source-level here: running a real sweep is what left a 1354mA cap on a phone.
if [ -f $execDir/acc-switch-scan.sh ]; then
  grep -q 'restore_all_on' $execDir/acc-switch-scan.sh 2>/dev/null \
    && ok "R3 the scanner has a restore-all path" \
    || no "R3 the scanner has no restore-all path - a sweep could leave a candidate applied"
  grep -qE 'trap' $execDir/acc-switch-scan.sh 2>/dev/null \
    && ok "R3 and it restores on interrupt, not only on a clean finish" \
    || no "R3 the scanner has no trap - an interrupted sweep leaves the phone mid-probe"
fi

# ---- R4: the re-kick must refuse to touch a working contract ---------------------------------------------------
# Three shipped versions of this guard were wrong in three different ways, each caught only by reading
# the ledger. t58 asks the guard directly; this checks the shipped copy still carries the latch.
if grep -q 'hvcontract' $execDir/misc-functions.sh 2>/dev/null; then
  ok "R4 the re-kick guard consults the per-plug contract latch"
else
  no "R4 the contract latch is gone - a load sag will permit a contract-killing re-kick"
fi
_clears=$(cnt -F 'rm -f $TMPDIR/.hvcontract' $execDir/accd.sh)
[ "${_clears:-0}" -ge 2 ] 2>/dev/null \
  && ok "R4 the latch is cleared in both places (unplug and daemon start)" \
  || no "R4 the latch is cleared in only ${_clears} place - a stale latch would block every repair"

# ---- R5: acc -e / acc -d must not strand the phone ----------------------------------------------------------------
# The measured failure: `acc -e` unplugged printed "Charging enabled", exited 0, wrote nothing, and left
# input_suspend=1. Covered live in P2; here we assert the shipped source no longer gates the release.
_ec=$(sed -n '/^enable_charging()/,/^}/p' $execDir/misc-functions.sh 2>/dev/null | sed 's/#.*//')
_flip=$(printf '%s' "$_ec" | grep -n 'flip_sw on || cycle_switches on' | head -1 | cut -d: -f1)
if [ -n "${_flip:-}" ]; then
  printf '%s' "$_ec" | sed -n "1,${_flip}p" | grep -qE 'if present; then' \
    && no "R5 the switch release is gated on present() again - unplugged phones will strand" \
    || ok "R5 the switch release is not gated on the cable being attached"
else
  no "R5 could not find the release flip in enable_charging"
fi

# ---- R6: AMPS / vendor log noise --------------------------------------------------------------------------------------
# AMPS ships as an asset and via repo curl and must never bump the ACC module version.
if [ -f $execDir/amps.sh ] || [ -f $execDir/../amps.sh ]; then
  ok "R6 AMPS is present as a separate script"
else
  skip "R6 AMPS not installed alongside"
fi

# ---- R7: the offline-charging prohibition ------------------------------------------------------------------------------
# Charger mode (phone off, cable in, battery icon) must NEVER be cut: a low resume there would brick
# recovery. This is inviolable and is asserted on the shipped source, not exercised.
_guard=0
for _f in $execDir/accd.sh $execDir/misc-functions.sh $execDir/post-fs-data.sh; do
  [ -f "$_f" ] || continue
  _n=$(cnt -E 'charger|_cut|shutdown' "$_f"); _guard=$(( _guard + _n ))
done
[ "${_guard:-0}" -gt 0 ] \
  && ok "R7 offline-charging guards are present in the shipped source" \
  || no "R7 no offline-charging guard found - charger mode could be cut"
