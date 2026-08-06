#!/system/bin/sh
# fastcharge-audit.sh - does ACC cost this phone any charging speed when no limit is configured?
#
#   sh fastcharge-audit.sh
#
# THE CLAIM BEING TESTED
#   With nothing configured, ACC must be invisible: the phone should charge exactly as fast as it
#   does with ACC not running at all. Anything less is ACC taxing a user who asked for nothing.
#
# HOW IT IS MEASURED
#   Three phases, back to back so the battery level and temperature barely move:
#     1. ACC running, no caps        - what a user actually gets
#     2. ACC daemon stopped          - what the phone does unmanaged
#     3. ACC running again           - proves phase 1 was not just a cold moment
#
#   Battery current, not the charge counter. The counter is quantised (a Mi A3 steps 28600 uAh) and
#   has been observed frozen for minutes at a time, which would report every phase as 0 mA. Current
#   is live and fine-grained; its sign is per-device, so the magnitude is used and the direction is
#   taken from the level trend.
#
# WHAT IT ALSO RECORDS
#   Every input-current node, before and after, so a phase difference can be attributed to a specific
#   node rather than guessed at. If ACC is costing speed, the node it left low is named.
#
# SAFETY
#   Stops and restarts the daemon; changes no setting. If it is interrupted the daemon is restarted
#   by the trap. Stop with TERM, not KILL.

DD=/data/adb/vr25/acc-data; TD=/dev/.vr25/acc; M=/data/adb/vr25/acc
DL=/sdcard/Download; [ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
OUT=$DL/acc-fastcharge-$(date +%Y%m%d-%H%M%S).txt

log(){ echo "$*"; echo "$*" >> "$OUT"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
abs(){ _a=${1#-}; echo "$_a"; }

G=/sys/class/power_supply/battery
for _c in /sys/class/power_supply/*/capacity; do _d=${_c%/capacity}
  [ -n "$(rd "$_c")" ] && [ -n "$(rd "$_d/status")" ] && { G=$_d; break; }; done
U=/sys/class/power_supply/usb

cleanup(){ trap - EXIT INT TERM HUP
  _p=$(rd $TD/acc.lock)
  [ -n "$_p" ] && [ -d "/proc/$_p" ] || { log ""; log "restarting the daemon"; acc -D restart >/dev/null 2>&1 & sleep 40; }
  log ""; log "daemon: $(rd $TD/acc.lock) $([ -d "/proc/$(rd $TD/acc.lock)" ] && echo alive || echo DOWN)"
  log "report: $OUT"; exit 0; }
trap cleanup EXIT INT TERM HUP

# Average |battery current| over a window. Fast, and unaffected by the counter's quantisation.
mA(){
  _t=0; _n=0; _i=0
  while [ $_i -lt 12 ]; do
    _i=$((_i + 1)); sleep 5
    _c=$(rd $G/current_now); isnum "$(abs "$_c")" || continue
    _t=$(( _t + $(abs "$_c") )); _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] && echo $(( _t / _n / 1000 )) || echo ""
}

nodes(){
  for _n in $U/current_max $U/input_current_settled /sys/class/power_supply/main/current_max \
            /sys/class/power_supply/main/constant_charge_current_max \
            $G/constant_charge_current_max $G/constant_charge_current \
            /sys/class/qcom-battery/restrict_cur /sys/class/qcom-battery/restrict_chg \
            /sys/class/power_supply/main-charger/current_max; do
    [ -f "$_n" ] && printf '      %-56s %s\n' "${_n#/sys/class/}" "$(rd $_n)"
  done
}

log "=== fast-charge audit: is ACC costing this phone anything? ==="
log "build   : $(sed -n 's/^versionCode=//p' $M/module.prop)   device: $(getprop ro.product.device)"
log "supply  : type=$(rd $U/real_type)  vbus=$(rd $U/voltage_now)  icl=$(rd $U/current_max)"
log "config  : mcc=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt) mcv=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt)"
log "level   : $(rd $G/capacity)%   temp $(( $(rd $G/temp) / 10 ))C"
log "screen  : $(dumpsys display 2>/dev/null | grep -o 'mScreenState=[A-Z_]*' | head -1 | cut -d= -f2)"
log ""

[ "$(rd $U/online)" = 1 ] || { log "NOT PLUGGED. Nothing to measure."; exit 0; }

_mcc=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
_mcv=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
if [ -n "$_mcc" ] || [ -n "$_mcv" ]; then
  log "A limit IS configured (current='$_mcc' voltage='$_mcv')."
  log "This audit only means something with nothing configured - clear them and re-run."
  exit 0
fi

log "PHASE 1 - ACC running, nothing configured"
log "$(nodes)"
P1=$(mA)
L1=$(rd $G/capacity)
log "      battery draw: ${P1:-?} mA   level ${L1}%"
log ""

log "PHASE 2 - ACC daemon STOPPED (what the phone does unmanaged)"
acc -D stop >/dev/null 2>&1
sleep 25
log "$(nodes)"
P2=$(mA)
L2=$(rd $G/capacity)
log "      battery draw: ${P2:-?} mA   level ${L2}%"
log ""

log "PHASE 3 - ACC running again (proves phase 1 was not a cold moment)"
acc -D restart >/dev/null 2>&1 &
sleep 45
log "$(nodes)"
P3=$(mA)
L3=$(rd $G/capacity)
log "      battery draw: ${P3:-?} mA   level ${L3}%"
log ""

log "=========================================================="
log "  ACC running   : ${P1:-?} mA   (and again: ${P3:-?} mA)"
log "  ACC stopped   : ${P2:-?} mA"
log "  level moved   : ${L1}% -> ${L3}%   (a big rise means the phases are not comparable)"
log ""
if isnum "$P1" && isnum "$P2" && isnum "$P3"; then
  _run=$(( (P1 + P3) / 2 ))
  _d=$(( _run - P2 ))
  _pct=0; [ "$P2" -gt 0 ] && _pct=$(( _d * 100 / P2 ))
  log "  ACC running averages ${_run} mA against ${P2} mA unmanaged: ${_d} mA (${_pct}%)"
  log ""
  # Charging current varies on its own with level, temperature and the charger's own stepping, so a
  # small difference is noise rather than a tax. A phone being throttled by software shows a large,
  # one-directional gap - the measured curtana-class case was 3010 mA against 310 mA.
  if [ "$_d" -lt -150 ]; then
    log "  VERDICT: ACC IS COSTING THIS PHONE $(( -_d )) mA with nothing configured."
    log "           Compare the node tables above - whichever one is lower in phases 1 and 3 than in"
    log "           phase 2 is the one ACC is holding down."
  elif [ "$_d" -gt 150 ]; then
    log "  VERDICT: ACC is charging FASTER than unmanaged by ${_d} mA. Not a fault, but worth"
    log "           understanding - usually ACC released a node the vendor had left low."
  else
    log "  VERDICT: NO COST. ACC is within ${_d} mA of unmanaged, which is ordinary variation."
    log "           With nothing configured, ACC is invisible to charging speed on this phone."
  fi
else
  log "  VERDICT: could not measure one of the phases; no claim made."
fi
