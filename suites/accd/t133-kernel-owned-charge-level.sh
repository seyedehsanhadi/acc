#!/system/bin/sh
# t133 - reject kernel-owned thermal levels from charge-switch discovery.

ID=t133
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
W=${TMPDIR:-/data/local/tmp}/t133.$$
mkdir -p "$W/battery" || exit 1
trap 'rm -rf "$W"' EXIT

sed -n '/^kernel_owned_level_switch() {/,/^}/p' "$MF" > "$W/fn.sh"
[ -s "$W/fn.sh" ] || { no "missing kernel-owned level guard"; fin; exit; }
. "$W/fn.sh"

PS=$W
: > "$W/battery/charge_control_limit"
echo 6 > "$W/battery/charge_control_limit_max"
chargingSwitch=(battery/charge_control_limit 0 battery/charge_control_limit_max)
kernel_owned_level_switch \
  && ok "charge_control_limit_max=6 is rejected as a thermal level" \
  || no "charge_control_limit_max=6 can still enter switch discovery"

echo 100 > "$W/battery/charge_control_limit_max"
kernel_owned_level_switch \
  && no "a percentage-scale level was rejected" \
  || ok "charge_control_limit_max=100 remains eligible"

: > "$W/battery/input_suspend"
chargingSwitch=(battery/input_suspend 0 1)
kernel_owned_level_switch \
  && no "a boolean input cut was rejected" \
  || ok "ordinary boolean switches remain eligible"

_guard=$(grep -n 'if kernel_owned_level_switch' "$MF" | head -1 | cut -d: -f1)
_write=$(grep -n '\[ ! -f ${chargingSwitch\[0\]' "$MF" | head -1 | cut -d: -f1)
[ -n "$_guard" ] && [ -n "$_write" ] && [ "$_guard" -lt "$_write" ] \
  && ok "the guard runs before probe writes" \
  || no "the guard does not protect the write path"

fin
