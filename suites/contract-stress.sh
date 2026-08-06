#!/system/bin/sh
# contract-stress.sh - try to collapse a negotiated fast-charge contract, the way a user's phone does.
#
#   sh contract-stress.sh          run the stress cycles
#   sh contract-stress.sh watch    just observe, change nothing (safe to leave running)
#
# THE REPORT THIS REPRODUCES
#   A curtana owner: fast charge gone, 4.83V / 5.84W, until a PHYSICAL REPLUG restored 8.66V / 15.3W.
#   That is a QC/HVDCP contract that dropped to 5V and did not come back on its own. The diagnostic
#   bundle could not show what happened around the drop, so the cause stayed a hypothesis.
#
# WHAT IT DOES
#   Cycles a current cap on and off - the operation that makes ACC touch the input nodes and, on the
#   old code, fire USB re-detection - while sampling the negotiated voltage throughout. If ACC can
#   collapse a contract, this is the shape of use that does it.
#
#   Run it under rc21 and then under rc22. rc21 is expected to drop the contract; rc22 is expected to
#   hold it. A result that reads the same under both has demonstrated nothing.
#
# REQUIREMENTS
#   A charger that actually negotiates ABOVE 5V, and a phone that can accept it:
#     Mi A3 (no PD sink)  -> USB-A to USB-C on a QC3 charger. A USB-C to C cable gives 5V only.
#     Pixel 6a (PD sink)  -> USB-C from the Lenovo 90W or the 33W.
#   It refuses to run on a 5V supply, because there is no contract to lose and any verdict would be
#   meaningless.
#
# SAFETY
#   Only `acc -s max_charging_current` is used, the same call the app makes. shutdown_temp is never
#   touched. The cap is cleared on exit through a trap. Stop with TERM, not KILL.

DD=/data/adb/vr25/acc-data; TD=/dev/.vr25/acc; M=/data/adb/vr25/acc
MODE=${1:-stress}
DL=/sdcard/Download; [ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
BUILD=$(sed -n 's/^versionCode=//p' $M/module.prop 2>/dev/null)
OUT=$DL/acc-contract-${BUILD}-$(date +%H%M%S).txt

log(){ echo "$*"; echo "$*" >> "$OUT"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }

G=/sys/class/power_supply/battery
for _c in /sys/class/power_supply/*/capacity; do _d=${_c%/capacity}
  [ -n "$(rd "$_c")" ] && [ -n "$(rd "$_d/status")" ] && { G=$_d; break; }; done

# The supply that carries the negotiated contract. Highest online voltage wins: on a Pixel that is
# the tcpm node, on a Qualcomm phone it is usb, and hardcoding either gets the other one wrong.
SUP=; SUPV=0
for _d in /sys/class/power_supply/*; do
  case "${_d##*/}" in battery|bms|maxfg|*fuelgauge*) continue;; esac
  [ "$(rd $_d/online)" = 1 ] || continue
  _v=$(rd $_d/voltage_now); isnum "$_v" || continue
  [ "$_v" -gt "$SUPV" ] && { SUPV=$_v; SUP=$_d; }
done
[ -n "$SUP" ] || { echo "No online supply with a voltage reading. Plug in a charger."; exit 0; }
vbus(){ rd $SUP/voltage_now; }
icl(){ rd $SUP/current_max; }
styp(){ for _t in real_type usb_type type; do [ -f "$SUP/$_t" ] && { rd $SUP/$_t; return; }; done; }
# The ledger is on tmpfs and does not exist until ACC first writes a node, which after a reboot may
# be minutes away. Reading it must be silent and must answer 0, not an error.
wl(){ [ -f "$TD/.write-ledger" ] || { echo 0; return; }
      _n=$(wc -l < "$TD/.write-ledger" 2>/dev/null); isnum "$_n" && echo "$_n" || echo 0; }

S_MCC=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
cleanup(){ trap - EXIT INT TERM HUP
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  log ""; log "--- restored: mcc=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt) ---"
  log "report: $OUT"; exit 0; }
trap cleanup EXIT INT TERM HUP

log "=== contract stress ==="
log "build   : $BUILD    device: $(getprop ro.product.device)"
log "supply  : ${SUP##*/}  type=$(styp)"
log "start   : vbus $(( $(vbus) / 1000 )) mV, icl $(( $(icl) / 1000 )) mA, batt $(rd $G/current_now) uA, level $(rd $G/capacity)%"
log "screen  : $(dumpsys display 2>/dev/null | grep -o 'mScreenState=[A-Z_]*' | head -1 | cut -d= -f2)"
log ""

V0=$(vbus)
if [ "${V0:-0}" -lt 5500000 ]; then
  log "REFUSING: this supply is at $(( ${V0:-0} / 1000 )) mV, it never went above 5V."
  log "There is no contract to collapse, so any verdict here would be meaningless."
  log ""
  log "  Mi A3    : needs USB-A to USB-C on the QC3 charger (it has no PD sink; C-to-C gives 5V)"
  log "  Pixel 6a : needs USB-C from the Lenovo 90W or the 33W"
  exit 0
