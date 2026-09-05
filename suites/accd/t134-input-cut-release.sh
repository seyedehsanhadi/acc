#!/system/bin/sh
# t134 - direct input-cut release evidence clears stale ownership.

ID=t134
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
W=${TMPDIR:-/data/local/tmp}/t134.$$
mkdir -p "$W" || exit 1
trap 'rm -rf "$W"' EXIT
sed -n '/^switch_release_observed() {/,/^}/p' "$MF" > "$W/fn.sh"
[ -s "$W/fn.sh" ] || { no "missing release observer"; fin; exit; }
. "$W/fn.sh"

present(){ return 0; }
online(){ return "${OFFLINE:-0}"; }
parse_value(){ echo "$1"; }
N=$W/input_suspend
chargingSwitch=($N 0 1)

echo 0 > "$N"
switch_release_observed \
  && ok "released input cut plus online is accepted" \
  || no "physical release evidence was ignored"

echo 1 > "$N"
switch_release_observed \
  && no "a still-latched cut was accepted" \
  || ok "a still-latched cut keeps ownership"

echo 0 > "$N"; OFFLINE=1
switch_release_observed \
  && no "an offline supply was accepted as resumed" \
  || ok "online is required before ownership clears"

OFFLINE=0; rm -f "$N"
switch_release_observed \
  && no "a missing switch node was accepted as released" \
  || ok "a missing switch node keeps ownership"

grep -A8 '^    if not_charging; then' "$MF" | grep -q 'switch_release_observed && chDisabledByAcc=false' \
  && ok "enable_charging consumes the direct evidence" \
  || no "the observer is not wired into enable_charging"

grep -A2 'flip_sw on ||' "$MF" | grep -q 'flip=' \
  && ok "resume clears switch-test mode before checking current" \
  || no "resume can enter the 35-second ON-test"

fin
