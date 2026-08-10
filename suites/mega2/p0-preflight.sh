#!/system/bin/sh
# P0 - preflight. Prove the harness itself is trustworthy BEFORE it judges the product.
#
# This phase exists because the harness has been the defective component more often than the product
# in this campaign. Two assertions could never fail; one shape emitted two values and killed a run
# while the summary still read "0 failed"; a suite ran without a trap and left ACC stopped on both
# phones; another left a 1354mA cap applied to a phone. A run that starts without checking these
# things is not a test, it is a way to generate confident wrong answers.

hdr "P0 PREFLIGHT"

# A previous run may have died while a different BUILD was installed. P3 swaps the real module out to
# measure its arms and puts it back at the end; a hard kill skips that restore, and every later run
# then measures rc21 or VR25 while module.prop still reports rc22. That happened, and two full runs
# were graded against the wrong build before anyone looked.
#
# Refuse rather than warn. A wrong-build run does not fail loudly - it produces plausible numbers.
if [ -f /data/local/tmp/.mega2-arm-installed ]; then
  # ABORT the run, do not merely report. A phase file is SOURCED, so `return 0` here ends this phase
  # and the runner cheerfully carries on into P1, P2 and P8 - which is what happened: the warning
  # scrolled past and 56 assertions ran anyway against a build nobody had verified. A guard that
  # warns and continues is worse than no guard, because the run still produces a green-looking tail.
  no "a previous run left the '$(cat /data/local/tmp/.mega2-arm-installed 2>/dev/null)' arm INSTALLED - reinstall the module zip before testing, because module.prop will report the right version over the wrong build"
  MEGA2_ABORT=yes
  return 0 2>/dev/null || exit 0
fi

# ---- 1: the shell we are actually on ---------------------------------------------------------------
# Only the constructs this file itself relies on. The full capability sweep - including BRE
# alternation - belongs to t57, which exempts its own probes from its scan. Duplicating that probe
# here made t57 report THIS file as a violation: the probe for a broken construct is indistinguishable
# from a use of it, which is exactly why t57 has a self-exemption and this does not.
printf 'x\n' > $WORK/.probe 2>/dev/null
_cls=no; grep -qE '[[:space:]]*x' $WORK/.probe 2>/dev/null && _cls=yes
note "grep: $(grep --version 2>&1 | head -1)"
note "supports:  [[:space:]]=$_cls   (full construct sweep is t57's job)"
[ "$_cls" = yes ] \
  && ok "[[:space:]] works, so assertions have a portable whitespace class" \
  || no "[[:space:]] does not work here - no portable way to match indentation"

# ---- 2: the assertion-sanity suite runs FIRST -------------------------------------------------------
# If the suites contain patterns this phone's grep cannot honour, every later verdict is suspect.
if [ -f $execDir/suites/accd/t57-assertion-sanity.sh ]; then
  if execDir=$execDir sh $execDir/suites/accd/t57-assertion-sanity.sh >$WORK/.t57 2>&1; then
    ok "t57 assertion-sanity passes - no unfailable assertions in the suites"
  else
    no "t57 assertion-sanity FAILED - the suites contain assertions that cannot fail; stop and fix"
    sed -n '/FAIL/p' $WORK/.t57 2>/dev/null | head -6 | sed 's/^/      /'
  fi
else
  no "t57 is missing - harness integrity is unverified"
fi

# ---- 3: the shutdown_temp prohibition, enforced mechanically -----------------------------------------
if assert_no_shutdown_temp_writes "$(dirname $0)"; then
  ok "no phase writes a numeric shutdown_temp (standing instruction, and a low value powers the phone off at room temperature)"
else
  no "a phase writes shutdown_temp - REFUSING to continue"
  exit 1
fi

# ---- 4: state capture, and proof the restore path actually works -------------------------------------
save_state
[ -f $RECOVER.config ] && ok "full config captured for crash recovery (not just three fields - a previous run lost the charging switch that way)" \
                       || no "state capture failed"

# Prove restore_state can put back a value we deliberately change. Done on a harmless field, and
# only while unplugged, so a failure here cannot strand the phone.
_before=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
acc -s cooldown_capacity=6 >/dev/null 2>&1
sleep 3
_mid=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
if [ "$_before" != "$_mid" ]; then
  cp -f $RECOVER.config $CFG 2>/dev/null
  daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1
  _after=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
  [ "$_before" = "$_after" ] \
    && ok "restore path verified live: a real change was made and put back" \
    || no "restore did NOT put the value back ($_before -> $_after) - the trap cannot be trusted"
else
  skip "could not perturb capacity to test the restore path"
fi

# ---- 5: the phone is in the state this run assumes ----------------------------------------------------
if [ "${EXPECT_PLUGGED:-no}" = yes ]; then
  plugged && ok "cable attached, as this phase set requires" || no "NOT plugged - the plugged phases cannot run"
