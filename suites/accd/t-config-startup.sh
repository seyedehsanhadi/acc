#!/system/bin/sh
# Exact startup readers/writers, private files only. No live daemon or sysfs writes.
execDir=${execDir:-/data/adb/vr25/acc}
W=${W:-${TMPDIR_T:-/data/local/tmp}/cfg-startup-$$}
TMPDIR=$W/tmp; dataDir=$W/data; config=$dataDir/config.txt
mkdir -p "$TMPDIR" "$dataDir"
isAccd=true
. "$execDir/cfg-guard.sh"
warn_once_per(){ :; }
getprop(){ echo unknown; }
case $0 in /*) _self=$0;; *) _self=$PWD/$0;; esac
cd "$W" || exit 2

if [ "${1-}" = native ]; then
 . "$execDir/default-config.txt"
 . "$config"
 _cfgSwitchLoaded="${chargingSwitch[*]-}"
 gcsl=/fake/native/charge_stop_level
 eval "$(sed -n '/# A non-empty value alone satisfies the cosmetic goal/,/^      _srccfg/p' "$execDir/accd.sh" | sed '/^      _srccfg/d')"
 exit $?
fi

P=0; F=0
check(){ if [ "$1" = "$2" ]; then P=$((P+1)); echo "PASS $3"; else F=$((F+1)); echo "FAIL $3: <$1> expected <$2>"; fi; }
cp "$execDir/default-config.txt" "$dataDir/.config-good"
sed -i 's/^capacity=.*/capacity=(5 101 80 88 false)/' "$dataDir/.config-good"
printf 'temperature=(\n' > "$config"
cp "$config" "$W/malformed"
( . "$execDir/default-config.txt"; . "$execDir/oem-custom.sh"; cmp -s "$config" "$W/malformed" )
check "$?" 0 'OEM startup preserves malformed user settings'
cp "$W/malformed" "$config"
( . "$execDir/oem-custom.sh"
  for fn in _srcsafe _srcgood _srccfg; do
   eval "$(sed -n "/^  $fn() {/,/^  }/p" "$execDir/accd.sh")"
  done
  _srccfg
  [ "${capacity[3]}" = 88 ] && [ "${_cfgFallback:-0}" = 1 ]
)
check "$?" 0 'startup enforces the last good limit without replacing the broken file'

cp "$execDir/default-config.txt" "$config"
sw_blacklisted(){ [ "$1" = battery/input_suspend ]; }
flip_sw(){ :; }
_srccfg(){ cfg_srcsafe "$config"; }
printf '#!/system/bin/sh\nexit 1\n' > "$TMPDIR/acca"; chmod 755 "$TMPDIR/acca"
eval "$(sed -n '/^  _drop_blocked_sw() {/,/^  }/p' "$execDir/accd.sh")"
sed -i 's|^chargingSwitch=.*|chargingSwitch=(battery/input_suspend 0 1 --)|' "$config"
chargingSwitch=(battery/input_suspend 0 1 --)
_drop_blocked_sw
check "$(sed -n 's/^chargingSwitch=//p' "$config")" '()' 'a blocked switch is cleared through the shared writer'
sed -i 's|^chargingSwitch=.*|chargingSwitch=(battery/charging_enabled 1 0 --)|' "$config"
chargingSwitch=(battery/input_suspend 0 1 --)
_drop_blocked_sw
check "$(sed -n 's/^chargingSwitch=//p' "$config")" '(battery/charging_enabled 1 0 --)' 'blocked-switch cleanup preserves a newer unblocked user choice'
check "${chargingSwitch[*]}" 'battery/charging_enabled 1 0 --' 'the daemon adopts that newer switch in memory'

cp "$execDir/default-config.txt" "$config"
export execDir W
export _self
( exec 0>>"$config.lock"; flock -x 0 || exit 2
  timeout -k 1 15 /system/bin/sh "$_self" native >"$W/native.log" 2>&1 & echo $! > "$W/native.pid"
  sleep 2
  sed -n 's/^chargingSwitch=//p' "$config" > "$W/during-lock"
  sed -i 's/^temperature=.*/temperature=(40 45 20 55)/' "$config"
)
check "$(cat "$W/during-lock")" '()' 'native switch registration waits for the config lock'
n=0
while [ "$n" -lt 60 ] && [ "$(sed -n 's/^chargingSwitch=//p' "$config")" = '()' ]; do sleep 0.1; n=$((n+1)); done
check "$(sed -n 's/^chargingSwitch=//p' "$config")" '(/fake/native/charge_stop_level 100 pcap)' 'native switch registration completes after unlock'
check "$(sed -n 's/^temperature=//p' "$config")" '(40 45 20 55)' 'native registration preserves the concurrent temperature edit'
echo "t-config-startup: $P passed, $F failed"
[ "$F" = 0 ]
