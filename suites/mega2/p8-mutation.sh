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
  mkdir -p $MUT/suites/accd 2>/dev/null
  for _f in $execDir/*.sh $execDir/*.txt $execDir/module.prop; do
    [ -f "$_f" ] && cp -f "$_f" $MUT/ 2>/dev/null
  done
  for _f in $execDir/suites/accd/t*.sh; do
    [ -f "$_f" ] && cp -f "$_f" $MUT/suites/accd/ 2>/dev/null
  done
  [ -f $MUT/accd.sh ] && [ -f $MUT/misc-functions.sh ]
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
  for _t in $MUT/suites/accd/t*.sh; do
    [ -f "$_t" ] || continue
    # A suite that fails on the CLEAN copy cannot prove anything; skip it rather than credit it.
    ( cd $MUT && execDir=$execDir sh "$_t" >/dev/null 2>&1 ) || continue
    if ! ( cd $MUT && execDir=$MUT sh "$_t" >/dev/null 2>&1 ); then
      _by=$(basename "$_t"); break
    fi
  done

  if [ -n "${_by:-}" ]; then
    CAUGHT=$(( CAUGHT + 1 ))
    ok "caught: $1  (by ${_by})"
  else
    MISSED=$(( MISSED + 1 ))
    no "MISSED: $1 - NO suite fails with the defect present. This is a real coverage hole."
  fi
}

# ---- the catalogue --------------------------------------------------------------------------------
# Every one of these is a defect that actually shipped, or was one edit away from shipping.

# 1. The stuck-cut bug: re-gate the switch release on the cable being attached.
mutate "the switch release gated on present() again (acc -e strands an unplugged phone)" \
  misc-functions.sh \
  's#^      flip_sw on || cycle_switches on#      if present; then flip_sw on || cycle_switches on; fi#'

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
