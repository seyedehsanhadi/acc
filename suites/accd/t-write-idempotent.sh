#!/system/bin/sh
# write() must not re-poke a node that already holds the target value.
#
# ACC re-asserts the switch every daemon loop while charging. Re-writing the SAME value (and the
# chmod that goes with it) re-triggers AICL / the charge-pump FSM on PPS/PD/VOOC/QC-CP phones,
# which drops fast charge to the main buck charger and never lets it re-engage - the "only slow
# charging after ACC" reports. rc14 fixed that by reading the node first and returning when it
# already matches.
#
# The mega2 mutation phase removes the gate:
#   if [ -n "$_cur" ] && [ "$_cur" = "$_tgt" ]; then   ->   if false; then
# and reported "NO suite fails with the defect present. This is a real coverage hole."
# This suite is that missing detector.
#
# A same-value poke is invisible in the node's contents, so this counts WRITES, using a ledger
# the production writer already calls (_wlog fires only on a real value change).

ID=t-write-idempotent
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

# Writes $1 to the node N times through the real write(), and prints how many reached the device.
pokes() {
  _val=$1; _n=$2
  _W=$(TMPDIR=$_TMPD0 mktemp -d) || { echo MKTEMP-FAILED; return; }
  (
    TMPDIR=$_W; dataDir=$_W; execDir=$_W
    mkdir -p "$_W/logs"
    _NODE=$_W/node; echo "$_val" > "$_NODE"
    _HITS=$_W/hits; : > "$_HITS"
    isAccd=true
    sw_blacklisted(){ return 1; }
    parse_value(){ echo "$1"; }
    mtk_current_flag(){ return 1; }
    # Count every real device write. _wlog is the production ledger hook and fires only when a
    # value actually changes, so it is the honest counter here.
    _wlog(){ echo "$*" >> "$_HITS"; }
    eval "$(awk -v fn=write -f "$AWKF" "$MF")" 2>/dev/null
    command -v write >/dev/null 2>&1 || { echo LIFT-FAILED; exit 0; }
    _i=0
    while [ "$_i" -lt "$_n" ]; do write "$_val" "$_NODE" >/dev/null 2>&1 || :; _i=$((_i + 1)); done
    wc -l < "$_HITS" 2>/dev/null || echo 0
  )
  rm -rf "$_W"
}

# --- 1: the lift has to work, or the count below means nothing ------------------------------
_same=$(pokes 42 5)
case "$_same" in
  *LIFT-FAILED*|*MKTEMP-FAILED*) no "could not run write() - no verdict"; fin; exit $?;;
  ''|*[!0-9]*) no "write() produced no usable count ('$_same') - no verdict"; fin; exit $?;;
esac

# --- 2: THE POINT. Five pokes of the value already there must reach the device zero times ----
if [ "$_same" -eq 0 ]; then
  ok "5 same-value pokes produced 0 device writes (idempotent)"
else
  no "5 same-value pokes produced $_same device writes - every daemon loop re-triggers charger negotiation and fast charge drops"
fi

# --- 3: the control. A real change must still be written, or the gate is just breaking writes -
_W2=$(TMPDIR=$_TMPD0 mktemp -d)
_changed=$(
  TMPDIR=$_W2; dataDir=$_W2; execDir=$_W2
  mkdir -p "$_W2/logs"
  _NODE=$_W2/node; echo 1 > "$_NODE"
  _HITS=$_W2/hits; : > "$_HITS"
  isAccd=true
  sw_blacklisted(){ return 1; }
  parse_value(){ echo "$1"; }
  mtk_current_flag(){ return 1; }
  _wlog(){ echo "$*" >> "$_HITS"; }
  eval "$(awk -v fn=write -f "$AWKF" "$MF")" 2>/dev/null
  write 999 "$_NODE" >/dev/null 2>&1 || :
  wc -l < "$_HITS" 2>/dev/null || echo 0
)
rm -rf "$_W2"
case "$_changed" in
  ''|*[!0-9]*) no "control produced no usable count - no verdict";;
  *) [ "$_changed" -ge 1 ] \
       && ok "a real value change is still written (the gate skips pokes, not writes)" \
       || no "a real value change was NOT written - the idempotency gate is swallowing real writes";;
esac

fin
