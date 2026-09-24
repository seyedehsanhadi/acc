#!/system/bin/sh
# t155 - enable_charging must survive an UNSET chargingSwitch under `set -u`.
#
# The measured failure (Mi A3 + Pixel 6a, rc25-test24-7, both phones, clean baseline):
#
#     $ acc -e
#     accd stopped
#     Hang on... 
#     /sbin/acc[1415]: chargingSwitch[@]: parameter not set
#     $ cat /sys/class/power_supply/battery/input_suspend
#     1
#
# `acc -e` exited 0, printed no failure, and the latched switch was never released - the phone
# could not charge again until something else wrote the node. The daemon was left stopped too,
# because the restart at the tail of the -e branch is downstream of the abort.
#
# The offending line is the FIRST statement inside the `.sw` restore block:
#
#     local _resumeSwitch; _resumeSwitch=("${chargingSwitch[@]}")
#
# and the two preconditions that make it fire are the ordinary case, not an edge case:
#
#   1. $TMPDIR/.sw exists - written by the daemon on every idle-avoidance pause, so it is present
#      exactly when the phone IS paused and `acc -e` is the command that matters.
#   2. chargingSwitch is unset - config.txt ships WITHOUT a charging_switch line (auto-discovery
#      is the documented default: "If unset, acc cycles through its database"). Confirmed absent
#      on both test phones. The array only exists in a shell that has run discovery; a fresh CLI
#      invocation has not.
#
# Under mksh with `set -u`, expanding an unset array is fatal. The guard is `[@]-`.
#
# NO HARDWARE.

ID=t155
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed${S:+, $S skipped}"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
TD=${TMPDIR:-/data/local/tmp}/t155.$$
mkdir -p "$TD" || { echo "$ID: cannot create $TD"; exit 1; }
trap 'rm -rf "$TD"' EXIT

[ 1 = 2 ] && no "harness: 1 equals 2" || ok "harness: the assertions discriminate"
[ -f "$MF" ] || { sk "misc-functions.sh not found at $MF"; fin; }

# ---- 1. the shipped source carries the guard ---------------------------------------------------
_line=$(grep -n '_resumeSwitch=(' "$MF" | head -1)
case "$_line" in
  *'${chargingSwitch[@]-}'*) ok "the .sw restore guards the array (${_line%%:*})" ;;
  '')                        no "the _resumeSwitch save is gone - this test no longer covers it" ;;
  *)                         no "the .sw restore expands chargingSwitch UNGUARDED: ${_line#*:}" ;;
esac

# ---- 2. drive it: the exact expansion, unset, under set -u -------------------------------------
# Not a grep. The lift is the two statements the abort happened between, run in a real mksh with
# the same `set -u` the daemon and the CLI both run under, with chargingSwitch never assigned.
_sw=$TD/.sw
echo 'chargingSwitch=(battery/input_suspend 0 1)' > "$_sw"

_probe() {   # $1 = the expansion to test; prints the shell's own diagnosis
  cat > "$TD/p.sh" <<PROBE
set -eu
TMPDIR=$TD
f() {
  if [ -f \$TMPDIR/.sw ]; then
    local _resumeSwitch; _resumeSwitch=("\${chargingSwitch$1}")
    . \$TMPDIR/.sw 2>/dev/null || :
    [ -n "\${chargingSwitch[0]-}" ] || chargingSwitch=("\${_resumeSwitch[@]}")
    echo "released: \${chargingSwitch[*]}"
  fi
}
f
PROBE
  /system/bin/sh "$TD/p.sh" 2>&1
}

_out=$(_probe '[@]-')
case "$_out" in
  *'released: battery/input_suspend 0 1'*) ok "guarded: the switch is restored from .sw and released" ;;
  *)                                       no "guarded form still failed: $_out" ;;
esac

# The mutant. If this PASSES, the shell on this device does not enforce `set -u` on arrays and
# assertion 2 above proves nothing here - say so rather than bank a green.
_out=$(_probe '[@]')
case "$_out" in
  *'parameter not set'*)                   ok "unguarded form aborts, as the field failure did" ;;
  *'released: battery/input_suspend 0 1'*) sk "this shell does not fault on an unset array - assertion 2 is not discriminating here" ;;
  *)                                       no "unguarded form neither aborted nor released: $_out" ;;
esac

# ---- 3. no OTHER unguarded array expansion sits on the `acc -e` path ---------------------------
# enable_charging runs before any config is re-sourced. Every array it touches must carry a
# default, or the same abort returns wearing a different variable name.
# A name the function ASSIGNS itself before use cannot be unset when it is read; _resumeSwitch is
# written on the line above its only expansion. Only names that arrive from the config can abort,
# so those are what this looks for.
_body=$(sed -n '/^enable_charging()/,/^}/p' "$MF" | sed 's/#.*//')
_bad=
for _n in $(printf '%s' "$_body" | grep -oE '[$][{][A-Za-z_][A-Za-z0-9_]*\[[@*]\][}]' \
            | sed 's/^..//;s/\[.*//' | sort -u); do
  printf '%s' "$_body" | grep -qE "(^|[^A-Za-z0-9_])$_n=\(" && continue
  _bad="$_bad $_n"
done
[ -z "$_bad" ] \
  && ok "enable_charging has no unguarded config-array expansion left" \
  || no "enable_charging still expands unguarded:$_bad"

fin