fi
log "contract confirmed at $(( V0 / 1000 )) mV - there is something to lose"
log ""

if [ "$MODE" = watch ]; then
  log "watch mode: changing nothing, sampling every 20s. Ctrl-C to stop."
  _n=0
  while [ $_n -lt 180 ]; do
    _n=$((_n + 1)); sleep 20
    log "  $(date '+%H:%M:%S')  vbus $(( $(vbus) / 1000 ))mV  icl $(( $(icl) / 1000 ))mA  batt $(rd $G/current_now)uA  level $(rd $G/capacity)%  $(styp)"
  done
  exit 0
fi

# Judge POWER, not voltage. QC3 and PD both renegotiate between operating points, and a step from
# 7V/2.0A to 5.4V/3.0A is MORE power, not a collapse - but a voltage threshold calls it one. The
# report itself is stated in watts: 5.84W where a replug gave 15.3W. Measured here: rc21 went
# 18.5W -> 2.0W (11% retained) while rc22 went 14.2W -> 11.9W (84%), and a voltage rule would have
# failed both.
I0=$(icl)
P0=$(( (V0 / 1000) * (${I0:-0} / 1000) / 1000000 ))
W0=$(wl)
LOW=0; MIN=$V0
log "stressing: 6 cycles of cap-on / cap-off, sampling vbus throughout"
_c=0
while [ $_c -lt 6 ]; do
  _c=$((_c + 1))
  acc -s max_charging_current=500 >/dev/null 2>&1
  _i=0; while [ $_i -lt 5 ]; do sleep 5; _i=$((_i + 1))
    _v=$(vbus); isnum "$_v" && [ "$_v" -lt "$MIN" ] && MIN=$_v
    isnum "$_v" && [ "$_v" -lt 5500000 ] && LOW=$((LOW + 1)); done
  acc -s max_charging_current= >/dev/null 2>&1
  _i=0; while [ $_i -lt 7 ]; do sleep 5; _i=$((_i + 1))
    _v=$(vbus); isnum "$_v" && [ "$_v" -lt "$MIN" ] && MIN=$_v
    isnum "$_v" && [ "$_v" -lt 5500000 ] && LOW=$((LOW + 1)); done
  log "  cycle $_c: vbus $(( $(vbus) / 1000 ))mV  icl $(( $(icl) / 1000 ))mA  batt $(rd $G/current_now)uA"
done

log ""
log "settling for 90s with nothing configured - a contract that recovers on its own did not collapse"
_i=0; while [ $_i -lt 18 ]; do sleep 5; _i=$((_i + 1)); done
V1=$(vbus)
K=$(tail -n +$(( W0 + 1 )) $TD/.write-ledger 2>/dev/null | grep -c 'rekick .*<- 1' 2>/dev/null || :)
case "${K:-x}" in ''|*[!0-9]*) K=0;; esac
S=$(tail -n +$(( W0 + 1 )) $TD/.write-ledger 2>/dev/null | grep -c 'rekick skipped' 2>/dev/null || :)
case "${S:-x}" in ''|*[!0-9]*) S=0;; esac

log ""
I1=$(icl)
P1=$(( (${V1:-0} / 1000) * (${I1:-0} / 1000) / 1000000 ))
# Percent from milliwatts, so a 12W-to-11W comparison does not lose its resolution to integer watts.
_mw0=$(( (V0 / 1000) * (${I0:-0} / 1000) / 1000 ))
_mw1=$(( (${V1:-0} / 1000) * (${I1:-0} / 1000) / 1000 ))
[ "$_mw0" -gt 0 ] 2>/dev/null && PCT=$(( _mw1 * 100 / _mw0 )) || PCT=0
log "start   : $(( V0 / 1000 )) mV x $(( ${I0:-0} / 1000 )) mA = ${P0} W"
log "final   : $(( ${V1:-0} / 1000 )) mV x $(( ${I1:-0} / 1000 )) mA = ${P1} W   (${PCT}% of start)"
log "lowest v: $(( MIN / 1000 )) mV   ($LOW samples under 5.5V)"
log "battery : $(rd $G/current_now) uA"
log "re-kicks: $K fired, $S skipped-and-logged"
log ""
# 60% of the starting power. A renegotiation between operating points costs a little; a collapse
# costs almost everything - the two measured cases were 84% and 11%, which is not a close call.
if [ "$PCT" -ge 60 ]; then
  log "VERDICT: CONTRACT HELD - ${PCT}% of the starting power retained (${P0}W -> ${P1}W)."
  log "         Voltage may have stepped down; that is renegotiation, not collapse, while the"
  log "         power is still there."
else
  log "VERDICT: CONTRACT COLLAPSED - only ${PCT}% of the starting power retained (${P0}W -> ${P1}W)."
  log "         This is the curtana symptom, which was reported as 5.84W against 15.3W."
  log "         A physical replug should restore it."
fi
