#!/system/bin/sh
# vs-rc21.sh - the five scenarios that MUST behave differently between rc21 and rc22.
#
#   sh vs-rc21.sh            run every scenario the current supply permits
#   sh vs-rc21.sh S1         run one
#
# WHY THIS EXISTS
#   Every other suite here answers "is rc22 correct". This one answers a different question: "does
#   rc22 actually behave differently from the build users are running". A fix that cannot be shown
#   to change behaviour on hardware is a claim, not a fix.
#
#   Run it under rc21 first and rc22 second. Each scenario prints a VERDICT line that is expected to
#   differ. Anything that reads the same under both builds has not been demonstrated.
#
# THE TWO FIELD REPORTS ARE SCENARIOS 1 AND 2
#   S1 is sweet: "charging is not stopped at max temperature".
#   S2 is curtana: "fast charge is gone, stuck at 5V".
#   Both are reproduced from the outside, the way the reporter would see them - no internal state is
#   consulted to decide the verdict, only what the battery and the charger are doing.
#
# SUPPLY REQUIREMENTS - each scenario says what it needs and skips when it is not there.
#   S1 any charger        S2 a charger that negotiates above 5V        S3 any charger
#   S4 any charger        S5 a SLOW charger (a cap must be able to starve the phone)
#
# SAFETY
#   shutdown_temp is never written. Settings restore from a trap. Stop with TERM, never KILL.

DD=/data/adb/vr25/acc-data; TD=/dev/.vr25/acc; M=/data/adb/vr25/acc
WANT=${1:-all}
DL=/sdcard/Download; [ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
BUILD=$(sed -n 's/^versionCode=//p' $M/module.prop 2>/dev/null)
OUT=$DL/acc-vs-rc21-${BUILD}-$(date +%H%M%S).txt

log(){ echo "$*"; echo "$*" >> "$OUT"; }
vd(){ log "  VERDICT $1"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
want(){ [ "$WANT" = all ] || [ "$WANT" = "$1" ]; }

G=/sys/class/power_supply/battery
for _c in /sys/class/power_supply/*/capacity; do _d=${_c%/capacity}
  [ -n "$(rd "$_c")" ] && [ -n "$(rd "$_d/status")" ] && { G=$_d; break; }; done
U=/sys/class/power_supply/usb
lvl(){ rd $G/capacity; }
tmpC(){ _t=$(rd $G/temp); isnum "${_t#-}" && echo $(( _t / 10 )) || echo ""; }
cc(){ rd $G/charge_counter; }
wl(){ _n=$(wc -l < $TD/.write-ledger 2>/dev/null); isnum "$_n" && echo "$_n" || echo 0; }

# Counter-based and adaptive: the current sensor's sign is per-device and flips on some phones, and
# the counter is quantised, so wait for it to actually move rather than dividing by a fixed window.
rate(){
  _a=$(cc); _t0=$(date +%s); _el=0
  while [ $_el -lt 120 ]; do
    sleep 5; _el=$(( _el + 5 )); _b=$(cc)
    case "${_a:-x}${_b:-x}" in *x*) echo ""; return;; esac
    [ "$(( _b - _a ))" -ne 0 ] && { _t1=$(date +%s); _dt=$(( _t1 - _t0 ))
      [ "$_dt" -gt 0 ] 2>/dev/null || _dt=$_el; echo $(( (_b - _a) * 3600 / _dt / 1000 )); return; }
    if [ $_el -ge 25 ]; then
      _im=$(rd $G/current_now); _im=${_im#-}
      isnum "$_im" && [ "$_im" -lt 120000 ] && { echo 0; return; }
    fi
  done
  echo 0
}
vbus(){ _m=0; for _d in /sys/class/power_supply/*; do
    case "${_d##*/}" in battery|bms|maxfg|*fuelgauge*) continue;; esac
    [ "$(rd $_d/online)" = 1 ] || continue
    _v=$(rd $_d/voltage_now); isnum "$_v" && [ "$_v" -gt "$_m" ] && _m=$_v
  done; echo "$_m"; }

# Screen state. It is not a detail: the panel draws 200-500 mA, which on a 500 mA supply is the
# entire budget, so a phone with the screen on can be net-negative with NO limit set at all. Every
# rate below is meaningless without it, and it is the difference between "the cap starved the phone"
# and "the screen did". Read once per call rather than per sample - dumpsys forks.
scr(){
  # mScreenState from `dumpsys display` is the one signal that reads correctly on both test phones.
  # Checked against the alternatives: `Display Power: state=` does not exist on Android 16, and the
  # A3's backlight actual_brightness reads 0 while the screen is genuinely on. mWakefulness is the
  # fallback, but it describes the DEVICE not the panel - a wakelock keeps it Awake with the screen
  # off - so it is only consulted when mScreenState is unavailable.
  _w=$(dumpsys display 2>/dev/null | grep -o 'mScreenState=[A-Z_]*' | head -1 | cut -d= -f2)
  case "${_w:-}" in ON) echo on; return;; OFF|DOZE*) echo off; return;; esac
  _w=$(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -1 | cut -d= -f2)
  case "${_w:-}" in
    Awake) echo on;;
    Asleep|Dozing) echo off;;
    *) for _b in /sys/class/backlight/*/actual_brightness /sys/class/backlight/*/brightness; do
         [ -f "$_b" ] || continue
         _v=$(rd "$_b"); case "${_v:-x}" in ''|*[!0-9]*) continue;; esac
         [ "$_v" -gt 0 ] && { echo on; return; } || { echo off; return; }
       done
       echo unknown;;
  esac
}

