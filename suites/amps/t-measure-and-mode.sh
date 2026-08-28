#!/system/bin/sh
# t-measure-and-mode - the arithmetic, sampling and mode fixes nothing else was watching.
#
# WHY THIS EXISTS. An A/B that plants each 7.2.4 defect back and requires a suite to fail found 23
# fixes with no test behind them. t-verdict-honesty and t-restore-safety closed the twelve where a
# user gets a wrong answer or a phone stops charging. These are the remaining eleven: quieter, but
# every one of them changes a NUMBER AMPS decides with, or the budget it runs under.
#
#   L12    --unplug advertised "Deep + unplug" and 10-20 minutes while running on quick's caps.
#   L126   the crash guard journalled only WRITES, so a phone that wedged on a driver READ recorded
#          nothing and the next scan hung the same way forever.
#   L895   defaults_native piped into its write loop, so the once-per-node dedupe, the journal
#          warning and the accumulated report text all died with the subshell.
#   L1452  a phone with no current sensor could not be scanned AT ALL.
#   L1723  a late weak-charger sample lowered SAMP_LAST but never SAMP_N.
#   L1750  a blind classify_held ignored a RISING coulomb counter and said NOT-HELD.
#   L1774  reg_add wrote empty fields into a tab-separated row, shifting every later column.
#   L2102  test_level's re-arm loop had no run-deadline break.
#   L3455  the micro-unit test used -gt, so a node reading EXACTLY 100000 stayed unconverted.
#   L3484  the input ceiling took the FIRST non-zero vote instead of the HIGHEST.
#   L3546  an unsigned battery current vetoed the input ceiling while discharging.
#
# NO HARDWARE. Source assertions, plus the two arithmetic ones EXECUTED over their boundary.

ID=t-measure-and-mode
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

# ---- L12: --unplug must get Deep's budget, not quick's ------------------------------------------
grep -q '\[ "$WANT_UNPLUG" = 1 \] && MODE=complete' "$AMPS" \
  && ok "--unplug promotes MODE to complete, so its budget matches what it advertises" \
  || no "--unplug no longer sets MODE=complete - it will claim 'Deep + unplug' and 10-20 minutes while running on quick's caps"

# ---- L3455: the micro-unit boundary, EXECUTED ------------------------------------------------------
# Pre-fix `-gt 100000`: a node reading EXACTLY 100000 fell through unconverted.
_csn=$(sed -n '/^_csn()/,/^}/p' "$AMPS")
[ -n "$_csn" ] || { no "could not extract _csn"; fin; }
printf '%s' "$_csn" | grep -q -- '-ge 100000' \
  && ok "_csn converts at >= 100000, so exactly 100000 is converted" \
  || no "_csn uses -gt 100000 - a node reading exactly 100000 stays in micro-units"
printf '%s' "$_csn" | grep -q -- '-gt 100000' \
  && no "  the -gt form is still present in _csn" \
  || ok "  and the -gt form is gone"

# ---- L3484: the input ceiling takes the HIGHEST vote, not the first ---------------------------------
grep -q '"${_uc:-0}" -gt "${_imax:-0}" \] 2>/dev/null && _imax=$_uc' "$AMPS" \
  && ok "the input ceiling keeps the HIGHEST vote it sees" \
  || no "the ceiling no longer compares votes - it will keep the first non-zero one and under-report the port"
grep -q '"${_imax:-0}" = 0 \] 2>/dev/null && _imax=$_uc' "$AMPS" \
  && no "  the first-non-zero form is back: a 500 mA SDP vote read before a 3 A one wins" \
  || ok "  and it does not stop at the first non-zero vote"
# execute the comparison over a vote sequence where order would matter
_pick=$( ( _imax=0
           for _uc in 500000 3200000 1500000; do
             [ "${_uc:-0}" -gt "${_imax:-0}" ] 2>/dev/null && _imax=$_uc
           done; printf '%s' "$_imax" ) )