else
  plugged && no "cable is ATTACHED - the unplugged phases measure nothing meaningful with it in" \
          || ok "cable is out, as the unplugged phases require"
fi

_l=$(lvl)
case "${_l:-}" in
  ''|*[!0-9]*) no "battery level unreadable" ;;
  *) [ "$_l" -ge 15 ] 2>/dev/null \
       && ok "battery at ${_l}%, enough headroom to run" \
       || no "battery at ${_l}% - too low to run a full pass safely" ;;
esac

# ---- 5b: state of charge, because a full pack makes a supply measurement meaningless -------------------
#
# A charger does not behave the same way at 30% and at 85%. Constant-current gives way to constant-
# voltage as the pack fills, current tapers, and on QC3 the negotiated voltage follows it down. A run
# that starts near full therefore measures the charge curve, not the build, and every comparison drawn
# from it is against a moving reference. Measured on a Mi A3 in one session: the supply fell 6.31V to
# 5.85V with ACC completely idle, purely because the pack was filling.
#
# The band is recorded on every run so two runs are never silently compared across different regimes,
# and a plugged run at or above the taper threshold refuses to offer a contract verdict at all.
note "state of charge band: $(soc_band)  (level ${_l}%)"
if [ "${EXPECT_PLUGGED:-no}" = yes ]; then
  if soc_comparable; then
    ok "pack is below the ${SOC_MAX:-75}% taper threshold, so the charge curve is not the dominant variable"
  else
    no "pack is at ${_l}%, at or above the ${SOC_MAX:-75}% taper threshold - current is tapering and the negotiated voltage follows it down, so any supply-voltage result here measures the charge curve rather than ACC. Discharge and re-run before trusting a contract verdict."
  fi
fi

# ---- 6: nothing is left over from a previous run ------------------------------------------------------
#
# .hvcontract IS NOT A LEFTOVER WHILE THE CABLE IS IN.
#
# It is the per-plug high-voltage contract latch: set once vbus reaches 6V, cleared on unplug and at
# daemon start. On a phone that has stayed plugged it is live state and deleting it strips the guard
# that stops a sagging supply being mistaken for "no contract" - which is precisely what permits the
# re-kick that collapses a QC/PD contract to 5V until a physical replug. This preflight deleted it
# unconditionally, so every plugged run tonight ran with that protection disabled on a Mi A3 whose
# QC3 supply sags from 6.5V to 5.1V as a matter of course. Nothing fired (apsd_rerun stayed 0), but
# the harness was disarming the product's own safety net in order to test it.
#
# Unplugged, it genuinely is stale: the daemon clears it on unplug, so one surviving there means a
# previous run died before that happened.
_leftover=0
for _f in $TD/.megatest $TD/.sw; do
  [ -e "$_f" ] && { note "leftover: $_f"; _leftover=$(( _leftover + 1 )); }
done
rm -f $TD/.sw 2>/dev/null || :
if [ -e $TD/.hvcontract ]; then
  if plugged; then
    ok "the contract latch is present and the cable is in - live state, left alone"
  else
    note "leftover: $TD/.hvcontract (stale: the daemon clears it on unplug)"
    _leftover=$(( _leftover + 1 ))
    rm -f $TD/.hvcontract 2>/dev/null || :
  fi
fi
[ "${_leftover:-0}" -eq 0 ] \
  && ok "no leftovers from an earlier run" \
  || note "$_leftover leftover marker(s) cleared"

# ---- 7: the switch is real and currently released ------------------------------------------------------
# An EMPTY switch is auto mode, not a fault. accd clears it on purpose when a switch stops holding,
# and re-picks one the next time a cut is needed. Reporting that as "charge control is not in effect"
# was wrong, and it is the fifth time switch state has been misread here by treating one legitimate
# configuration as broken. Only a switch that NAMES a node which does not exist is a real problem:
# then nothing can be written and nothing will be re-picked either.
_sw=$(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//' | tr -d ' ')
if [ -z "${_sw:-}" ]; then
  ok "no switch pinned - ACC is in auto mode and will pick one when a cut is next needed"
else
  _n=$(sw_node 2>/dev/null)
  if [ -n "${_n:-}" ] && [ -f "$_n" ]; then
    ok "charging switch resolves to a real node: $_n"
    note "$(sw_state_desc)"
    sw_released       && ok "charging is permitted by the switch - nothing is left cut"       || no "the switch is BLOCKING charge ($(sw_state_desc)) - the phone will not charge when plugged"
  else
    no "the config names a charging switch whose node does not exist - it can neither be written nor re-picked"
  fi
fi

# ---- 8: daemon is genuinely running, not merely lock-alive ---------------------------------------------
if daemon_alive; then
  if daemon_looping 20; then
    ok "daemon $(daemon_pid) is LOOPING (cpu time advanced), not just holding a lock"
  else
    no "daemon holds acc.lock but did NOT advance - it is wedged, and every A/B below would be junk"
  fi
else
  no "no daemon running"
fi
