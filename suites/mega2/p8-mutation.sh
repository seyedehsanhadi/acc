#!/system/bin/sh
# P8 - can this suite actually catch a regression?
#
# WHY THIS IS THE MOST IMPORTANT PHASE
#   Across a full campaign this suite has found eighteen defects in ITSELF and zero in the product.
#   That is consistent with two very different worlds: the product is genuinely clean, or the suite
#   cannot see. Every green tick so far is equally compatible with both, and no amount of re-running
#   it distinguishes them.
#
#   The only way to tell is to break the product ON PURPOSE, in the exact ways it has broken before,
#   and check the suite screams. A mutation that survives is a hole in coverage, stated as a number
#   rather than a feeling.
#
# HOW
#   Each mutation is applied to a THROWAWAY COPY of the source under /data/local/tmp. The installed
#   module is never touched, no daemon is restarted, nothing is written to a charge node. Every
#   mutation is a one-line edit that reintroduces a real, previously-shipped defect, and EVERY suite
#   is then run against it.
#
#   A suite that FAILS against the mutated copy = the defect was caught = PASS here.
#   A suite that PASSES against the mutated copy = the defect went undetected = FAIL here.
#
# NO HARDWARE. Nothing outside the scratch directory is modified.

hdr "P8 MUTATION - proving the suite has teeth"

MUT=$WORK/.mut
CAUGHT=0; MISSED=0; TOTAL=0

