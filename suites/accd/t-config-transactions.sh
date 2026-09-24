#!/system/bin/sh
# Real writers, private files, deterministic scheduling. No live configuration or sysfs writes.
execDir=${execDir:-/data/adb/vr25/acc}
W=${W:-${TMPDIR_T:-/data/local/tmp}/cfg-transactions-$$}
TMPDIR=$W/tmp; dataDir=$W/data; config=$dataDir/config.txt
mkdir -p "$TMPDIR" "$dataDir"
isAccd=true

case ${1-} in
  writer)
    . "$execDir/default-config.txt"
    . "$config"
    _cfgSwitchLoaded="${chargingSwitch[*]-}"
    if [ "$2" = daemon ]; then
      chargingSwitch=(battery/input_suspend 0 1)
      mv() {
        if [ "$3" = "$config" ]; then
          : > "$W/ready"
          while [ ! -f "$W/release" ]; do sleep 0.05; done
        fi
        command mv "$@"
      }
      . "$execDir/write-config.sh" own:s
    elif [ "$2" = wake ]; then
      isAccd=false
      pgrep(){ return 0; }
      language=de
      . "$execDir/write-config.sh" set:language
    else
      ct=40; mt=45; rt=20
      . "$execDir/write-config.sh" set:ct,mt,rt
    fi
    result=$?
    : > "$W/$2-done"
    exit "$result"
  ;;
esac

P=0; F=0
ok(){ P=$((P+1)); echo "PASS $*"; }
no(){ F=$((F+1)); echo "FAIL $*"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else no "$3: got <$1>, expected <$2>"; fi; }
value(){ sed -n "s/^$1=//p" "$config"; }
reset(){ cp "$execDir/default-config.txt" "$config"; }
save(){ ( . "$execDir/default-config.txt"; sed '/^[[:space:]]*:/d' "$config" > "$W/load"; . "$W/load"; eval "$2"; . "$execDir/write-config.sh" "$1" ); }

reset
export execDir W
timeout 20 /system/bin/sh "$0" writer daemon > "$W/daemon.log" 2>&1 & daemon=$!
n=0
while [ ! -f "$W/ready" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n+1)); done
if [ -f "$W/ready" ]; then
  timeout 20 /system/bin/sh "$0" writer user > "$W/user.log" 2>&1 & user=$!
  n=0
  while [ ! -f "$W/user-done" ] && [ "$n" -lt 40 ]; do sleep 0.05; n=$((n+1)); done
  : > "$W/release"
  wait "$daemon"; d=$?
  wait "$user"; u=$?
  check "$d/$u" 0/0 'both overlapping writes complete'
  check "$(value temperature)" '(40 45 20 55)' 'overlap preserves the user temperature'
  check "$(value chargingSwitch)" '(battery/input_suspend 0 1)' 'overlap preserves the daemon switch'
else
  no 'daemon did not reach publish'
  : > "$W/release"; wait "$daemon"
fi

reset
save set:ct,mt,rt 'ct=40; mt=45; rt=20'
save set:pc,rc 'temperature=(29 34 24 55); pc=66; rc=61'
check "$(value temperature)" '(40 45 20 55)' 'a stale CLI snapshot preserves unrelated settings'
check "$(value capacity)" '(5 101 61 66 false)' 'requested capacity still lands'
save set:language,battStatusWorkaround "language=de; battStatusWorkaround=false"
check "$(value language)/$(value battStatusWorkaround)" de/false 'canonical scalar keys survive rebasing'
literal="don't execute \$(false)"
save set:rcp 'rcp=$literal'
check "$(. "$config"; printf '%s' "$runCmdOnPause")" "$literal" 'quotes and substitutions remain literal'

