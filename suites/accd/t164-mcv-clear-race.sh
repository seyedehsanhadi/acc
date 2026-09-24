#!/system/bin/sh
# t164 - a stale daemon voltage apply racing a clear must leave a marker the daemon releases.
#
# Reproduced on a Mi A3 (test24-12, 1 run in 5): acca -s mcv= restored 4400000, the daemon wrote its
# stale 4150000 in the same second and touched .volt-custom, then the clear's final rm deleted that
# marker. Config empty + no marker = every later `set_ch_volt -` fast-returns; capped until reboot.
# Fixture replays that order: the restore stub plays the daemon's write + touch.
# Then apply_on_plug: a stale plugged pass (marker gone) must not re-cap the node from memory.
# ARM=<dir holding set-ch-volt.sh + misc-functions.sh> grades another build (test24-12 fails 3).

ID=t164
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM=${ARM:-${execDir:-/data/adb/vr25/acc}}
W=${W:-/data/local/tmp/t164}
[ -f "$ARM/set-ch-volt.sh" ] || { no "no set-ch-volt.sh in $ARM"; fin; }
rm -rf $W; mkdir -p $W/t
echo 'maxChargingVoltage=(4150 battery/voltage_max::4150000::4400000)' > $W/config.txt
echo 4150000 > $W/node

cat > $W/run.sh <<EOF
TMPDIR=$W/t; config=$W/config.txt; dataDir=$W
. $ARM/set-ch-volt.sh
_mcv_unlatch(){ :; }; print_volt_restored(){ :; }
apply_on_boot(){
  if [ "\${1-}" = default ]; then
    echo 4400000 > $W/node
    if [ ! -f $W/raced ]; then : > $W/raced; echo 4150000 > $W/node; : > $W/t/.volt-custom; fi
  fi
}
isAccd=false; set_ch_volt -
echo 'maxChargingVoltage=()' > $W/config.txt
echo "after-clear node=\$(cat $W/node) own=\$([ -f $W/t/.volt-custom ] && echo Y || echo n)"
isAccd=true _accdRelease=true set_ch_volt -
echo "after-release node=\$(cat $W/node)"
EOF
out=$(/system/bin/sh $W/run.sh 2>$W/stderr)
echo "$out" | sed 's/^/    /'

[ -f $W/raced ] && ok "harness: the stale daemon write landed after the restore" || no "harness: race never staged"
echo "$out" | grep -q 'after-clear .* own=Y' && ok "the stale write keeps its ownership marker" || no "the clear deleted the stale write's marker"
echo "$out" | grep -q 'after-release node=4400000' && ok "the daemon's next release restores the node" || no "node left capped with an empty config"
[ ! -s $W/stderr ] && ok "no shell errors" || no "shell errors: $(head -1 $W/stderr)"

MF=$ARM/misc-functions.sh
[ -f "$MF" ] || MF=${execDir:-/data/adb/vr25/acc}/misc-functions.sh
plug(){
  rm -rf $W/t $W/ps; mkdir -p $W/t $W/ps/battery; echo 4400000 > $W/ps/battery/voltage_max
  [ "$1" = own ] && : > $W/t/.volt-custom
  {
    echo "TMPDIR=$W/t; PS=$W/ps"
    echo 'applyOnPlug=(); maxChargingCurrent=(); chargingSwitch=()'
    echo 'maxChargingVoltage=(4150 battery/voltage_max::4150000::4400000)'
    echo 'write(){ _v=$(eval echo $1); echo "$_v" > "$2"; }'
    echo '_wlog(){ :; }'
    sed -n '/^apply_on_plug() {/,/^}/p' "$MF"
    echo 'apply_on_plug value >/dev/null 2>&1'
  } > $W/plug.sh
  /system/bin/sh $W/plug.sh 2>>$W/stderr
  cat $W/ps/battery/voltage_max
}
[ "$(plug own)" = 4150000 ] && ok "an owned voltage cap is still enforced on plug" || no "apply_on_plug stopped enforcing an owned cap"
[ "$(plug stale)" = 4400000 ] && ok "a stale plug pass (marker gone) does not re-cap" || no "a stale plug pass re-capped the node with no marker"
rm -rf $W
fin
