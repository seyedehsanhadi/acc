#!/system/bin/sh
# The unplugged verdict must be gated by a REAL present() implementation.
#
# idle_discharging ends with the last word on the matter:
#     if [ "$_status" = Charging ] && ! present 2>/dev/null; then _status=Discharging; fi
# so a phone with no cable can never be reported as Charging. Both phones once did exactly that,
# with opposite current signs and opposite cached polarity, because all three arbiters are
# inferences and failed together; present() is the only one that asks the hardware.
#
# The mega2 mutation phase deletes the implementation:
#     present()   ->   present_DISABLED()
# and reported "NO suite fails with the defect present. This is a real coverage hole."
#
# Nothing caught it because an UNDEFINED command exits 127, so `! present` is still true and the
# guard still happens to take the safe branch. The behaviour survives by accident - every other
# present() caller in the daemon is now calling a command that does not exist. A detector for
# this has to assert the gate resolves to a real implementation, not merely that this one branch
# lands the right way.

ID=t-unplugged-verdict-gate
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=${BI:-$execDir/batt-interface.sh}
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AWKF=${AWKF:-$SELF/../xf.awk}
[ -f "$BI" ]   || { no "missing $BI"; fin; exit $?; }
[ -f "$AWKF" ] || { no "missing $AWKF"; fin; exit $?; }

# --- 1: the implementation must exist -------------------------------------------------------
# This is the mutation. Renaming present() leaves every caller invoking a missing command, which
# exits 127 and silently reads as "not present" everywhere.
if grep -qE '^present\(\)' "$BI"; then
  ok "batt-interface.sh defines present(), so the gate calls a real implementation"
else
  no "no present() definition - every caller invokes a missing command that exits 127, and the unplugged verdict holds only by accident"
fi

# --- 2: the gate must be the LAST word in idle_discharging ----------------------------------
_body=$(awk -v fn=idle_discharging -f "$AWKF" "$BI" 2>/dev/null)
if [ -z "$_body" ]; then
  no "could not lift idle_discharging - no verdict"
else
  _tail=$(printf '%s\n' "$_body" | grep -vE '^[[:space:]]*#' | grep -E '[^[:space:]]' | tail -4)
  case "$_tail" in
    *'! present'*) ok "the present() gate is the last correction idle_discharging applies" ;;
    *) no "idle_discharging does not end on the present() gate - a later branch can re-promote the status to Charging" ;;
  esac
fi

# --- 3: behaviour. Run the GUARD ITSELF, not the whole function ------------------------------
# idle_discharging reads the sensor stack, so eval'ing the whole body standalone aborts partway
# and leaves _status untouched. That made the "no cable" case fail on a CLEAN tree and made the
# plugged control pass for the wrong reason - a vacuous pass. Lift just the final guard, which
# is self-contained, and drive present() both ways.
_guard=$(printf '%s\n' "$_body" | grep -A2 -E '^[[:space:]]*if \[ "\$_status" = Charging \] && ! present')

if [ -z "$_guard" ]; then
  no "could not lift the final present() guard - no verdict"
else
  _out=$(
    _status=Charging
    present(){ return 1; }        # cable OUT
    eval "$_guard" >/dev/null 2>&1 || :
    echo "$_status"
  )
  [ "$_out" = Discharging ] \
    && ok "with no cable a Charging status is corrected to Discharging" \
    || no "with no cable the verdict stayed '$_out' - ACC would claim to be charging while unplugged"

  _out2=$(
    _status=Charging
    present(){ return 0; }        # cable IN
    eval "$_guard" >/dev/null 2>&1 || :
    echo "$_status"
  )
  [ "$_out2" = Charging ] \
    && ok "control: with a cable attached a genuine Charging status is left alone" \
    || no "control: a plugged phone was demoted to '$_out2' - the gate is firing unconditionally"
fi

fin