S_C=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')
S_T=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
S_R=$(echo $S_C|cut -d' ' -f3); S_P=$(echo $S_C|cut -d' ' -f4)
S_CT=$(echo $S_T|cut -d' ' -f1); S_MT=$(echo $S_T|cut -d' ' -f2); S_RT=$(echo $S_T|cut -d' ' -f3)
restore(){
  acc -s resume_capacity=$S_R pause_capacity=$S_P >/dev/null 2>&1
  acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
  acc -s max_charging_current= >/dev/null 2>&1
  acc -s max_charging_voltage= >/dev/null 2>&1
}
trap 'restore; log ""; log "--- restored ---"; log "report: $OUT"; exit 0' EXIT INT TERM HUP

log "=== ACC change test, rc21 vs rc22 ==="
log "build   : $BUILD"
log "device  : $(getprop ro.product.device)"
log "level   : $(lvl)%   temp $(tmpC)C"
log "supply  : online=$(rd $U/online) icl=$(rd $U/current_max) vbus=$(vbus) type=$(rd $U/real_type)"
SCR=$(scr)
log "screen  : $SCR   (the panel draws 200-500 mA; on a slow supply that is the whole budget)"
log ""

_on=no; for _f in /sys/class/power_supply/*/online; do [ "$(rd "$_f")" = 1 ] && _on=yes; done
[ "$_on" = yes ] || { log "NOT PLUGGED. Every scenario needs a charger. Nothing changed."; exit 0; }
FREE=$(rate)
log "free rate: ${FREE:-?} mA"
log ""

# =================================================================================================
if want S1; then
log "S1. SWEET: does charging stop at max temperature?"
# The report: charging continues above max_temp. Three fixes had to land together - the counter-delta
# verdict, the no-cable rule, and the native thermal pause below the resume level.
_t=$(tmpC)
if ! isnum "${_t#-}" || [ "$_t" -le 12 ] 2>/dev/null; then
  log "  skip - temperature unreadable"
else
  acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
  acc -s cooldown_temp=$(( _t - 3 )) max_temp=$(( _t - 2 )) resume_temp=$(( _t - 5 )) >/dev/null 2>&1
  sleep 45
  _r=$(rate)
  log "  pack ${_t}C, max_temp $(( _t - 2 ))C, level $(lvl)%, rate ${_r:-?} mA"
  if [ "${_r:-9999}" -le 150 ] 2>/dev/null; then
    vd "S1 STOPPED at max_temp (${_r} mA) - the sweet symptom does NOT reproduce"
  else
    vd "S1 STILL CHARGING at ${_r} mA above max_temp - the sweet symptom REPRODUCES"
  fi
  acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
  sleep 20
fi
log ""
fi

# =================================================================================================
if want S2; then
log "S2. CURTANA: does the fast-charge contract survive a cap cycle?"
# The report: fast charge gone, stuck at 5V until a replug. Needs a charger that actually negotiates
# above 5V, or there is no contract to lose and the scenario proves nothing.
_v0=$(vbus)
if [ "${_v0:-0}" -lt 5500000 ]; then
  log "  skip - this charger is at $(( ${_v0:-0} / 1000 )) mV, it never went above 5V."
  log "         Use the QC or PD charger; on 5V there is no contract to collapse."
else
  _i0=$(rd $U/current_max); _w0=$(wl)
  log "  contract before: $(( _v0 / 1000 )) mV, $(( ${_i0:-0} / 1000 )) mA"
  acc -s max_charging_current=800 >/dev/null 2>&1; sleep 40
  acc -s max_charging_current= >/dev/null 2>&1; sleep 60
  _v1=$(vbus); _i1=$(rd $U/current_max)
  _k=$(tail -n +$(( _w0 + 1 )) $TD/.write-ledger 2>/dev/null | grep -c 'rekick .*<- 1' 2>/dev/null || :)
  case "${_k:-x}" in ''|*[!0-9]*) _k=0;; esac
  log "  contract after : $(( ${_v1:-0} / 1000 )) mV, $(( ${_i1:-0} / 1000 )) mA   (re-kicks fired: $_k)"
  if [ "${_v1:-0}" -ge 5500000 ]; then
    vd "S2 CONTRACT HELD at $(( _v1 / 1000 )) mV - the curtana symptom does NOT reproduce"
  else
    vd "S2 CONTRACT COLLAPSED $(( _v0 / 1000 )) -> $(( ${_v1:-0} / 1000 )) mV - curtana REPRODUCES"
  fi
fi
log ""
fi

# =================================================================================================
if want S3; then
log "S3. Does a current cap actually write anything?"
_w0=$(wl)
acc -s max_charging_current=500 >/dev/null 2>&1
sleep 40
_w1=$(wl); _wrote=$(( _w1 - _w0 ))
_capped=$(rate)
log "  ACC wrote $_wrote node lines; rate ${_capped:-?} mA against a free ${FREE:-?} mA"
if [ "$_wrote" -gt 0 ]; then
  vd "S3 CAP WRITES $_wrote nodes - the limit is real"
else
  vd "S3 CAP WROTE NOTHING - accepted in config, never applied"
fi
acc -s max_charging_current= >/dev/null 2>&1; sleep 30
log ""
fi

# =================================================================================================
if want S4; then
log "S4. Does the front end survive losing the interface cache?"
# rc21: acc -i sourced an empty file, left every node path unset, and a read fell through to stdin -
# so it BLOCKED rather than answering. AccA hangs on that.
_p0=$(rd $TD/acc.lock)
: > $TD/.batt-interface.sh
_t0=$(date +%s)
_ans=$(timeout 25 acc -i 2>/dev/null </dev/null | sed -n 's/^status //p' | head -1)
_el=$(( $(date +%s) - _t0 ))
if [ -n "$_ans" ]; then
  vd "S4 acc -i ANSWERED '$_ans' in ${_el}s with the cache gone"
else
  vd "S4 acc -i returned NOTHING (took ${_el}s) - blind, and blocks on some builds"
fi
_h=no; _n=0
while [ $_n -lt 40 ]; do sleep 5; _n=$((_n+1))
  [ -s $TD/.batt-interface.sh ] && grep -q '^battCapacity=' $TD/.batt-interface.sh 2>/dev/null && { _h=yes; break; }
done
_p1=$(rd $TD/acc.lock)
log "  cache healed: $_h after $(( _n * 5 ))s   daemon pid $_p0 -> $_p1"
if [ "$_h" = yes ] && [ "$_p0" = "$_p1" ]; then
  vd "S4 CACHE REPUBLISHED by the running daemon, no restart"
else
  vd "S4 CACHE NOT REPUBLISHED (healed=$_h, restarted=$([ "$_p0" = "$_p1" ] && echo no || echo yes))"
fi
log ""
fi

# =================================================================================================
if want S5; then
log "S5. O1: does a binary limit still hold when a throttle has starved the charge?"
# Needs a SLOW supply. The cap has to be tight enough that the phone consumes more than it draws,
# which is what makes is_charging false and hides both binary limits from the charging branch.
if [ "$(scr)" = on ]; then
  # With the screen on, the PANEL starves the phone, not the cap. The switch might still be held
  # correctly, but the scenario would not have demonstrated what it claims to: O1 is specifically
  # about a THROTTLE hiding the limit from the charging branch.
  log "  skip - the screen is ON. It draws 200-500 mA, so it would be the thing starving the"
  log "         phone rather than the 300 mA cap, and the verdict would not mean what it says."
  log "         Turn the screen off and re-run: sh vs-rc21.sh S5"
elif [ "${FREE:-0}" -gt 900 ] 2>/dev/null; then
  log "  skip - this supply gives ${FREE} mA. Use the SLOW charger (laptop USB-A);"
  log "         on a strong supply a cap cannot starve the phone and O1 cannot arise."
else
  _L=$(lvl)
  acc -s resume_capacity=$(( _L - 3 )) pause_capacity=$(( _L - 1 )) >/dev/null 2>&1
  acc -s max_charging_current=300 >/dev/null 2>&1
  sleep 60
  SW=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
  SWN=$(echo $SW | cut -d' ' -f1); SWOFF=$(echo $SW | cut -d' ' -f3)
  _node=$(rd "$SWN"); _r=$(rate)
  _held=no
  [ "$_node" = "$SWOFF" ] && _held=yes
  case "$SWOFF" in pcap) _l=$(lvl); isnum "$_node" && [ "$_node" -le "$_l" ] 2>/dev/null && _held=yes;; esac
  log "  level $(lvl)% vs pause $(( _L - 1 ))%, cap 300 mA, rate ${_r:-?} mA"
  log "  switch node $SWN = '$_node' (off value '$SWOFF') -> limit held: $_held"
  if [ "$_held" = yes ]; then
    vd "S5 LIMIT HELD by the pause even though a throttle stopped the charge"
  else
    vd "S5 LIMIT NOT HELD - the switch is ON, only the throttle is stopping the charge (O1)"
  fi
  acc -s max_charging_current= >/dev/null 2>&1
  acc -s resume_capacity=$S_R pause_capacity=$S_P >/dev/null 2>&1
fi
log ""
fi