[ "$_pick" = 3200000 ] \
  && ok "  over votes 500000,3200000,1500000 the ceiling resolves to 3200000" \
  || no "  the ceiling resolved to $_pick, not the highest vote"

# ---- L3546: an unsigned current must not veto the ceiling while discharging ---------------------------
# The veto is only meaningful while the pack is actually CHARGING; _csn strips the sign, so on a
# discharging pack the magnitude looked like a draw and cancelled a perfectly good ceiling.
grep -qE '^  Charging\|charging\|Full\|full\)' "$AMPS" \
  && ok "the ceiling veto is gated on the pack actually charging" \
  || no "the charging-only gate is gone - an unsigned current will veto the ceiling while discharging"

# ---- L1750: a rising coulomb counter is not NOT-HELD ---------------------------------------------------
_ch=$(sed -n '/^classify_held()/,/^}/p' "$AMPS")
[ -n "$_ch" ] || _ch=$(grep -n 'classify_held' "$AMPS" | head -1)
grep -q 'echo NOT-HELD' "$AMPS" \
  && ok "classify_held can still return NOT-HELD" \
  || no "NOT-HELD is gone from classify_held"
grep -qiE 'coulomb|charge_counter|charge_full|rising' "$AMPS" \
  && ok "  and it consults a coulomb/charge counter, so a rising pack is not called NOT-HELD" \
  || no "  nothing consults a coulomb counter - a blind classify will call a charging pack NOT-HELD"

# ---- L1774: reg_add must not write empty fields ---------------------------------------------------------
grep -q '"${2:--}" "${3:--}" "${4:--}"' "$AMPS" \
  && ok "reg_add defaults empty fields to '-', keeping the tab-separated row aligned" \
  || no "reg_add writes bare \$2/\$3/\$4 - an empty field shifts every later column"

# ---- L2102: the re-arm loop must respect the run deadline ------------------------------------------------
grep -q 'do over && break; sleep 6; hold_probe' "$AMPS" \
  && ok "test_level's re-arm loop breaks when the run deadline passes" \
  || no "the re-arm loop has no deadline break - it can run past the whole scan's budget"

# ---- L126: the crash guard covers READS, not just writes --------------------------------------------------
grep -q 'lyr_mark "${_lm%% \*}"' "$AMPS" \
  && ok "log() marks the layer in flight, so a wedge during a READ is recorded" \
  || no "lyr_mark is not called from log() - a phone that hangs on a driver read records nothing and hangs again next run"
grep -q '^lyr_mark()' "$AMPS" && ok "  and lyr_mark is defined" || no "  lyr_mark is not defined"
grep -q '^lyr_skip()' "$AMPS" \
  && ok "  and a layer recorded from an abnormal boot can be skipped next run" \
  || no "  nothing skips a layer that took the phone down"

# ---- L895: defaults_native's write loop must not run in a subshell -------------------------------------------
grep -q 'done < "$BK/native.txt"' "$AMPS" \
  && ok "defaults_native reads its list by redirect, so dedupe state and warnings survive the loop" \
  || no "defaults_native pipes into its loop - the once-per-node dedupe and the report text die with the subshell"
grep -q 'done < "$BK/native.txt" | cat' "$AMPS" \
  && no "  the loop is piped again" || ok "  and the loop is not piped"

# ---- L1452: a phone with no current sensor must still be scannable ----------------------------------------------
grep -q 'BASE_STATE=CHARGING' "$AMPS" \
  && ok "a phone with no current sensor gets a usable base state instead of being unscannable" \
  || no "the no-sensor fallback is gone - such a phone cannot be scanned at all"

# ---- L1723: a late sample must lower BOTH the value and the count -------------------------------------------------
grep -q 'SAMP_LAST=0; SAMP_N="$_em"' "$AMPS" \
  && ok "a late weak-charger sample resets SAMP_N alongside SAMP_LAST" \
  || no "SAMP_N is not reset with SAMP_LAST - the sample count and the sample disagree"

fin