reset
save set:mcc 'mcc=1500'
save own:mcc 'maxChargingCurrent=(900 battery/current_max::900000::3000000)'
check "$(value maxChargingCurrent)" '(1500)' 'daemon expansion cannot resurrect an older current cap'
save set:mcc 'mcc='
save own:mcc 'maxChargingCurrent=(900 battery/current_max::900000::3000000)'
check "$(value maxChargingCurrent)" '()' 'daemon expansion cannot undo a cleared current cap'
save set:mcv 'mcv=4100'
save own:mcv 'maxChargingVoltage=(4000 battery/voltage_max::4000000::4400000)'
check "$(value maxChargingVoltage)" '(4100)' 'daemon expansion cannot undo a newer voltage cap'
save set:s 's="battery/charging_enabled 1 0 --"'
save own:s '_cfgSwitchLoaded=""; chargingSwitch=(battery/input_suspend 0 1)'
check "$(value chargingSwitch)" '(battery/charging_enabled 1 0 --)' 'daemon selection cannot overwrite a later switch edit'

reset
save set:pc,rc,mcc 'pc=88; rc=80; mcc=900'
save own:mcc 'pause_capacity=66; resume_capacity=61; pc=66; rc=61; maxChargingCurrent=(900 battery/current_max::900000::3000000)'
check "$(value capacity)" '(5 101 80 88 false)' 'daemon pause aliases cannot overwrite newer capacity settings'
save set:s 's="battery/charging_enabled 1 0 --"'
save own:s '_cfgSwitchLoaded=""; charging_switch=""; chargingSwitch=(battery/input_suspend 0 1)'
check "$(value chargingSwitch)" '(battery/charging_enabled 1 0 --)' 'daemon clear alias cannot override a newer user switch'

reset
save set:mcc 'mcc=900'
save own:mcc 'maxChargingCurrent=(900 battery/current_max::900000::3000000)'
check "$(value maxChargingCurrent)" '(900 battery/current_max::900000::3000000)' 'matching current intent still expands'
printf ':; touch %s/EXECUTED\n' "$W" >> "$config"
save set:language 'language=de'
[ ! -e "$W/EXECUTED" ] && ok 'saving does not execute scheduled commands' || no 'saving executed a scheduled command'

reset
: > "$dataDir/.user-locked"
rm -f "$dataDir/.rediscover"
cp "$config" "$W/private.txt"
( isAccd=false; config=$W/private.txt; save set:s 's=""' )
[ -f "$dataDir/.user-locked" ] && [ ! -f "$dataDir/.rediscover" ] && ok 'private config leaves installed discovery markers alone' || no 'private config changed installed discovery markers'
( isAccd=false; save set:s 's=""' )
[ ! -f "$dataDir/.user-locked" ] && [ -f "$dataDir/.rediscover" ] && ok 'installed config still requests rediscovery' || no 'installed config lost rediscovery'
rm -f "$dataDir/.rediscover"
: > "$dataDir/.user-locked"
ln -sf "$config" "$W/alias.txt"
( isAccd=false; config=$W/alias.txt; save set:s 's=""' )
[ ! -f "$dataDir/.user-locked" ] && [ -f "$dataDir/.rediscover" ] && ok 'installed config alias keeps marker semantics' || no 'config alias lost rediscovery'

reset
mkfifo "$TMPDIR/.wake" || exit 2
timeout -k 1 4 /system/bin/sh "$0" writer wake > "$W/wake.log" 2>&1
check "$?" 0 'a vanished FIFO reader cannot hang a successful config write'
# Release a surviving old-code writer before removing its private FIFO.
timeout -k 1 1 cat "$TMPDIR/.wake" >/dev/null 2>&1 || :
rm -f "$TMPDIR/.wake"

printf 'temperature=(\n' > "$config"
cp "$config" "$W/malformed"
( . "$execDir/default-config.txt"; language=de; . "$execDir/write-config.sh" set:language ) >/dev/null 2>&1
[ $? != 0 ] && cmp -s "$config" "$W/malformed" && ok 'malformed config is refused without replacement' || no 'malformed config was replaced'

echo "t-config-transactions: $P passed, $F failed"
[ "$F" = 0 ]
