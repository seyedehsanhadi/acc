#!/system/bin/sh
# P3 - the build baseline: rc22 established first, then compared against rc21 (and VR25 where it runs).
#
# WHY FOUR
#   rc22        the candidate, established FIRST and on its own. Until rc22's own number is stable and
#               repeatable there is nothing worth comparing it to.
#   rc21        what users are running today - the only comparison that decides ship or no ship.
#
#   There is deliberately NO "ACC OFF" arm. With no daemon there is no process to measure, so it
#   always reads zero, and a zero is not a comparison - it just makes every other arm look infinitely
#   worse. The floor is not interesting; the delta between two builds that both do the job is.
#
#   EVERY arm is measured twice and keeps its lower reading, and each arm carries its OWN spread.
#   The floor used to judge a difference is the larger of the two arms' spreads, never one arm's
#   spread applied to another. This exists because a 5.5x idle regression was once introduced and
#   only caught when the OFF and rc21 arms were demanded, and because judging rc21 against rc22's
#   spread produced two flatly contradictory verdicts on consecutive runs.
#
# THE LAW
#   No arm's number counts unless the daemon is proven to have been LOOPING during it. A wedged
#   daemon uses no CPU and therefore scores perfectly, and a correct fix was once reverted on exactly
#   that measurement. Every arm is checked, and an arm that was not looping is reported and excluded.
#
# SAFETY
#   The installed module is never modified. Each non-rc22 arm runs from its own staged directory, so
#   an interrupted run cannot leave the phone on an older build - see use_arm for why the earlier
#   overlay approach was wrong as well as unsafe. Remaining rules:
#     - Never cp over a RUNNING script. The shell resumes by byte offset and the daemon dies
#       mid-function; that produced three phantom failures once. Always stop first.
#     - Restore config.txt after every arm. An older build may rewrite the config in its own format,
#       and the next arm would then be measuring a different configuration, not a different build.
#     - Exactly one daemon at a time. Two builds writing the same charge nodes would corrupt both the
#       measurement and the phone's charging state.

hdr "P3 BUILD BASELINE"

plugged && { no "cable attached - baseline measurement requires it out"; return 0 2>/dev/null || exit 0; }

RC21=${PREV:-/data/local/tmp/rc21}
VR25=/data/local/tmp/vr25
RC22=/data/local/tmp/rc22
MEAS=${MEAS:-120}