# A pristine copy of everything the suites read.
setup_mut() {
  rm -rf $MUT 2>/dev/null
  mkdir -p $MUT/suites/accd $MUT/suites/amps 2>/dev/null
  for _f in $execDir/*.sh $execDir/*.txt $execDir/module.prop; do
    [ -f "$_f" ] && cp -f "$_f" $MUT/ 2>/dev/null
  done
  for _f in $execDir/suites/accd/t*.sh; do
    [ -f "$_f" ] && cp -f "$_f" $MUT/suites/accd/ 2>/dev/null
  done
  # EVERYTHING under suites/ that is not a t*.sh, not just the suites themselves. t65 reads
  # $execDir/suites/xf.awk and calls fin (exit 1) when it is absent -- and because the eligibility
  # check below used to run against the REAL tree while the mutation ran against $MUT, that absence
  # looked exactly like a caught defect. t65 sorts before t66, so it broke the loop on EVERY mutation
  # and t66..t91 were never executed against a single one. Six mutations aimed squarely at them
  # (thermal hysteresis, acc-switch-scan) were all credited to a suite that only failed because a
  # file was missing.
  for _f in $execDir/suites/*; do
    [ -f "$_f" ] && cp -f "$_f" $MUT/suites/ 2>/dev/null
  done
  for _f in $execDir/suites/amps/*; do
    [ -f "$_f" ] && cp -f "$_f" $MUT/suites/amps/ 2>/dev/null
  done
  [ -f $MUT/accd.sh ] && [ -f $MUT/misc-functions.sh ]
}

# Which suites can prove anything at all against THIS staged tree?
#
# A suite is eligible only if it PASSES against the unmutated $MUT. Testing eligibility against
# $execDir instead is what let a staging gap masquerade as detection: the suite passed on the real
# tree, failed on $MUT for want of a file, and was recorded as having caught the defect.
#
# Computed once; every mutation reuses it.
ELIGIBLE=$MUT.eligible
build_eligible() {
  : > $ELIGIBLE
  for _t in $MUT/suites/accd/t*.sh; do
    [ -f "$_t" ] || continue
    ( cd $MUT && execDir=$MUT TMPDIR=${TMPDIR:-/data/local/tmp} sh "$_t" >/dev/null 2>&1 )       && echo "$_t" >> $ELIGIBLE
  done
  _ec=$(grep -c . $ELIGIBLE 2>/dev/null) || _ec=0
  _tc=0; for _t in $MUT/suites/accd/t*.sh; do [ -f "$_t" ] && _tc=$((_tc+1)); done
  note "eligible detectors: ${_ec}/${_tc} (a suite that cannot pass on a CLEAN staged tree cannot prove a mutation)"
  [ "${_ec:-0}" -gt 0 ]
}

# $1 label, $2 file to mutate, $3 sed program
#
# EVERY suite is run against the mutation, not one nominated suite.
#
# The first version named a single suite per defect and reported a miss when THAT suite passed. Two of
# seven came back as coverage holes on the first run and neither was: removing write()'s
# read-before-write is asserted by t59, not by t55 (which is about the batt-interface cache), and the
# present() gate is checked in more than one place. Pinning a defect to a guessed suite measures my
# guess, not the coverage. What matters is whether ANYTHING catches it.
mutate() {
  TOTAL=$(( TOTAL + 1 ))
  setup_mut || { no "could not stage a scratch copy for: $1"; return; }

  sed -i "$3" "$MUT/$2" 2>/dev/null || { no "$1: could not apply the mutation"; return; }
  if cmp -s "$MUT/$2" "$execDir/$2" 2>/dev/null; then
    no "$1: the mutation did not change $2 - the pattern no longer matches, so this is untested"
    return
  fi

  _by=
  while read -r _t; do
    [ -f "$_t" ] || continue
    if ! ( cd $MUT && execDir=$MUT TMPDIR=${TMPDIR:-/data/local/tmp} sh "$_t" >/dev/null 2>&1 ); then
      _by=$(basename "$_t"); break
    fi
  done < $ELIGIBLE

  if [ -n "${_by:-}" ]; then
    CAUGHT=$(( CAUGHT + 1 ))
    ok "caught: $1  (by ${_by})"
  else
    MISSED=$(( MISSED + 1 ))
    no "MISSED: $1 - NO suite fails with the defect present. This is a real coverage hole."
  fi
}

# ---- eligibility, computed once against a clean staged tree ----------------------------------------
setup_mut && build_eligible || no "could not establish an eligible detector set - every result below is unattributable"

# ---- the catalogue --------------------------------------------------------------------------------
# Every one of these is a defect that actually shipped, or was one edit away from shipping.

# 1. The stuck-cut bug: re-gate the switch release on the cable being attached.
mutate "the switch release gated on present() again (acc -e strands an unplugged phone)" \
  misc-functions.sh \
  's#^      flip_sw on ||.*#      if present; then flip_sw on || cycle_switches on; fi#'

# 2. Remove the per-plug contract latch, so a sagging supply reads as "no contract".
mutate "contract latch removed from the re-kick guard (a load sag permits a contract-killing re-kick)" \
  misc-functions.sh \
  's|hvcontract|hvcontract_DISABLED|g'

# 3. Drop write()'s read-before-write, restoring the fork storm and the Tensor state-machine churn.
mutate "write() idempotency removed (every poke rewrites, re-triggering charger negotiation)" \
  misc-functions.sh \
  's|if \[ -n "$_cur" \] && \[ "$_cur" = "$_tgt" \]; then|if false; then|'

# 4. Break the native thermal hold back to clamping stop to start.
mutate "native thermal hold clamped to resume level (limit absent below the resume level)" \
  accd.sh \
  's|^      _tl=$(batt_cap 2>/dev/null)|      _tl=|'

# 5. Remove the physical present() gate that stops "charging while unplugged".
mutate "present() gate removed from the unplugged verdict" \
  batt-interface.sh \
  's|^present()|present_DISABLED()|'

# 6. Make the init log redirect unconditional again: an unwritable /data kills the daemon.
mutate "init log redirect made unconditional (unwritable /data aborts the daemon silently)" \
  accd.sh \
  's|^  if : > $dataDir/logs/init.log 2>/dev/null; then|  if true; then|'

# 7. Remove the temperature guard from the re-enable paths.
mutate "temperature guard removed from a re-enable path (charging resumes above max_temp)" \
  accd.sh \
  's#_temp_hold || enable_charging#enable_charging#g'

# 8. THE REPORTED DEFECT. Put the firmware-limit thermal hold back on max_temp at BOTH edges, so it
#    releases a tenth of a degree under the limit and the pack burst-charges at it. This is precisely
#    "still charges above set temperature", and if nothing fails here then nothing was ever proving
#    the fix.
mutate "native thermal hold released at max_temp again (still charges above set temperature)" \
  accd.sh \
  's|^    _rt=$(( ${temperature\[2\]:-40} \* 10 ))|    _rt=$(( ${temperature[1]:-50} * 10 ))|'

# 9. Reset the hold latch every pass. A latch cleared each loop is not a latch: it collapses to the
#    old single-threshold behaviour while still LOOKING like hysteresis in the source.
mutate "the thermal hold latch reset every charging pass (hysteresis present but inert)" \
  accd.sh \
  's|^    _mt=$(( ${temperature\[1\]:-50} \* 10 ))|    _ntHot=0\n    _mt=$(( ${temperature[1]:-50} * 10 ))|'

# 10. Put the toybox-broken flock guard back, which aborted every switch scan ever run on Android.
mutate "the switch scanner's flock guard restored (every scan aborts claiming one is running)" \
  acc-switch-scan.sh \
  's|^if ! mkdir "$_SCANLOCK" 2>/dev/null; then|if command -v flock >/dev/null 2>\&1 \&\& { exec 8>"$TMPDIR/.scan.lock"; flock -n 8; }; then :; fi\nif ! mkdir "$_SCANLOCK" 2>/dev/null; then|'

# 11. Un-detach the scanner's daemon hand-off. daemon_ctrl ends in `exec accd`, so without setsid the
#     daemon becomes a process in the dying script's session and the phone is left uncapped.
mutate "the scan's daemon restart un-detached (scan ends with no daemon, charging uncapped)" \
  acc-switch-scan.sh \
  's|    setsid "$ACCA" -D restart </dev/null >/dev/null 2>&1 \&|    "$ACCA" -D restart >/dev/null 2>\&1|'

# 12. Put restore_all_on's filter back into the per-candidate restore, so a current node written to 0
#     by write_off is never put back. The phone is left unable to draw current, and every candidate
#     tested after it is measured on a phone that cannot charge.
mutate "the scan's per-candidate restore skips current nodes (leaves them at 0, contaminates the rest of the run)" \
  acc-switch-scan.sh \
  's|^    \[ "$1" = "--" \] \&\& { shift 3; continue; }|    case "$1" in --\|*/current_max\|*/constant_charge_current*) shift 3; continue;; esac|'

# 13. Go back to a bare pgrep for the "is the daemon back" check, which matches pkill and
#     start-stop-daemon and so reports success against the process tearing the daemon down.
mutate "the daemon check back to a bare pgrep (reports 'restarted' with no daemon running)" \
  acc-switch-scan.sh \
  's|^      daemon_alive \&\& { up=1; break; }|      pgrep -f accd.sh >/dev/null 2>\&1 \&\& { up=1; break; }|'

rm -rf $MUT 2>/dev/null

# ---- the score -------------------------------------------------------------------------------------
echo ""
if [ "${TOTAL:-0}" -gt 0 ]; then
  _pct=$(( CAUGHT * 100 / TOTAL ))
  note "mutations planted: ${TOTAL}   caught: ${CAUGHT}   missed: ${MISSED}   detection: ${_pct}%"
  if [ "${MISSED:-0}" -eq 0 ]; then
    ok "every planted defect was detected - the suite can see a real regression, not just a clean run"
  else
    no "${MISSED} planted defect(s) went undetected - the suite would pass a build carrying them"
  fi
  baseline_record mutation_detection "$_pct"
else
  skip "the mutation catalogue (no suites available to mutate)"
fi
