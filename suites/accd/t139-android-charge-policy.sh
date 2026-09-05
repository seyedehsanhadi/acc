#!/system/bin/sh
# Android's charging_policy is an ownership interface, not an ACC switch.

ID=t139
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
PF=$execDir/post-fs-data.sh
ROOT=${ROOT:-$execDir/../..}
AC=${AC:-$ROOT/acc-compat.sh}
AM=${AM:-$ROOT/amps.sh}
W=${TMPDIR:-/data/local/tmp}/t139.$$
rm -rf "$W" 2>/dev/null; mkdir -p "$W/ps/battery" "$W/data/logs"
trap 'rm -rf "$W" 2>/dev/null' EXIT

for _f in "$AD" "$PF"; do [ -f "$_f" ] || { no "missing $_f"; fin; exit $?; }; done

_fn=$(sed -n '/^  system_charge_policy_active() {/,/^  }/p' "$AD")
_pd=$(sed -n '/^  probe_due() {/,/^  }/p' "$AD")
if [ -n "$_fn" ] && [ -n "$_pd" ]; then
  eval "$_fn"
  eval "$_pd"
  ACC_PSY=$W/ps
  capacity[3]=80
  batt_cap(){ echo 78; }

  echo 3 > "$W/ps/battery/charging_policy"
  probe_due && no "automatic switch probing still runs under an active OS policy" \
    || ok "active OS policy suppresses automatic switch probing"

  echo 1 > "$W/ps/battery/charging_policy"
  probe_due && ok "DEFAULT OS policy leaves ACC discovery available" \
    || no "DEFAULT OS policy wrongly disables ACC discovery"

  echo broken > "$W/ps/battery/charging_policy"
  probe_due && ok "an unreadable policy fails open instead of silently disabling ACC" \
    || no "a malformed policy silently disables ACC"
else
  no "daemon policy helpers could not be extracted"
fi

_sw=$(sed -n '/^    sw_excluded() {/,/^    }/p' "$AD")
if [ -n "$_sw" ]; then
  eval "$_sw"
  sw_excluded battery/charging_policy \
    && ok "daemon candidate discovery excludes charging_policy" \
    || no "daemon can still probe charging_policy"
else
  no "daemon switch exclusion helper could not be extracted"
fi

grep -q 'warn_once_per ospolicy' "$AD" \
  && ok "the daemon explains why automatic discovery is paused" \
  || no "active OS ownership silently disables automatic discovery"

cat > "$W/config" <<EOF
capacity=(5 101 72 75 false)
chargingSwitch=($W/ps/battery/input_suspend 0 1 --)
EOF
echo 0 > "$W/ps/battery/input_suspend"
echo 80 > "$W/ps/battery/capacity"
echo Battery > "$W/ps/battery/type"

echo 3 > "$W/ps/battery/charging_policy"
EARLYCAP_CFG=$W/config EARLYCAP_PS=$W/ps EARLYCAP_DATA=$W/data sh "$PF" __work >/dev/null 2>&1
[ "$(cat "$W/ps/battery/input_suspend")" = 0 ] \
  && ok "early boot does not fight an active OS policy" \
  || no "early boot wrote a charge switch under an active OS policy"

echo 1 > "$W/ps/battery/charging_policy"
EARLYCAP_CFG=$W/config EARLYCAP_PS=$W/ps EARLYCAP_DATA=$W/data sh "$PF" __work >/dev/null 2>&1
[ "$(cat "$W/ps/battery/input_suspend")" = 1 ] \
  && ok "DEFAULT policy preserves the configured early cap" \
  || no "DEFAULT policy prevented the configured early cap"

for _f in "$AC" "$AM"; do
  [ -f "$_f" ] || continue
  grep '^DANGER_RE=' "$_f" | grep -q 'charging_policy' \
    && ok "$(basename "$_f") refuses to write charging_policy" \
    || no "$(basename "$_f") can write charging_policy"
done

/system/bin/sh -n "$AD" 2>/dev/null && /system/bin/sh -n "$PF" 2>/dev/null \
  && ok "policy-guarded boot scripts parse" \
  || no "a policy-guarded boot script does not parse"

fin
