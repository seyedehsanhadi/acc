#!/system/bin/sh
# Releasing a latched charging switch must NOT depend on the cable being attached.
#
# This is the rc22 strand: a switch cut while the charger was plugged stays cut after the cable
# comes out, and nothing electrical undoes it - the next plug-in still cannot charge. The fix
# was to call flip_sw on unconditionally and gate only the fallback SWEEP on present(), because
# a sweep cannot re-arm anything when there is no charger anyway.
#
# The mega2 mutation phase re-injects the defect:
#   flip_sw on || { present && _rearm_sweep; }   ->   if present; then flip_sw on || ...; fi
# and reported "NO suite fails with the defect present. This is a real coverage hole."
# This suite is that missing detector: it runs the real enable_charging with present() false and
# asserts the release still happened.

ID=t-release-not-gated-on-present
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=${MF:-$execDir/misc-functions.sh}
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AWKF=${AWKF:-$SELF/../xf.awk}
[ -f "$MF" ]   || { no "missing $MF"; fin; exit $?; }
[ -f "$AWKF" ] || { no "missing $AWKF"; fin; exit $?; }

_TMPD0=${TMPDIR:-}
[ -d "${_TMPD0:-/nonexistent}" ] || _TMPD0=/data/local/tmp
[ -d "$_TMPD0" ] || _TMPD0=/tmp
[ -d "$_TMPD0" ] || _TMPD0=.

# $1 = what present() reports (0 = cable attached, 1 = cable out)
# Prints every release-relevant call enable_charging made.
calls() {
  _W=$(TMPDIR=$_TMPD0 mktemp -d) || { echo MKTEMP-FAILED; return; }
  _LOG=$_W/log; : > "$_LOG"
  (
    TMPDIR=$_W; dataDir=$_W; execDir=$_W
    mkdir -p "$_W/logs"
    ghostCharging=false; isAccd=true; _acc_nopromo=1
    chargingSwitch=("$_W/sw" 1 0 --); echo 0 > "$_W/sw"
    _pres=$1
    present(){ return $_pres; }
    online(){ return $_pres; }
    flip_sw(){ echo "flip_sw $1" >> "$_LOG"; return 0; }
    cycle_switches(){ echo "cycle_switches $1" >> "$_LOG"; return 0; }
    _rearm_sweep(){ echo "_rearm_sweep" >> "$_LOG"; return 0; }
    mtk_current_flags(){ :; }
    write(){ :; }; _wlog(){ :; }; parse_value(){ echo "$1"; }
    print_charging_enabled(){ :; }; print_charging_enabled_for(){ :; }
    print_charging_enabled_until(){ :; }; print_unplugged(){ :; }
    disable_charging(){ :; }; not_charging(){ return 1; }
    volt_now(){ echo 4000; }; batt_cap(){ echo 50; }
    eval "$(awk -v fn=enable_charging -f "$AWKF" "$MF")" 2>/dev/null
    command -v enable_charging >/dev/null 2>&1 || { echo "LIFT-FAILED" >> "$_LOG"; exit 0; }
    enable_charging >/dev/null 2>&1 || :
  ) >/dev/null 2>&1
  cat "$_LOG" 2>/dev/null
  rm -rf "$_W"
}

# --- 1: the lift has to work, or every assertion below is vacuous ---------------------------
out_out=$(calls 1)   # cable OUT
out_in=$(calls 0)    # cable IN
case "$out_out$out_in" in
  *LIFT-FAILED*|*MKTEMP-FAILED*)
    no "could not run enable_charging (lift or scratch dir failed) - no verdict"
    fin; exit $?;;
esac
printf '%s\n' "$out_in" | grep -q 'flip_sw on' \
  && ok "control: with the cable attached the switch is released" \
  || { no "control failed: no release even WITH a cable - the harness is not exercising the path"
       fin; exit $?; }

# --- 2: THE POINT. No cable, and the release must still happen ------------------------------
printf '%s\n' "$out_out" | grep -q 'flip_sw on' \
  && ok "with the cable OUT the switch is still released (not gated on present)" \
  || no "the release is gated on present() - a switch latched off stays latched with no cable, and the next plug-in cannot charge"

# --- 3: the sweep, and only the sweep, may be gated -----------------------------------------
if printf '%s\n' "$out_out" | grep -qE '_rearm_sweep|cycle_switches'; then
  no "a fallback sweep ran with no cable - it cannot re-arm anything and costs forks"
else
  ok "no fallback sweep with the cable out, which is the one thing present() may gate"
fi

fin
