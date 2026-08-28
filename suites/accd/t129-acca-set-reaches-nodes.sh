#!/system/bin/sh
# t129 - `acca -s` must reach the HARDWARE for the keys whose effect lives in sysfs.
#
# WHAT WENT WRONG
#   acc -s and acca -s are two front-ends onto one idea, and they had drifted. acc -s routes through
#   set-prop.sh, which calls set_ch_curr / set_ch_volt / set_temp_level. acca -s did not: it
#   sourced the config, assigned the variable, ran write-config.sh and exited. Config written,
#   nodes untouched.
#
#   AccA drives acca. So clearing a charge-voltage limit from the APP wrote
#   maxChargingVoltage=() and left battery/voltage_max and main/voltage_max pinned at 4150000
#   against a 4400000 default. A 4.15V ceiling holds a pack near 70%, it survived a clear, an
#   unplug and a reboot, and nothing in the config or the UI said so. Found on a Mi A3 only by
#   reading the sysfs nodes; under `sh -x` the trace showed the array cleared and the branch
#   returning with set_ch_volt never called at all.
#
#   Fix: acca -s delegates those keys to acc.sh, so there stays ONE implementation of the
#   apply/release rules rather than a second copy free to drift again.
#
# NO CHARGER NEEDED. The release path is what broke, and it runs unplugged.

ID=t129
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AA=$execDir/acca.sh
[ -f "$AA" ] || { no "missing $AA"; fin; }

# ---- 1: source-level, so the delegation cannot be quietly dropped --------------------------------
_aac=$(sed 's/^[[:space:]]*#.*//' "$AA")
printf '%s' "$_aac" | grep -qE 'mcv\|max_charging_voltage' \
  && ok "acca -s recognises the voltage keys as node-affecting" \
  || no "acca -s no longer routes mcv anywhere - the config would be written and the nodes left"

printf '%s' "$_aac" | grep -qE 'mcc\|max_charging_current' \
  && ok "acca -s recognises the current keys" \
  || no "acca -s no longer routes mcc"

printf '%s' "$_aac" | grep -q 'id:-acc' \
  && ok "the delegation uses \${id:-acc} (acca never sets id; a bare \${id} aborts under set -eu)" \
  || no "the delegation uses a bare \${id} - under set -eu that kills the front-end before write-config"

# ---- 2: behaviour, on the real phone --------------------------------------------------------------
[ "$(id -u 2>/dev/null)" = 0 ] || { sk "not root; skipping the live round trip"; fin; }
PS=/sys/class/power_supply
CFG=${config:-/data/adb/vr25/acc-data/config.txt}
# NOT ${TMPDIR:-...}: on Android a shell inherits TMPDIR=/data/local/tmp, so that default never
# applies and the runtime link is looked for in the wrong place - which reads as "no acca" and
# skips the only assertion that touches hardware.
A=/dev/.vr25/acc
[ -x "$A/acca" ] || A=$(dirname "$execDir")/acc
[ -x "$A/acca" ] || { sk "no runtime acca link"; fin; }

_vn=
for n in battery/voltage_max main/voltage_max; do [ -f "$PS/$n" ] && _vn="$_vn $n"; done
[ -n "$_vn" ] || { sk "this device has no voltage control node"; fin; }

_bak=/data/local/tmp/.t129.cfg
cp "$CFG" "$_bak" 2>/dev/null

# Stage the exact failing state: nodes capped, config carrying the node-spec form.
for n in $_vn; do chmod u+w "$PS/$n" 2>/dev/null; echo 4150000 > "$PS/$n" 2>/dev/null; done
sed -i 's|^maxChargingVoltage=.*|maxChargingVoltage=(4150 battery/voltage_max::4150000::4400000 main/voltage_max::4150000::4400000)|' "$CFG"
rm -f "$A/.volt-custom" 2>/dev/null

# PROVE THE SETUP LANDED. Without this the assertion below passes on a phone that was never capped.
_staged=0
for n in $_vn; do [ "$(cat "$PS/$n" 2>/dev/null)" = 4150000 ] && _staged=$((_staged+1)); done
if [ "$_staged" -eq 0 ]; then
  sk "could not cap the nodes on this device; the round trip would prove nothing"
  cp "$_bak" "$CFG" 2>/dev/null
  fin
fi
ok "staged: $_staged node(s) held at 4150000 against a 4400000 default"

"$A/acca" -s mcv= >/dev/null 2>&1
sleep 3

_still=
for n in $_vn; do
  v=$(cat "$PS/$n" 2>/dev/null)
  [ "$v" = 4400000 ] || _still="$_still $n=$v"
done
[ -z "$_still" ] \
  && ok "acca -s mcv= restored every voltage node to its default" \
  || no "acca -s mcv= left the hardware capped:$_still (config says no limit)"

grep -q '^maxChargingVoltage=()' "$CFG" \
  && ok "and the config records no limit" \
  || no "the config still carries a voltage limit after the clear"

cp "$_bak" "$CFG" 2>/dev/null
rm -f "$_bak" 2>/dev/null
fin
