#!/system/bin/sh
# t150 - the two switch watchdogs must reach an AUTOMATIC selection, and must still refuse to
# replace a manual lock.
#
# THE FAULT. Both the breach monitor and the resume-stall watchdog decided which switch they were
# allowed to act on with
#     [[ "${chargingSwitch[*]-}" = *\ -- ]]
# The trailing " --" is the MANUAL-LOCK marker. Since t148 an automatic pick no longer carries it,
# so the only class of switch ACC is permitted to replace could never enter the arm that replaces
# it: a non-holding automatic switch was warned about and then kept forever. Before t148 the marker
# was appended to automatic picks too, which made the gate pass for the wrong reason and stamped a
# spurious .user-locked on the way past.
#
# THE FIX. The condition is now "a switch is SELECTED" -- a non-empty chargingSwitch[0] -- and the
# separation between the two classes moves inside, where it already was: .user-locked present means
# warn and keep retrying the user's node, absent means unlock and blacklist.
#
# WHY THIS NEEDS ITS OWN SUITE. Replacing a failing automatic switch is behaviour rc24 never had.
# The debounce (3 confirmed loops, each re-verified across a 2s sleep) and the boot-scoped blacklist
# are what keep it from churning, so they are graded here as part of the gate.
#
# NO HARDWARE.

ID=t150
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found under $execDir"; fin; }

# ---- 1. both gates, and nothing else, moved ------------------------------------------------------
_marker=$(sed 's/^[[:space:]]*#.*//' "$AD" | grep -c 'chargingSwitch\[\*\]-}" = \*\\ --')
[ "$_marker" -eq 0 ] \
  && ok "no watchdog decides a switch class from the ' --' marker any more" \
  || no "$_marker watchdog gate(s) still read the manual-lock marker"

_sel=$(sed 's/^[[:space:]]*#.*//' "$AD" | grep -c '\[ -n "${chargingSwitch\[0\]-}" \]')
[ "$_sel" -ge 2 ] \
  && ok "both the breach monitor and the resume-stall watchdog gate on a SELECTED switch ($_sel sites)" \
  || no "expected 2 selected-switch gates, found $_sel"

grep -q 'rf -ge 4 \] && \[ -n "${chargingSwitch\[0\]-}" \]' "$AD" \
  && ok "the resume-stall watchdog keeps its 4-failure debounce alongside the new gate" \
  || no "the resume-stall debounce changed with the gate"

# ---- 2. the gate itself, driven ------------------------------------------------------------------
# OLD is the rc24 form, NEW is the shipped one. Both are run over the same three config values.
gate(){ # $1 arm, $2 the literal charging_switch value
  ( eval "set -A chargingSwitch $2"
    case $1 in
      old) case "${chargingSwitch[*]-}" in *\ --) echo REPLACEABLE;; *) echo UNREACHABLE;; esac ;;
      new) if [ -n "${chargingSwitch[0]-}" ]; then echo REPLACEABLE; else echo UNREACHABLE; fi ;;
    esac ) 2>/dev/null
}
[ "$(gate old 'battery/input_suspend 1 0')" = UNREACHABLE ] \
  && ok "the old gate could not reach an automatic switch - the defect reproduces" \
  || no "the old gate reached an automatic switch, so this suite is not measuring the defect"
[ "$(gate new 'battery/input_suspend 1 0')" = REPLACEABLE ] \
  && ok "the new gate reaches an automatic switch" \
  || no "the new gate still cannot reach an automatic switch"
[ "$(gate new '')" = UNREACHABLE ] \
  && ok "no switch selected still falls to the else arm, which only notifies" \
  || no "an empty switch now reaches the blacklist arm"
[ "$(gate new 'battery/input_suspend 1 0 --')" = REPLACEABLE ] \
  && ok "a manual lock also enters the arm, where .user-locked decides what happens to it" \
  || no "a manual lock no longer enters the monitored arm"

# ---- 3. a manual lock is still never auto-replaced ------------------------------------------------
_arm=$(sed -n '/if \[ -n "${chargingSwitch\[0\]-}" \]; then/,/^          else$/p' "$AD" | head -40)
printf '%s' "$_arm" | grep -q 'if \[ -f \$dataDir/.user-locked \]; then' \
  && ok "the user-lock test is the first branch inside the arm" \
  || no "the .user-locked branch is not inside the monitored arm"
printf '%s' "$_arm" | sed -n '/if \[ -f \$dataDir\/.user-locked \]; then/,/else/p' | grep -q 'sw-blacklist' \
  && no "a user-locked switch can reach the blacklist" \
  || ok "a user-locked switch is warned about, never blacklisted"
printf '%s' "$_arm" | grep -q 'warn_once_per lockhold' \
  && ok "the user-locked branch still warns" || no "the user-locked warning is gone"

# ---- 4. the debounce that keeps the new power from churning ---------------------------------------
printf '%s' "$_arm" | grep -q 'lf -ge 3' \
  && ok "the blacklist needs 3 confirmed loops" || no "the 3-loop debounce is gone"
grep -q 'sleep 2 && present && { _thermal_hold_active || _ge_pause_cap; } && ! not_charging' "$AD" \
  && ok "each of those loops re-verifies across a 2s sleep, so one bad sample cannot start a replacement" \
  || no "the breach monitor lost its second, delayed confirmation"
grep -q 'sw-blacklist' "$AD" && grep -q '\$TMPDIR/.sw-blacklist' "$AD" \
  && ok "the blacklist lives in tmpfs, so a reboot retries the switch" \
  || no "the blacklist is not tmpfs-scoped"

fin
