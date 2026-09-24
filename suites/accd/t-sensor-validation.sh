#!/system/bin/sh
execDir=${execDir:-install}
execDir=$(cd "$execDir" && pwd)
. "$execDir/state-export.sh"
for fn in current_now current_factor temperature_now status idle_discharging volt_now cc_now read_status; do
  eval "$(awk -v name="$fn" '$0 ~ "^" name "\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "$execDir/batt-interface.sh")"
done
eval "$(awk '/^  set_dp\(\) \{/,/^  \}/' "$execDir/accd.sh")"
P=0
eqv() { [ "$1" = "$2" ] || { echo "FAIL $3: [$1] != [$2]"; exit 1; }; P=$((P+1)); }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
TMPDIR=$W
dataDir=$W
mkdir -p "$W/battery" "$W/bms" "$W/usb" "$W/wireless"
cd "$W" || exit 1
currFile=battery/current_now
battStatus=battery/status
battCapacity=battery/capacity
voltNow=battery/voltage_now
temp=battery/temp
ACC_PSY=$W
ampFactor=1000
ampFactor_=
# status() only consults the current on the inference path; with the workaround off it answers with
# the kernel word and needs no current at all. This block grades the validation of the reading, so
# it drives the path that actually uses one, and gives read_status something real to read.
echo Charging > "$battStatus"
battStatusWorkaround=true
for value in '' null '-' '+' '1-2' '--1' '1.5' 'x' '99999999999999999999'; do
  _se_int "$value"; eqv "$_senum" null "integer $value"
  printf '%s\n' "$value" > "$currFile"
  eqv "$(current_now)" null "current $value"
  if status; then echo 'FAIL invalid sensor verified as stopped'; exit 1; fi
  eqv "$_status" Unknown "status $value"
done
for value in +00895 00895 895; do
  _se_int "$value"; eqv "$_senum" 895 "$value decimal"
done
_se_int -000895; eqv "$_senum" -895 'negative decimal'
_se_int -000; eqv "$_senum" 0 'negative zero'
for ampFactor in 1000 1000000; do
  _se_ma +008000; expected=8000; [ "$ampFactor" = 1000 ] || expected=8
  eqv "$_sema" "$expected" "battery factor $ampFactor"
done
ampFactor=0; _se_ma 895; eqv "$_sema" null 'zero divisor'
ampFactor=; ampFactor_=
_se_ma 895; eqv "$_sema" null 'ambiguous battery scale'
echo 895 > "$currFile"; echo -895000 > bms/current_now
eqv "$(current_factor)" 1000 'OnePlus paired gauges'
echo 895000 > "$currFile"
eqv "$(current_factor)" 1000000 'microamp gauge'
rm -f "$W/.current-unit"
ampFactor=1000
eqv "$(current_factor)" 1000 'explicit scale wins'
for value in 4200 4200000 +004200000; do
  echo "$value" > "$voltNow"; voltFactor=
  eqv "$(volt_now)" 4200 "voltage $value"
done
for value in '' -4200 '4200oops' 4200000000 4; do
  echo "$value" > "$voltNow"
  eqv "$(volt_now)" 9999 "invalid voltage $value"
done
for spec in '250:10:250' '25000:1000:250' '25:1:250' '-5:1:-50' '+000250:10:250' '25000::250' 'x:10:null' '999999999:1:null'; do
  value=${spec%%:*}; tail=${spec#*:}; tempFactor=${tail%%:*}; expected=${tail#*:}
  echo "$value" > "$temp"
  eqv "$(temperature_now)" "$expected" "temperature $spec"
done
inputAmpFactor=
_se_input_ma 2696040 usb/current_now; eqv "$_sema" 2696 'input learn'
_se_input_ma +005353 usb/current_now; eqv "$_sema" 5 'input taper stays microamps'
_se_input_ma 5353 wireless/current_now; eqv "$_sema" null 'separate sensors'
inputAmpFactor=1000; _se_input_ma -5353 usb/current_now; eqv "$_sema" -5353 'explicit input override'
inputAmpFactor=1000000; _se_input_ma -5353 usb/current_now; eqv "$_sema" -5 'negative microamps'
inputAmpFactor=bad; _se_input_ma 0; eqv "$_sema" null 'invalid input override'
inputAmpFactor=1000000
echo 0 > usb/online; echo 9000000 > usb/voltage_now; echo 3000000 > usb/current_now
echo 1 > wireless/online; echo 5000000 > wireless/voltage_now; echo 500000 > wireless/current_now
eqv "$(_se_input)" '"input":{"voltageMv":5000,"currentMa":500}' 'same active supply'
_se_watts 50000 100000; eqv "$_sew" 5000 'watts without 32-bit overflow'
_se_watts 4040 -1799; eqv "$_sew" 7.267 'signed input magnitude'
eqv "$(_se_class 895 true unknown normal)" unknown 'unknown scale cannot classify'
eqv "$(_se_class 895 true mA unknown)" unknown 'unknown polarity cannot classify'
_srccfg() { :; }
sleep() { :; }
sdp() { printf '%s' "$1" > "$W/polarity"; }
battStatusWorkaround=true
echo Charging > "$battStatus"
ampFactor=1000; _DPOL=+
echo 895 > "$currFile"
set_dp 2>/dev/null; set +x
eqv "$(cat "$W/polarity")" - 'mA polarity correction'
rm -f "$W/polarity"
_DPOL=
echo -invalid > "$currFile"
set_dp 2>/dev/null; set +x
eqv "$([ -f "$W/polarity" ] && echo changed || echo unchanged)" unchanged 'invalid sign is not learned'
for units in mA uA; do
 for polarity in normal inverted unstable; do
  for raw in -895 895; do
   value=$raw; [ "$units" = mA ] || value=$((raw * 1000))
   eqv "$(_se_class "$value" true "$units" "$polarity" rising Charging)" charging "rising $units $polarity $raw"
   eqv "$(_se_class "$value" true "$units" "$polarity" falling Charging)" drain "falling $units $polarity $raw"
   eqv "$(_se_class "$value" false "$units" "$polarity" falling Discharging)" discharging "unplugged $units $polarity $raw"
  done
 done
done
eqv "$(_se_class 895 true mA unstable unknown Unknown)" unknown 'unresolved mode-flipping polarity'
echo "sensor-validation: $P passed"
