#!/system/bin/sh
# Execute the real CLI setter and writer against private config files; hardware calls are recorded.
execDir=${execDir:-/data/adb/vr25/acc}
W=${TMPDIR_T:-/data/local/tmp}/setting-aliases-$$
mkdir -p "$W/tmp" "$W/data"
TMPDIR=$W/tmp; dataDir=$W/data; config=$dataDir/config.txt
defaultConfig=$execDir/default-config.txt
isAccd=false
. "$execDir/cfg-guard.sh"
. "$execDir/set-prop.sh"
srccfg_try(){ . "$1"; }
daemon_ctrl(){ return 9; }
set_ch_curr(){
  echo "current $1" >> "$W/calls"
  [ "$1" != 99999 ] || return 11
  maxChargingCurrent=("$1" battery/current_max::900000::3000000); unset mcc max_charging_current
}
set_ch_volt(){ echo "voltage $1" >> "$W/calls"; maxChargingVoltage=("$1" battery/voltage_max::4000000::4400000); unset mcv max_charging_voltage; }
set_temp_level(){ echo "level $1" >> "$W/calls"; tempLevel=$1; tl=$1; }
P=0; F=0
check(){ if [ "$1" = "$2" ]; then P=$((P+1)); echo "PASS $3"; else F=$((F+1)); echo "FAIL $3: <$1> expected <$2>"; fi; }
for pair in maxChargingCurrent=900 maxChargingVoltage=4000 tempLevel=25 max_charging_current=900 max_charging_voltage=4000; do
  cp "$defaultConfig" "$config"; : > "$W/calls"
  ( set_prop "$pair" ) > "$W/output" 2>&1
  rc=$?
  case $pair in
    maxChargingCurrent=*|max_charging_current=*) expected='current 900';;
    maxChargingVoltage=*|max_charging_voltage=*) expected='voltage 4000';;
    tempLevel=*) expected='level 25';;
  esac
  check "$rc" 0 "$pair succeeds"
  check "$(cat "$W/calls")" "$expected" "$pair reaches its hardware setter"
  case $pair in
    *Current=*|*_current=*) check "$(sed -n 's/^maxChargingCurrent=//p' "$config")" '(900 battery/current_max::900000::3000000)' "$pair preserves the applied nodes";;
    *Voltage=*|*_voltage=*) check "$(sed -n 's/^maxChargingVoltage=//p' "$config")" '(4000 battery/voltage_max::4000000::4400000)' "$pair preserves the applied nodes";;
  esac
done
cp "$defaultConfig" "$config"; : > "$W/calls"
( set_prop mcc=99999 ) > "$W/refused" 2>&1
rc=$?
check "$rc" 11 'a refused current setting returns failure'
check "$(sed -n 's/^maxChargingCurrent=//p' "$config")" '()' 'a refused current setting is not saved'
echo "t-setting-aliases: $P passed, $F failed"
[ "$F" = 0 ]
