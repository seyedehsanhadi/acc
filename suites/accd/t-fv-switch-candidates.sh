#!/system/bin/sh
# Private files: voltage discovery must not turn a paired FV vote into scalar switches.
execDir=${execDir:-/data/adb/vr25/acc}
W=${TMPDIR_T:-/data/local/tmp}/fv-switches-$$
TMPDIR=$W; mkdir -p "$W/pmic-votable/FV"
trap 'rm -rf "$W"' EXIT
P=0; F=0
check(){ if [ "$1" = "$2" ]; then P=$((P+1)); echo "PASS $3"; else F=$((F+1)); echo "FAIL $3: <$1> expected <$2>"; fi; }
printf '%s\n' 'battery/voltage_max::v000::4400000' '/sys/kernel/debug/pmic-votable/FV/force_val::v000::0' '/sys/kernel/debug/pmic-votable/FV/force_active::1::0' > "$TMPDIR/ch-volt-ctrl-files"
append=$(sed -n '/^[ ]*sed .*3600mV.*ch-volt-ctrl-files/p' "$execDir/read-ch-curr-ctrl-files-p2.sh")
[ -n "$append" ] || exit 2
eval "$append"
check "$(cat "$TMPDIR/ch-switches")" 'battery/voltage_max 4400000 3600mV' 'only the ordinary voltage node becomes a switch'
eval "$(sed -n '/^flip_sw() {/,/^}/p' "$execDir/misc-functions.sh")"
parse_value(){ echo "$1"; }
write(){ local value; eval "value=$1"; echo "$value" > "$2"; }
currFile=$W/current; curThen=$W/previous; echo 1000000 > "$currFile"
for node in force_val force_active; do
 path=$W/pmic-votable/FV/$node; echo 0 > "$path"
 chargingSwitch=("$path" 0 3600mV)
 flip_sw off >/dev/null 2>&1
 check "$(cat "$path")" 0 "cached invalid $node candidate cannot apply a cut"
 echo 3600 > "$path"
 flip_sw on >/dev/null 2>&1
 check "$(cat "$path")" 0 "cached $node candidate can still be released"
done
path=$W/voltage_max; echo 4400000 > "$path"; chargingSwitch=("$path" 4400000 3600mV)
flip_sw off; check "$(cat "$path")" 3600000 'ordinary voltage switch still cuts in microvolts'
flip_sw on; check "$(cat "$path")" 4400000 'ordinary voltage switch still restores'
eval "$(sed -n '/^_write() {/,/^}/p' "$execDir/acc-switch-scan.sh")"
_sw_blacklisted(){ false; }
for node in force_val force_active; do
 path=$W/pmic-votable/FV/$node; echo 0 > "$path"
 _write off "$path 0 3600mV"
 check "$(cat "$path")" 0 "standalone scanner also refuses invalid $node cuts"
 echo 3600 > "$path"; _write on "$path 0 3600mV"
 check "$(cat "$path")" 0 "standalone scanner still releases $node"
done
echo "t-fv-switch-candidates: $P passed, $F failed"
[ "$F" = 0 ]
