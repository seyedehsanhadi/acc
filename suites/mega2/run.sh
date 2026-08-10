#!/system/bin/sh
# mega2 - the super mega test.
#
#   sh run.sh checks        P0 P1 P2 P8 P9     (cable OUT, no battery measurement)
#   sh run.sh battery       P0 P3              (cable OUT, the ~20min idle-CPU arms)
#   sh run.sh unplugged     P0 P1 P2 P8 P9 P3  (cable OUT, both of the above)
#   sh run.sh plugged       P0 P4 P5 P9 P10 (cable IN)
#   sh run.sh deep          P0 P10 only, the three-arm enforcement+cost pass (cable IN)
#   sh run.sh all           everything, prompts between
#   sh run.sh static        P0 P1 only, no hardware interaction
#   sh run.sh volt          P0 P7 only, voltage attribution (cable IN)
#   sh run.sh soak          P0 P6 only, soak (cable IN)
#
# DESIGN RULES, each one paid for during this campaign:
#   1. The harness proves itself before it judges the product (P0 runs t57 first).
#   2. Every run restores config, switch AND daemon through a trap armed on all signals.
#   3. The crash-recovery file holds the WHOLE config, because a partial one lost a charging switch.
#   4. No arm's number is trusted unless the daemon is proven to have been LOOPING during it.
#   5. shutdown_temp is never written. Checked mechanically, not by reviewer discipline.
#   6. Nothing is left cut. Checked at the end of every phase that could cut.
#   7. Silent truncation is banned: anything skipped is reported as SKIP, never omitted.

SELF=$(cd "$(dirname "$0")" && pwd)
execDir=${execDir:-/data/adb/vr25/acc}
WORK=/data/local/tmp/mega2
mkdir -p $WORK 2>/dev/null

. $SELF/lib.sh
. $SELF/baseline.sh

MODE=${1:-unplugged}
START=$(date '+%H:%M:%S' 2>/dev/null)

case "$MODE" in
  plugged|deep|volt|soak) EXPECT_PLUGGED=yes ;;
  *) EXPECT_PLUGGED=no ;;
esac
export EXPECT_PLUGGED

# Armed BEFORE any phase runs. A run that dies without this leaves the config, the switch and the
# daemon wherever the failure happened - which has stranded a phone before.
arm_trap

# A phase file that exists but no mode dispatches is coverage that silently does not run. `unplugged`
# - the DEFAULT mode - fell out of the dispatch during an unrelated repair and every invocation of it
# exited 2 with "unknown mode"; `all` meanwhile omitted mutation, fault-recovery and the deep plugged
# phase while claiming to be everything. Both went unnoticed because nothing checked.
unreachable_phases() {
  _u=
  for _p in $SELF/p*.sh; do
    _b=$(basename "$_p")
    grep -q "run_phase $_b" "$0" || _u="$_u $_b"
  done
  printf '%s' "$_u"
}
_orphan=$(unreachable_phases)
[ -n "$_orphan" ] && echo "#  WARNING: phase files no mode runs:$_orphan"

run_phase() {
  # Once a phase sets MEGA2_ABORT the run stops dispatching. P0 uses it when the installed build
  # cannot be trusted; there is no point measuring anything after that, and continuing produces a
  # result line that looks like a verdict.
  [ "${MEGA2_ABORT:-no}" = yes ] && { skip "phase $1 (run aborted by preflight)"; return 0; }
  _f=$SELF/$1
  [ -f "$_f" ] || { skip "phase $1 not found"; return 0; }
  . "$_f"
}

echo "############################################################"
echo "#  ACC super mega test - mode: $MODE"
echo "#  device : $(getprop ro.product.device 2>/dev/null)"
echo "#  module : $(grep -m1 '^version=' $execDir/module.prop 2>/dev/null | cut -d= -f2)"
echo "#  started: $START"
echo "############################################################"

case "$MODE" in
  fast)
    # Everything that needs no cable and no long settle: preflight, the whole accd unit suite via
    # P1, and unplugged behaviour. Leaves out P8 (mutation, 7 defects x every suite) and P3 (build
    # staging plus idle-CPU settle windows), which are the only slow parts of the unplugged half.
    EXPECT_PLUGGED=no
    run_phase p0-preflight.sh
    run_phase p1-static.sh
    run_phase p2-unplugged.sh
    ;;
  checks)
    # Everything unplugged EXCEPT the battery/idle-CPU measurement. Correctness first: P3 takes ~20
    # minutes of pure waiting and tells you nothing about whether the code is right, so running it
    # before the checks are green just delays every answer that matters.
    EXPECT_PLUGGED=no
    run_phase p0-preflight.sh
    run_phase p1-static.sh
    run_phase p2-unplugged.sh
    run_phase p8-mutation.sh
    run_phase p9-fault-recovery.sh
    ;;
  battery)
    # The measurement on its own, for when the checks already passed.
    EXPECT_PLUGGED=no
    run_phase p0-preflight.sh
    run_phase p3-arms.sh
    ;;
  unplugged)
    EXPECT_PLUGGED=no
    run_phase p0-preflight.sh
    run_phase p1-static.sh
    run_phase p2-unplugged.sh
    run_phase p8-mutation.sh
    run_phase p9-fault-recovery.sh
    run_phase p3-arms.sh
    ;;
  plugged)
    EXPECT_PLUGGED=yes
    run_phase p0-preflight.sh
    run_phase p4-plugged.sh
    run_phase p5-reports.sh
    run_phase p9-fault-recovery.sh
    # P10 replaces P6+P7: arm C IS the soak, so the two phases no longer measure the same thing twice.
    [ "${SKIP_DEEP:-no}" = yes ] && skip "P10 plugged deep (SKIP_DEEP=yes)" || run_phase p10-plugged-deep.sh
    ;;
  deep)
    EXPECT_PLUGGED=yes
    run_phase p0-preflight.sh
    run_phase p10-plugged-deep.sh
    ;;
  all)
    run_phase p0-preflight.sh
    run_phase p1-static.sh
    run_phase p2-unplugged.sh
    run_phase p8-mutation.sh
    run_phase p9-fault-recovery.sh
    run_phase p3-arms.sh
    run_phase p4-plugged.sh
    run_phase p5-reports.sh
    # P6 and P7 are superseded by P10, which measures the same thing once instead of twice.
    run_phase p10-plugged-deep.sh
    ;;
  volt)
    EXPECT_PLUGGED=yes
    run_phase p0-preflight.sh
    run_phase p7-voltage-attribution.sh
    ;;
  soak)
    EXPECT_PLUGGED=yes
    run_phase p0-preflight.sh
    run_phase p6-soak.sh
    ;;
  *)
    echo "unknown mode: $MODE"
    exit 2
    ;;
esac

echo ""
echo "############################################################"
echo "#  RESULT: $P passed, $F failed, $SKIP skipped"
echo "#  mode $MODE   $START -> $(date '+%H:%M:%S' 2>/dev/null)"
if [ "$F" -gt 0 ]; then
  echo "#"
  echo "#  FAILURES:${FAILED_LIST}"
fi
echo "############################################################"

[ "$F" -eq 0 ]