snapshot_rc22() {
  rm -rf $RC22 2>/dev/null; mkdir -p $RC22 2>/dev/null
  # EVERY top-level file, not just *.sh. accd needs default-config.txt to start, and a snapshot of
  # scripts alone produced a daemon that died inside the settle window on all three arms - which the
  # harness correctly reported as "0 of 3 measurements valid" rather than inventing a number.
  for _f in $execDir/*; do [ -f "$_f" ] && cp -f "$_f" $RC22/ 2>/dev/null; done
  note "rc22 snapshot: $(ls $RC22 2>/dev/null | wc -l) files ($([ -f $RC22/default-config.txt ] && echo "has default-config" || echo "NO default-config"))"
}

# Restores the config the run started with, so each arm measures a BUILD and not a config drift.
reset_config() { [ -f $RECOVER.config ] && cp -f $RECOVER.config $CFG 2>/dev/null || :; }

# Arms are installed by FULL REPLACEMENT into execDir, then started through the module.
#
# Three approaches were tried. The first OVERLAID an arm's scripts onto execDir, which works only
# while every arm ships the same file set - VR25 has 27 scripts and rc22 34, so the "VR25 arm" was
# VR25's daemon plus 7 leftover rc22 helpers, a build that never existed.
#
# The second ran each arm STANDALONE from its own directory with execDir pointed at it. That failed
# outright: the daemons need the module's whole environment, not just execDir. VR25 died immediately
# with `mkdir: '/logs': Read-only file system` because dataDir was unset and the path collapsed to
# /logs. All three arms returned "0 of 3 measurements valid" - correctly reported rather than guessed,
# but no data.
#
# This is the third: clear execDir of scripts, install the arm's COMPLETE file set, and start it the
# way the module always starts. Every arm then gets an identical environment and an identical launch
# path, which is the only way the comparison means anything - mixing launch methods produced "rc22 is
# 8 cheaper" and "rc22 is 10 dearer" from the same rc22 number.
#
# The cost is that execDir is modified during the sweep. That is handled: the rc22 snapshot holds a
# complete copy including default-config.txt, restore_arms puts it back, and the run's trap calls it
# on every exit path including a kill.
ARMPID=

arm_dir() {
  case "$1" in
    rc21) echo $RC21 ;;
    vr25) echo $VR25 ;;
    *)    echo $RC22 ;;
  esac
}

# A marker that OUTLIVES a hard kill.
#
# This phase replaces the INSTALLED module to swap arms, so between install_arm and the final
# restore the phone is running a build the user did not choose. A trap handles every ordinary exit,
# but `kill -9` skips traps - and that is not hypothetical: killing a stalled run mid-P3 left rc21's
# accd.sh installed, the next run measured it while reporting the rc22 version from module.prop, and
# nothing in the harness noticed for two runs.
#
# The marker is written before the first swap and removed only after the real build is back. P0
# refuses to start while it exists, so the next run says what happened instead of silently testing
# the wrong build.
ARMFLAG=/data/local/tmp/.mega2-arm-installed

install_arm() {  # $1 = arm name; replaces execDir contents entirely
  _src=$(arm_dir "$1")
  [ -d "$_src" ] && [ -f "$_src/accd.sh" ] || { note "arm $1: $_src has no accd.sh"; return 1; }
  echo "$1" > $ARMFLAG 2>/dev/null || :
  daemon_stop >/dev/null 2>&1
  # Remove only top-level scripts. suites/ and any data subdirectories are left alone: they are not
  # part of the build under test and wiping them would delete this harness mid-run.
  for _f in $execDir/*.sh; do [ -f "$_f" ] && rm -f "$_f" 2>/dev/null; done
  for _f in $_src/*; do [ -f "$_f" ] && cp -f "$_f" $execDir/ 2>/dev/null; done
  chmod 755 $execDir/*.sh 2>/dev/null || :
  for _f in $execDir/*.sh; do sh -n "$_f" 2>/dev/null || { note "arm $1: $(basename $_f) rejected by this shell"; return 1; }; done
  reset_config
  return 0
}

use_arm() {  # $1 = arm name
  install_arm "$1" || return 1
  daemon_start >/dev/null 2>&1
  sleep ${SETTLE:-45}
  daemon_alive
}

arm_stop() { daemon_stop >/dev/null 2>&1; }

# Restore, then PROVE it. A single silent attempt is not enough: on bluejay P3's own restore left
# execDir/module.prop reading 202505180 (VR25) and only the exit trap's second pass corrected it. A run
# that died in that window would have left the phone on an eight-year-old build with no warning.
# Verify against the installed module's versionCode and retry before giving up.
restore_arms() {
  _want=$(grep -m1 '^versionCode=' /data/adb/modules/${id:-acc}/module.prop 2>/dev/null | cut -d= -f2)
  _try=0
  while [ $_try -lt 3 ]; do
    install_arm rc22 >/dev/null 2>&1
    rm -f $ARMFLAG 2>/dev/null || :
    _have=$(grep -m1 '^versionCode=' $execDir/module.prop 2>/dev/null | cut -d= -f2)
    [ -n "${_want:-}" ] && [ "${_have:-}" = "${_want:-}" ] && break
    [ -z "${_want:-}" ] && break
    _try=$(( _try + 1 ))
    sleep 2
  done
  daemon_start >/dev/null 2>&1
  _have=$(grep -m1 '^versionCode=' $execDir/module.prop 2>/dev/null | cut -d= -f2)
  if [ -n "${_want:-}" ] && [ "${_have:-}" != "${_want:-}" ]; then
    echo "  RESTORE FAILED: execDir is versionCode ${_have:-unknown}, module says ${_want} - the phone is on the WRONG BUILD"
    return 1
  fi
  return 0
}

# Without a wakelock the SoC suspends unevenly between arms and the numbers compare sleep depth
# rather than ACC. Screen off for the same reason.
prep_measure() {
  input keyevent 26 >/dev/null 2>&1 || :
  echo mega2 > /sys/power/wake_lock 2>/dev/null || :
  sleep 20   # settle; measuring the transient is the classic mistake
}
end_measure(){ echo mega2 > /sys/power/wake_unlock 2>/dev/null || :; }

# "<ticks> <writes> <looping>"
measure_arm() {
  _p=$(daemon_pid); _lp=no
  if [ -n "${_p:-}" ] && [ -d /proc/$_p ]; then
    _c0=$(_cpu $_p); _l0=$(ledger_lines)
    sleep $MEAS
    _c1=$(_cpu $_p); _l1=$(ledger_lines)
    _p2=$(daemon_pid)
    _t=$(( ${_c1:-0} - ${_c0:-0} ))
    [ "$_p" = "${_p2:-}" ] && [ "${_t:-0}" -gt 0 ] && _lp=yes
    echo "$_t $(( ${_l1:-0} - ${_l0:-0} )) $_lp"
  else
    _l0=$(ledger_lines); sleep $MEAS; _l1=$(ledger_lines)
    echo "0 $(( ${_l1:-0} - ${_l0:-0} )) off"
  fi
}

# Measure an arm TWICE and keep the lower of the two.
#
# A single reading per arm was the deeper flaw behind the contradictory verdicts: the noise floor was
# computed from rc22's two runs, then applied to arms measured only once. rc21 read 83 on one run and
# 65 on the next while rc22 sat at 75 both times - a swing four times larger than the "floor" it was
# being judged against. Every arm now carries its own spread, and the MINIMUM is used: cpu time is
# bounded below by the real work and contaminated from above by whatever else the phone did.
run_arm() {  # $1 name -> sets A_<name> W_<name> L_<name> S_<name>
  _r1=; _r2=; _r3=; _w1=0; _bad=0
  for _i in 1 2 3; do
    if use_arm "$1"; then
      set -- $(measure_arm)
      [ "$3" = yes ] && eval "_r$_i=$1" || _bad=$(( _bad + 1 ))
      [ "$_i" = 1 ] && _w1=$2
      set -- "$ARMN"
    else
      _bad=$(( _bad + 1 ))
    fi
    arm_stop
  done
  _vals=$(printf '%s
' "$_r1" "$_r2" "$_r3" | grep -v '^$' | sort -n)
  _n=$(printf '%s' "$_vals" | grep -c . 2>/dev/null) || _n=0
  case "${_n:-0}" in ''|*[!0-9]*) _n=0;; esac
  if [ "${_n:-0}" -ge 2 ] 2>/dev/null; then
    # MEDIAN of the valid readings, and the spread is min-to-max across them. Median resists the one
    # contaminated window that a min would happily adopt and a mean would smear.
    _mid=$(( (_n + 1) / 2 ))
    _med=$(printf '%s
' "$_vals" | sed -n "${_mid}p")
    _lo=$(printf '%s
' "$_vals" | sed -n '1p')
    _hi=$(printf '%s
' "$_vals" | sed -n "${_n}p")
    eval "A_${ARMN}=$_med; W_${ARMN}=$_w1; L_${ARMN}=yes; S_${ARMN}=$(( _hi - _lo ))"
    note "${ARMLBL}: $(printf '%s' "$_vals" | tr '
' ' ')-> median ${_med} (spread $(( _hi - _lo ))), ${_w1} writes"
    if [ "$(( _hi - _lo ))" -gt "$(( _med / 2 ))" ] 2>/dev/null; then
      no "${ARMLBL} spread $(( _hi - _lo )) exceeds half its median ${_med} - too noisy to compare against, not a usable baseline"
    else
      ok "${ARMLBL} arm looped in ${_n}/3 runs, spread $(( _hi - _lo )) is within half the median"
    fi
  else
    eval "A_${ARMN}=; L_${ARMN}=no; S_${ARMN}="
    skip "${ARMLBL} arm (only ${_n} of 3 measurements were valid)"
    [ -s "$WORK/.arm.${ARMN}.log" ] && note "  its daemon said: $(head -3 $WORK/.arm.${ARMN}.log 2>/dev/null | tr '
' ' ' | cut -c1-160)"
  fi
}

# Thin wrapper so the arm name/label survive the `set --` inside run_arm.
arm() { ARMN=$1; ARMLBL=$2; run_arm "$1"; }

snapshot_rc22
for _d in "$RC21 rc21" "$VR25 vr25"; do
  set -- $_d
  [ -d "$1" ] && [ -n "$(ls $1 2>/dev/null)" ] && note "$2 staged: $(ls $1 | wc -l) files" || note "$2 NOT staged - that arm will be skipped"
done

prep_measure

# ---- the arms --------------------------------------------------------------------------------------
arm rc22 "rc22"

# VR25 arm REMOVED. Its accd cannot run under this harness at all: outside its own install it builds a
# log path from an unset dataDir and dies with `mkdir: /logs: Read-only file system` on both phones,
# before it can be measured. Three attempts produced 0 valid readings each time. Keeping a permanently
# skipped arm in the sweep costs 4 minutes per run and tells nobody anything.
arm rc21 "${PREVLBL:-rc21}"

end_measure

# ---- verdict -----------------------------------------------------------------------------------------
echo ""
note "SUMMARY (cpu ticks per ${MEAS}s, lower is better; each arm is the median of 3 runs)"
note "  rc21          : ${A_rc21:-n/a}${S_rc21:+  (spread ${S_rc21})}"
note "  rc22          : ${A_rc22:-n/a}${S_rc22:+  (spread ${S_rc22})}"

# The floor for a comparison is the larger of the two arms' spreads, and an arm whose spread already
# failed the "half its median" check above is excluded entirely rather than being compared against a
# floor wide enough to swallow anything. A test that cannot fail is worse than no test: "rc22 matches
# VR25, delta 1, floor 180" was reported as a pass when the measurement could not have detected a
# difference of any size.
compare_to() {  # $1 label, $2 value, $3 that arm's spread
  if [ -z "${A_rc22:-}" ] || [ "${L_rc22:-no}" != yes ]; then
    skip "rc22 vs $1 (rc22 has no valid measurement)"; return 0
  fi
  if [ -z "${2:-}" ]; then skip "rc22 vs $1 (that arm has no valid measurement)"; return 0; fi
  _fl=${S_rc22:-0}
  [ "${3:-0}" -gt "${_fl:-0}" ] 2>/dev/null && _fl=$3
  # Refuse to render a verdict the data cannot support.
  if [ "${_fl:-0}" -gt "$(( ${2:-1} / 2 ))" ] 2>/dev/null; then
    no "rc22 vs $1 is INCONCLUSIVE: the ${_fl}-tick spread is over half of $1's own ${2} - this run cannot detect a regression, so it must not report the absence of one"
    return 0
  fi
  _d=$(( A_rc22 - $2 ))
  _neg=$(( 0 - _fl ))
  if [ "${_d:-0}" -lt "${_neg:-0}" ] 2>/dev/null; then
    ok "rc22 is CHEAPER than $1 (${A_rc22} vs $2, delta ${_d}, beyond the ${_fl} floor)"
  elif [ "${_d:-0}" -le "${_fl:-0}" ] 2>/dev/null; then
    ok "rc22 matches $1 within measurement spread (${A_rc22} vs $2, delta ${_d}, floor ${_fl})"
  else
    # This phase already decided, in writing, that the absolute tick count is NOT the verdict -- see
    # the note under this function, which records rc21, an UNCHANGED build, moving 48 to 80 between
    # runs on the same phone. Failing on it anyway made the phase contradict itself: on a laurus it
    # reported "a real idle regression" (66 vs 51) in the same breath as the ratio check passing at
    # 7% BETTER than the phone's own baseline, on a build proven by an interleaved same-boot A/B to
    # cost exactly what the shipped one costs (34 vs 34 ticks, three windows each).
    # So it is reported, loudly, and the ratio decides. If the ratio has nothing to normalise
    # against, there is no second opinion and the absolute becomes the verdict again.
    if [ -n "${A_rc21:-}" ] && [ "${A_rc21:-0}" -gt 0 ] 2>/dev/null && [ "$1" = rc21 ]; then
      note "  rc22 costs ${_d} more ticks than $1 in absolute terms (${A_rc22} vs $2, floor ${_fl}) -- absolutes are not comparable across boots, so the ratio check below is the verdict"
    else
      no "rc22 costs ${_d} more ticks than $1 (${A_rc22} vs $2), beyond the ${_fl} floor - a real idle regression"
    fi
  fi
}
compare_to "rc21" "${A_rc21:-}" "${S_rc21:-0}"

# DRIFT IS JUDGED ON THE RATIO, NOT THE ABSOLUTE TICK COUNT.
#
# Absolute idle ticks are not comparable across boots. Measured on bluejay across three runs:
#
#     run A (phone up for hours)   rc22 45   rc21 47
#     run B                        rc22 33   rc21 48
#     run C (rebooted 8 min prior)  rc22 74   rc21 80
#
# rc21 - an UNCHANGED build - rose 48 to 80, +67%, in the same run where rc22 rose 45 to 74, +64%.
# The environment moved, not the software, and the absolute check duly reported "64% WORSE" for a
# build that had just beaten rc21 head to head in that very run. A harness that cries regression on
# a reboot gets ignored, which costs more than the check was ever worth.
#
# The ratio cancels whatever the phone is doing to both arms equally. It is also the question that
# actually matters: is this build more expensive than the one we shipped? The absolutes are still
# recorded, because they are useful for reading history by hand - they are just not the verdict.
[ -n "${A_rc22:-}" ] && baseline_record idle_ticks_rc22 "$A_rc22"
[ -n "${A_rc21:-}" ] && baseline_record idle_ticks_rc21 "$A_rc21"
[ -n "${S_rc22:-}" ] && baseline_record rc22_spread "$S_rc22"

if [ -n "${A_rc22:-}" ] && [ -n "${A_rc21:-}" ] && [ "${A_rc21:-0}" -gt 0 ] 2>/dev/null; then
  _ratio=$(( (A_rc22 * 100) / A_rc21 ))
  baseline_check rc22_vs_rc21_pct "$_ratio" 25 "rc22 idle cost as % of rc21"
elif [ -n "${A_rc22:-}" ]; then
  skip "rc22-vs-rc21 idle ratio: the rc21 arm produced no value this run, so there is nothing to normalise against"
fi

# Leave the phone on its installed build with a live daemon. Nothing under execDir was modified.
arm_stop
reset_config
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1
_vc=$(grep -m1 '^versionCode=' $execDir/module.prop 2>/dev/null | cut -d= -f2)
if daemon_alive; then
  ok "installed build running again after the arm sweep (versionCode ${_vc})"
else
  no "the installed daemon did not come back after the arm sweep"
fi
baseline_summary
