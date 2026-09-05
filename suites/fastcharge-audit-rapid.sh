#!/system/bin/sh
# Rapid ACC/on-off-on charging-speed audit. Test code only.

set +e
M=/data/adb/vr25/acc
DD=/data/adb/vr25/acc-data
TD=/dev/.vr25/acc
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
OUT=/sdcard/Download/acc-fastcharge-rapid-$(date +%Y%m%d-%H%M%S).txt
[ -w /sdcard/Download ] || OUT=/data/local/tmp/acc-fastcharge-rapid-$(date +%Y%m%d-%H%M%S).txt

log(){ echo "$*"; echo "$*" >> "$OUT"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
num(){ case "${1:-x}" in ''|*[!0-9-]*) return 1;; esac; }
daemon(){ _p=$(rd "$TD/acc.lock"); [ -n "$_p" ] && [ -d "/proc/$_p" ]; }
wait_daemon(){ _i=0; while [ "$_i" -lt 30 ]; do daemon && return 0; sleep 2; _i=$((_i+1)); done; return 1; }

had_hot=0; old_hot=0
[ -f "$TD/.nthot" ] && { had_hot=1; old_hot=$(rd "$TD/.nthot"); }

cleanup(){
  trap - EXIT HUP INT TERM
  acc -D stop >/dev/null 2>&1
  if [ "$had_hot" = 1 ]; then printf '%s' "$old_hot" > "$TD/.nthot"; else rm -f "$TD/.nthot"; fi
  acc -D restart >/dev/null 2>&1 &
  wait_daemon; sleep 5
  log "restore : nthot=$(rd "$TD/.nthot") daemon=$([ -n "$(rd "$TD/acc.lock")" ] && echo alive || echo DOWN) status=$(rd "$B/status")"
  log "report  : $OUT"
}
trap cleanup EXIT HUP INT TERM

sample(){
  _sum=0; _n=0; _lo=999999999; _hi=0; _i=0
  while [ "$_i" -lt 10 ]; do
    sleep 2; _raw=$(rd "$B/current_now"); _raw=${_raw#-}; _i=$((_i+1))
    num "$_raw" || continue
    _ma=$((_raw / 1000)); _sum=$((_sum + _ma)); _n=$((_n + 1))
    [ "$_ma" -lt "$_lo" ] && _lo=$_ma; [ "$_ma" -gt "$_hi" ] && _hi=$_ma
  done
  if [ "$_n" -ge 5 ]; then echo $(((_sum - _lo - _hi) / (_n - 2))); elif [ "$_n" -gt 0 ]; then echo $((_sum / _n)); else echo 0; fi
}

phase(){
  _name=$1; _t0=$(rd "$B/temp"); _v0=$(rd "$U/voltage_now"); _c0=$(rd "$U/current_max")
  _ma=$(sample); _t1=$(rd "$B/temp"); _st=$(rd "$B/status")
  log "$_name: ${_ma}mA temp=${_t0}->${_t1} vbus=$_v0 icl=$_c0 status=$_st"
  echo "$_ma"
}

log "=== rapid fast-charge audit ==="
log "build   : $(sed -n 's/^versionCode=//p' "$M/module.prop") device=$(getprop ro.product.device)"
log "supply  : $(rd "$U/real_type") vbus=$(rd "$U/voltage_now") icl=$(rd "$U/current_max")"
log "start   : temp=$(rd "$B/temp") status=$(rd "$B/status") nthot=$old_hot"
wait_daemon || { log "ABORT: daemon is not running"; exit 1; }

_mcc=$(sed -n 's/^maxChargingCurrent=(//p' "$DD/config.txt" | head -1); _mcc=${_mcc%)}
_mcv=$(sed -n 's/^maxChargingVoltage=(//p' "$DD/config.txt" | head -1); _mcv=${_mcv%)}
[ -z "$_mcc$_mcv" ] || { log "ABORT: current/voltage cap configured"; exit 1; }
[ "$(rd "$U/present")" = 1 ] || { log "ABORT: charger not present"; exit 1; }

# A latched hold may be cleared only when the pack is already below max_temp.
if [ "$old_hot" = 1 ]; then
  _temp=$(rd "$B/temp"); _max=$(sed -n 's/^temperature=(//p' "$DD/config.txt" | awk '{print $2}'); _max=${_max%)}
  num "$_temp" && num "$_max" && [ "$_temp" -lt $((_max * 10)) ] || { log "ABORT: unsafe to clear thermal latch"; exit 1; }
  log "control : temporarily clearing nthot below max_temp (${_temp} < $((_max * 10)))"
  acc -D stop >/dev/null 2>&1; rm -f "$TD/.nthot"; acc -D restart >/dev/null 2>&1 &
  wait_daemon; sleep 5
fi

input keyevent 223 >/dev/null 2>&1
sleep 30
P1=$(phase ACC-1 | tail -1)
acc -D stop >/dev/null 2>&1; sleep 12
P2=$(phase OFF | tail -1)
acc -D restart >/dev/null 2>&1 &
wait_daemon; sleep 10
P3=$(phase ACC-2 | tail -1)

run=$(((P1 + P3) / 2)); delta=$((run - P2)); spread=$((P1 > P3 ? P1 - P3 : P3 - P1))
log "result  : ACC=${run}mA unmanaged=${P2}mA delta=${delta}mA spread=${spread}mA"
endtemp=$(rd "$B/temp"); maxtemp=$(sed -n 's/^temperature=(//p' "$DD/config.txt" | awk '{print $2}'); maxtemp=${maxtemp%)}
if num "$endtemp" && num "$maxtemp" && [ "$endtemp" -ge $((maxtemp * 10)) ]; then
  log "VERDICT : INCONCLUSIVE (pack reached max_temp during the comparison)"
elif [ "$run" -gt 0 ] && [ $((spread * 100 / run)) -gt 20 ]; then
  log "VERDICT : INCONCLUSIVE (ACC phases differ by more than 20%)"
elif [ "$delta" -lt -200 ]; then
  log "VERDICT : ACC COSTS $((-delta))mA"
else
  log "VERDICT : NO MATERIAL COST"
fi
