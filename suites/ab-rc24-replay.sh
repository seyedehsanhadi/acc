#!/system/bin/sh
ROOT=${1:?baseline/candidate parent required}
W=$(mktemp -d /data/local/tmp/ab-replay.XXXXXX) || exit 1
trap 'rm -rf "$W"' EXIT
for arm in a b; do
(
 execDir=$ROOT/acc-$arm/install
 . "$execDir/state-export.sh"
 for fn in current_now current_factor temperature_now status volt_now idle_discharging cc_now; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$execDir/batt-interface.sh")"
 done
 TMPDIR=$W/$arm; dataDir=$TMPDIR; mkdir -p "$TMPDIR/battery" "$TMPDIR/bms"; cd "$TMPDIR"
 currFile=$PWD/battery/current_now; temp=$PWD/battery/temp; voltNow=$PWD/battery/voltage_now
 read_status(){ echo "$kernel"; }
 present(){ return 0; }
 online(){ return 0; }
 emit(){ printf '%s\t%s\t%s\n' "$arm" "$1" "$2"; }
 battStatusWorkaround=false; ampFactor=1000; ampFactor_=1000
 for pair in '895:Charging' '-895:Discharging' '0:Idle' 'garbage:Discharging'; do
  raw=${pair%:*}; kernel=${pair#*:}; echo "$raw" > "$currFile"
  status; rc=$?; emit "status-known-$raw-$kernel" "$_status/rc=$rc"
 done
 ampFactor=; ampFactor_=
 for pair in '0:Discharging' '895:Charging' '-895:Discharging'; do
  raw=${pair%:*}; kernel=${pair#*:}; echo "$raw" > "$currFile"
  status; rc=$?; emit "status-auto-$raw-$kernel" "$_status/rc=$rc"
 done
 if command -v current_factor >/dev/null; then emit cold-auto-factor "$(current_factor)"; else emit cold-auto-factor 1000; fi
 for fn in amp_recheck set_dp; do eval "$(sed -n "/^  $fn() {/,/^  }/p" "$execDir/accd.sh")"; done
 _cache_write(){ :; }
 _srccfg(){ :; }
 sleep(){ :; }
 sdp(){ _DPOL=$1; }
 battStatusWorkaround=true; battStatus=$PWD/battery/status; echo Charging > "$battStatus"
 for pair in '1000:-895' '1000000:-895000'; do
  ampFactor=${pair%:*}; ampFactor_=$ampFactor; _DPOL=-; echo "${pair#*:}" > "$currFile"
  set_dp 2>/dev/null; set +x
  emit "polarity-relatch-$ampFactor" "$_DPOL"
 done
 ampFactor=1000; ampFactor_=1000; echo ampFactor=1000 > "$dataDir/config.txt"; echo 20000 > "$currFile"
 amp_recheck
 emit explicit-factor-after-recheck "$(cat "$dataDir/config.txt")"
 for raw in 250 450 45000; do
  echo "$raw" > "$temp"
  if command -v temperature_now >/dev/null; then result=$(temperature_now); else result=$(cat "$temp"); fi
  emit "temperature-$raw" "$result"
 done
 for raw in 3712937 4200 999 50001; do echo "$raw" > "$voltNow"; emit "voltage-$raw" "$(volt_now)"; done
 ampFactor=1000000; ampFactor_=1000000
 emit watts-5V-895mA "$(_se_charge 5000 895 895000 4000000 Charging 250 50)"
 emit watts-9V-895mA "$(_se_charge 9000 895 895000 4000000 Charging 250 50)"
 for fn in _iin_ma; do eval "$(sed -n "/^$fn() {/,/^}/p" "$execDir/misc-functions.sh")"; done
 mkdir usb
 echo 1800 > usb/input_current_now
 emit input-mA-no-history "$(_iin_ma)"
 printf 0 > usb/input_current_now; emit input-zero-without-newline "$(_iin_ma)"
 echo 2696040 > usb/input_current_now; emit input-uA-learn "$(_iin_ma)"
 echo 5353 > usb/input_current_now; emit input-uA-taper "$(_iin_ma)"
 ampFactor=1000; ampFactor_=1000
 SE_CCCACHE=$TMPDIR/export-counter
 now=$(date +%s); echo "1000000 $((now-10))" > "$SE_CCCACHE"
 emit exporter-counter-reset "$(_se_ccdir 1)"
 echo "1000000 $((now-10))" > "$TMPDIR/.cc_then"
 cc_now(){ echo 1; }
 curNow=895; idleThreshold=10; _DPOL=-; _status=Charging; _kstatus=Charging; curThen=895
 idle_discharging
 emit controller-counter-reset "$_status"
)
(
 AMPS=$ROOT/acc-$arm/amps.sh
 eval "$(grep -E '^(ex|rd|read1|san|abs|sgn)\(\)' "$AMPS")"
 eval "$(sed -n '/^_norm(){/,/^minimize_combo()/{ /^minimize_combo()/!p; }' "$AMPS")"
 PSY=$W/amps-$arm; BATT=$PSY/battery; CURF=$BATT/current_now; HAVE_TO=0; mkdir -p "$BATT" "$PSY/bms"
 echo -895 > "$CURF"; echo -822265 > "$PSY/bms/current_now"; echo 5400000 > "$BATT/constant_charge_current_max"
 log(){ :; }
 RAW=-895; ABSB=895; ST_UNIT=mA
 if command -v node_unit >/dev/null; then
  CUR_UNIT=$(node_unit "$CURF"); RAW=$(rd_current "$CURF"); IDLE=10000; unit=$CUR_UNIT
 else
  eval "$(sed -n '/^UNIT=mA; THR=50/,/^SIGN_UNSTABLE=0/{ /^SIGN_UNSTABLE=0/!p; }' "$AMPS")"; unit=$UNIT
 fi
 printf '%s\tOnePlus-baseline\tunit=%s/result=%s\n' "$arm" "$unit" "$(classify_state 1 1 "$RAW" inverted "$IDLE")"
 for raw in 895000 -895000 0 -1; do printf '%s\tAMPS-known-uA-%s\t%s\n' "$arm" "$raw" "$(classify_state 1 1 "$raw" normal 10000)"; done
)
done
