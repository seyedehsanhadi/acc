#!/system/bin/sh
# t148 - an automatically selected switch must not present itself as a manual lock.
#
# THE FAULT, found on both test phones at once. laurus carried
#   chargingSwitch=(battery/input_suspend 0 1 --)
# and bluejay carried
#   chargingSwitch=(/sys/devices/platform/google,charger/charge_stop_level 100 pcap --)
# with $dataDir/.user-locked present on both, timestamped to the same second as config.txt. Neither
# had ever been locked by hand.
#
# WHERE IT COMES FROM. cycle_switches appended " --" when a candidate passed the strict pass. That
# string is the manual-lock marker, and four readers act on it:
#   - AccA's isAutomaticSwitchEnabled reads it off the charging_switch line and reports automatic
#     mode as OFF,
#   - write-config's pbim arm skips the deliberate auto-mode switch reset,
#   - write-config's own tail touches .user-locked on the first NON-daemon write that sees it, which
#     is what promoted an automatic pick into a lock ACC then refuses to replace,
#   - accd's init release of a left-cut switch excludes a marked switch, so a stranded automatic cut
#     survives the restart that exists to clear it.
#
# THE OTHER HALF. Dropping the marker is only safe because the two runtime watchdogs no longer look
# for it. Both used to read `[[ "${chargingSwitch[*]}" = *\ -- ]]`, so with an unmarked automatic
# switch they took their else arm, which notifies and never replaces: the one switch class ACC is
# permitted to swap was the one class that could never reach the reselect. They now test that a
# switch is SELECTED, and .user-locked alone separates a manual lock from an automatic pick.

ID=t148
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
dataDir=${dataDir:-/data/adb/vr25/acc-data}
MF=$execDir/misc-functions.sh
AD=$execDir/accd.sh
[ -f "$MF" ] && [ -f "$AD" ] || { no "misc-functions.sh or accd.sh not found under $execDir"; fin; }

# ---- 1. the selection itself -------------------------------------------------------------------
_cycle=$(awk '/^cycle_switches\(\) \{/,/^}/' "$MF")
[ -n "$_cycle" ] || { no "cycle_switches not found"; fin; }

printf '%s\n' "$_cycle" | grep -q 'chargingSwitch\[\*\]} --' \
  && no "the strict pass still appends the manual-lock marker to an automatic selection" \
  || ok "an automatic selection is stored without the manual-lock marker"

# The assignment must still happen, or the fan-out never settles - this is the half that is easy to
# delete along with the marker.
printf '%s\n' "$_cycle" | grep -qE '^[[:space:]]*s="\$\{chargingSwitch\[\*\]\}"[[:space:]]*$' \
  && ok "the verified switch is still persisted" \
  || no "the verified switch is no longer persisted - the re-probe sawtooth returns"

# ---- 2. both watchdogs must reach an automatic switch -------------------------------------------
# A marker test here is the defect. Count them: zero is the contract.
# Fixed string, not a regex: toybox grep reads a lone \} as an unbalanced interval and errors out.
_gates=$(grep -cF '"${chargingSwitch[*]-}" = *\ --' "$AD") || _gates=0
[ "${_gates:-0}" -eq 0 ] \
  && ok "no watchdog gates its reselect on the manual-lock marker" \
  || no "${_gates} watchdog gate(s) still test the marker - an automatic switch can never be replaced"

# Each of the two must instead test that a switch is selected, and must still consult .user-locked.
# Two separate greps, never a `\|` alternation: toybox grep does not implement it, so on a phone
# that pattern matches nothing and a negative count would read as a silent pass.
_sel=$(grep -c 'if \[ -n "${chargingSwitch\[0\]-}" \]; then' "$AD") || _sel=0
_selr=$(grep -c 'if \[ \$rf -ge 4 \] && \[ -n "${chargingSwitch\[0\]-}" \]; then' "$AD") || _selr=0
_sel=$(( _sel + _selr ))
[ "${_sel:-0}" -ge 2 ] \
  && ok "both watchdogs gate on a SELECTED switch" \
  || no "expected 2 selected-switch gates in accd.sh, found ${_sel:-0}"

_ul=$(grep -c '\-f \$dataDir/\.user-locked' "$AD") || _ul=0
[ "${_ul:-0}" -ge 3 ] \
  && ok ".user-locked still protects a manual lock on every arm" \
  || no "only ${_ul:-0} .user-locked guards remain - a manual lock can be auto-replaced"

# ---- 3. the init release must not exclude an automatic switch -----------------------------------
# This line releases a switch left cut across a restart. It excludes a MARKED switch on purpose (a
# user lock is the user's business). With the marker gone from automatic picks it now covers them,
# which is the point; the exclusion itself must stay for real locks.
grep -F -q "!= *\ -- ]]" "$AD" && grep -q "chDisabledByAcc && \[ -n" "$AD" \
  && ok "the init release still skips a genuinely locked switch and now covers automatic ones" \
  || no "the init release no longer distinguishes a user lock"

# ---- 4. live state, when there is one -----------------------------------------------------------
CFG=${config:-$dataDir/config.txt}
if [ -f "$CFG" ]; then
  _sw=$(sed -n 's/^chargingSwitch=(\(.*\))$/\1/p' "$CFG" | head -1)
  case "$_sw" in
    *' --')
      if [ -f "$dataDir/.user-locked" ]; then
        ok "the stored switch is marked and .user-locked is present - a consistent manual lock"
      else
        no "the stored switch carries ' --' with no .user-locked - an automatic pick wearing a lock"
      fi
    ;;
    '') ok "no switch stored yet - nothing to misreport";;
    *)  ok "the stored switch is unmarked - AccA will report automatic mode correctly";;
  esac
else
  ok "no live config to inspect"
fi

fin
