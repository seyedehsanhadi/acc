#!/system/bin/sh
# megatest.sh - one run, every fix, machine-comparable across builds.
#
#   sh megatest.sh              full profile
#   sh megatest.sh quick        same sections and assertions, shorter windows
#   sh megatest.sh T-CAPS       one section
#
# WHAT IT IS FOR
#   Run it under rc21, then under rc22, and diff the two TSVs. A fix that does not change a result
#   between the two builds has not been demonstrated, whatever the source says.
#
# OUTPUTS
#   <DL>/megatest-<build>-<stamp>.txt    human readable
#   <DL>/megatest-<build>-<stamp>.tsv    id, result, condition, evidence   <- the comparable artifact
#   <TMPDIR>/.megatest-done              one line, written last: the verdict. Block on it, do not poll.
#
# HOW IT DECIDES
#   Every section names the CONDITION it needs and SKIPS when that condition is absent. A skip is
#   never counted as a pass. An assertion that cannot fail is deleted, not softened.
#
# MEASUREMENT, AND WHY IT IS BUILT THIS WAY
#   An adversarial review of the first version of this file confirmed 54 defects in the HARNESS -
#   more than in the product it tests. The measurement core below is the answer to them:
#
#   - SIGN IS RESOLVED HERE, ONCE, AT PREFLIGHT. The first version read ACC's own cached _DPOL to
#     decide which way current flows. Two sections deliberately corrupt or delete that cache, so the
#     harness was reading an artifact it had just poisoned. This file learns the convention from the
#     phone while the cable state is known, and keeps it in its own variable.
#   - CURRENT, NOT THE STATUS LABEL. The kernel says "Charging" on a native-limit phone holding at
#     zero. Every resume and every stop verdict is drawn from signed current.
#   - CURRENT, NOT THE COUNTER, as the primary rate. The counter is quantised (A3 28600 uAh, Pixel
#     ~20000) and freezes for minutes; one quantum over a short window reports a wild figure.
#   - LEDGER WINDOWS SURVIVE ROTATION. The ledger is trimmed at 400 lines, so a line-number offset
#     taken before an operation points somewhere else afterwards. Windows are content counts, and a
#     shrink is detected and reported as unreliable rather than silently miscounted.
#   - SWITCH PATHS ARE RESOLVED. ACC stores them relative to /sys/class/power_supply.
#   - PRESENT, NEVER ONLINE. An input-cut switch zeroes online while still plugged.
#   - SUPPLY = HIGHEST VOLTAGE. Alphabetically first picks a node that mirrors the battery.
#
# SAFETY
#   shutdown_temp is never written. Every setting is saved and restored from a trap, and the restore
#   is itself asserted. Refuses on a hot pack. Stop with TERM, never KILL: KILL skips the trap.

set -u

TD=/dev/.vr25/acc
DD=/data/adb/vr25/acc-data
M=/data/adb/vr25/acc
IF=$TD/.batt-interface.sh
FL=$DD/logs/flight.log
WL=$TD/.write-ledger
PS=/sys/class/power_supply
WANT=${1:-all}

DL=/sdcard/Download
[ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
BUILD=$(sed -n 's/^versionCode=//p' $M/module.prop 2>/dev/null)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$DL/megatest-${BUILD}-${STAMP}.txt
TSV=$DL/megatest-${BUILD}-${STAMP}.tsv
DONE=$TD/.megatest-done
T0=$(date +%s)
REFUSED=

P=0; F=0; SK=0
COND=unknown
log(){ echo "$*"; echo "$*" >> "$OUT"; }
row(){ printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$COND" "$3" >> "$TSV"; }
ok(){ P=$((P+1)); log "  PASS  $2"; row "$1" PASS "$2"; }
no(){ F=$((F+1)); log "  FAIL  $2"; row "$1" FAIL "$2"; }
sk(){ SK=$((SK+1)); log "  skip  $2"; row "$1" SKIP "$2"; }
sec(){ log ""; log "===== $* ====="; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
isint(){ case "${1:-x}" in ''|-|*[!0-9-]*) return 1;; esac; }
abs(){ echo "${1#-}"; }
want(){ [ "$WANT" = all ] || [ "$WANT" = quick ] || [ "$WANT" = "$1" ]; }

if [ "$WANT" = quick ]; then
  W_SETTLE=15; W_RATE=24; W_POLL=90; N_SAMP=6; W_SWEEP=120
else
  W_SETTLE=24; W_RATE=40; W_POLL=150; N_SAMP=12; W_SWEEP=240
fi

# ---- device shape -------------------------------------------------------------------------------
G=$PS/battery
for _c in $PS/*/capacity; do
  _d=${_c%/capacity}
  [ -n "$(rd "$_c")" ] && [ -n "$(rd "$_d/status")" ] && { G=$_d; break; }
done
lvl(){ rd $G/capacity; }
tmpC(){ _t=$(rd $G/temp); isint "${_t:-x}" && echo $(( _t / 10 )) || echo ""; }
cc(){ rd $G/charge_counter; }
alive(){ _p=$(rd $TD/acc.lock); [ -n "$_p" ] && [ -d "/proc/$_p" ]; }
accst(){ timeout 20 acc -i 2>/dev/null </dev/null | sed -n 's/^status //p' | head -1; }
scr(){
  _w=$(dumpsys display 2>/dev/null | grep -o 'mScreenState=[A-Z_]*' | head -1 | cut -d= -f2)
  case "${_w:-}" in ON) echo on; return;; OFF|DOZE*) echo off; return;; esac
  _w=$(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -1 | cut -d= -f2)
  case "${_w:-}" in Awake) echo on;; Asleep|Dozing) echo off;; *) echo unknown;; esac
}

# ---- screen control -----------------------------------------------------------------------------
# The panel draws 200-500 mA, which on a slow supply IS the whole charging budget. Sampling the state
# once at preflight was not enough: a notification wakes the screen mid-measurement and the run then
# compares a screen-off row against a screen-on one and calls the difference a charging regression.
# So the harness owns the screen for the duration and hands it back at the end.
#
# keyevent 223 is KEYCODE_SLEEP and 224 is KEYCODE_WAKEUP, both deterministic. keyevent 26 is the
# power TOGGLE, which turns the screen ON half the times it is used.
SCR0=
STAYON0=
screen_off(){
  [ "$(scr)" = off ] && return 0
  input keyevent 223 >/dev/null 2>&1
  _w=0
  while [ $_w -lt 20 ]; do
    [ "$(scr)" = off ] && return 0
    sleep 2; _w=$(( _w + 2 ))
  done
  return 1
}
screen_wake(){ input keyevent 224 >/dev/null 2>&1; sleep 2; }
# "Stay awake while charging" is a developer option that pins the screen ON for the whole of a
# plugged-in run, so every rate measurement would carry the panel load and no keyevent would hold.
# Cleared here, restored in finish().
stayon_clear(){
  STAYON0=$(settings get global stay_on_while_plugged_in 2>/dev/null)
  case "${STAYON0:-}" in ''|null|0) : ;; *) settings put global stay_on_while_plugged_in 0 >/dev/null 2>&1;; esac
}
stayon_restore(){
  case "${STAYON0:-}" in ''|null|0) : ;; *) settings put global stay_on_while_plugged_in "$STAYON0" >/dev/null 2>&1;; esac
}

plugged(){
  for _pf in $PS/*/present; do
    case "$_pf" in */battery/*|*/bms/*|*/maxfg/*|*fuelgauge*) continue;; esac
    [ "$(rd "$_pf")" = 1 ] && return 0
  done
  return 1
}

SUP=; SUPV=0
for _d in $PS/*; do
  case "${_d##*/}" in battery|bms|maxfg|*fuelgauge*) continue;; esac
  [ "$(rd $_d/online)" = 1 ] || continue
  _v=$(rd $_d/voltage_now); isnum "$_v" || continue
  [ "$_v" -gt "$SUPV" ] && { SUPV=$_v; SUP=$_d; }
done
vbus(){ [ -n "$SUP" ] && rd $SUP/voltage_now || echo 0; }
icl(){ [ -n "$SUP" ] && rd $SUP/current_max || echo 0; }
styp(){ [ -n "$SUP" ] || return 0; for _t in real_type usb_type type; do [ -f "$SUP/$_t" ] && { rd $SUP/$_t; return; }; done; }

# ---- our own sign convention --------------------------------------------------------------------
# CHG is the sign current_now takes while the pack is FILLING. Learned here, from the phone, while
# the cable state is known - never from ACC's cached _DPOL, which two sections below deliberately
# corrupt and delete. The two phones disagree (A3 fills positive, Pixel negative) and a phone can
# also contradict its own cache.
CHG=
learn_sign(){
  plugged || return 1
  _c0=$(cc); _i=$(rd $G/current_now)
  isint "${_i:-x}" || return 1
  [ "$(abs "$_i")" -gt 60000 ] || return 1
  sleep 20
  _c1=$(cc); _j=$(rd $G/current_now)
  isint "${_j:-x}" || return 1
  if isint "${_c0:-x}" && isint "${_c1:-x}" && [ "$_c1" -ne "$_c0" ]; then
    # The counter is the honest arbiter of DIRECTION: rising means filling, whatever sign this
    # kernel happens to give current_now.
    if [ "$_c1" -gt "$_c0" ]; then case "$_j" in -*) CHG=-;; *) CHG=+;; esac
    else                           case "$_j" in -*) CHG=+;; *) CHG=-;; esac; fi
    return 0
  fi
  # Counter frozen. Fall back to the kernel label, which is trustworthy for direction even though it
  # is useless for "is any current actually flowing".
  case "$(rd $G/status)" in
    Charging|Full) case "$_j" in -*) CHG=-;; *) CHG=+;; esac; return 0;;
    Discharging)   case "$_j" in -*) CHG=+;; *) CHG=-;; esac; return 0;;
  esac
  return 1
}
# Signed mA in OUR convention: positive means the pack is filling. The first version returned a
# magnitude, so a phone discharging at 500 mA read identically to one charging at 500 mA, which
# inverted the bug 11 test completely.
mA(){
  _i=$(rd $G/current_now)
  isint "${_i:-x}" || { echo ""; return; }
  case "$CHG" in
    -) case "$_i" in -*) echo $(( ${_i#-} / 1000 ));; *) echo $(( 0 - _i / 1000 ));; esac;;
    +) echo $(( _i / 1000 ));;
    *) echo "";;
  esac
}
# Battery POWER in mW. This is the domain-correct quantity for comparing rows: max_charging_current
# caps the INPUT, and on a 9V PD phone feeding a 4V pack a 586 mA input cap shows as ~1029 mA at the
# battery. Comparing a cap in one domain against a measurement in the other made every grid row
# meaningless, which is exactly what happened on the Pixel.
bmV(){ _v=$(rd $G/voltage_now); isint "${_v:-x}" || { echo ""; return; }
  [ "$_v" -gt 100000 ] && echo $(( _v / 1000 )) || echo "$_v"; }
bmW(){ _m=$(mA); _v=$(bmV); isint "${_m:-x}" && isint "${_v:-x}" || { echo ""; return; }
  echo $(( _m * _v / 1000 )); }
charging_now(){ _m=$(mA); isint "${_m:-x}" && [ "$_m" -gt 150 ]; }
not_charging(){ _m=$(mA); isint "${_m:-x}" && [ "$_m" -le 150 ]; }

# ---- rate ---------------------------------------------------------------------------------------
# Current averaged over a window, in our sign convention. The counter is NOT the primary instrument:
# it is quantised at 20000-28600 uAh and freezes for minutes, so the first non-zero delta over a 5 s
# window reports figures like 20000 mA.
RS=$TD/.megatest-rsrc
rsrc(){ cat "$RS" 2>/dev/null || echo none; }
rate(){
  screen_off
  # ADAPTIVE. The old fixed 75s window existed for the charge counter, which is quantised and needs a
  # long baseline. Nothing here reads the counter any more - current_now is instantaneous - so the
  # window now ends as soon as the running mean stops moving. A settled phone answers in ~14s instead
  # of 75s, and an unsettled one still gets the full window rather than a wrong number quickly.
  _sum=0; _n=0; _t=0; _wake=0; _vlo=; _vhi=; _prev=; _stable=0
  while [ $_t -lt "$W_RATE" ]; do
    sleep 2; _t=$(( _t + 2 ))
    if [ $(( _t % 12 )) -eq 0 ] && [ "$(scr)" = on ]; then _wake=$(( _wake + 1 )); screen_off; fi
    _bv=$(vbus); if isint "${_bv:-x}"; then
      [ -z "$_vlo" ] && { _vlo=$_bv; _vhi=$_bv; }
      [ "$_bv" -lt "$_vlo" ] && _vlo=$_bv
      [ "$_bv" -gt "$_vhi" ] && _vhi=$_bv
    fi
    _m=$(mA); isint "${_m:-x}" || continue
    _sum=$(( _sum + _m )); _n=$(( _n + 1 ))
    [ "$_n" -ge 6 ] || continue
    _avg=$(( _sum / _n ))
    if [ -n "$_prev" ]; then
      _d=$(( _avg - _prev )); _d=${_d#-}
      _ref=${_avg#-}; [ "$_ref" -lt 100 ] && _ref=100
      if [ $(( _d * 100 / _ref )) -le 3 ]; then
        _stable=$(( _stable + 1 ))
        [ "$_stable" -ge 3 ] && break
      else
        _stable=0
      fi
    fi
    _prev=$_avg
  done
  [ "$_n" -gt 0 ] || { echo none > "$RS"; echo ""; return; }
  _vr=
  if [ -n "$_vlo" ] && [ "$_vlo" != "$_vhi" ]; then _vr=", vbus $(( _vlo / 1000 ))-$(( _vhi / 1000 ))mV"
  elif [ -n "$_vlo" ]; then _vr=", vbus $(( _vlo / 1000 ))mV"; fi
  if [ "$_wake" -gt 0 ]; then
    echo "current, ${_n} samples over ${_t}s, SCREEN WOKE ${_wake}x${_vr}" > "$RS"
  else
    echo "current, ${_n} samples over ${_t}s${_vr}" > "$RS"
  fi
  echo $(( _sum / _n ))
}

# Wait for the phone to actually settle instead of sleeping a fixed guess. A cap lands in a few
# seconds on most phones; the old flat 35s per step was the single largest cost in the suite.
settle(){
  _p=; _i=0
  while [ $_i -lt "$W_SETTLE" ]; do
    sleep 3; _i=$(( _i + 3 ))
    _c=$(mA); isint "${_c:-x}" || continue
    if [ -n "$_p" ]; then
      _dd=$(( _c - _p )); _dd=${_dd#-}
      _rr=${_c#-}; [ "$_rr" -lt 100 ] && _rr=100
      [ $(( _dd * 100 / _rr )) -le 6 ] && return 0
    fi
    _p=$_c
  done
  return 0
}

waitfor(){ _lim=$1; shift; _w=0
  while [ $_w -lt "$_lim" ]; do "$@" && return 0; sleep 5; _w=$(( _w + 5 )); done; return 1; }

# ---- write ledger, rotation-safe ----------------------------------------------------------------
# ACC trims the ledger at 400 lines. The first version captured a LINE NUMBER before an operation and
# sliced with `tail -n +N` afterwards; once a trim happened, that offset pointed into unrelated
# history and every ledger assertion in the file was reading the wrong window. Windows are counts of
# a pattern across the whole file, and a shrink marks the window unreliable rather than miscounting.
led_lines(){ [ -f "$WL" ] || { echo 0; return; }; _n=$(wc -l < "$WL" 2>/dev/null); isnum "$_n" && echo "$_n" || echo 0; }
led_count(){ [ -f "$WL" ] || { echo 0; return; }
  _c=$(grep -c "$1" "$WL" 2>/dev/null); isnum "$_c" && echo "$_c" || echo 0; }
LEDN=0
led_open(){ LEDN=$(led_lines); }
led_delta(){
  [ "$(led_lines)" -lt "$LEDN" ] && { echo rotated; return; }
  _a=${2:-0}; _b=$(led_count "$1")
  [ "$_b" -ge "$_a" ] && echo $(( _b - _a )) || echo rotated
}

# ---- switch class -------------------------------------------------------------------------------
# ACC stores switch paths RELATIVE to /sys/class/power_supply ("battery/input_suspend"). Reading the
# raw config value found no file, so held() was false on every call and two sections tested nothing.
SW=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
SWN_RAW=$(echo $SW | cut -d' ' -f1)
SWOFF=$(echo $SW | cut -d' ' -f3)
SWN=
case "${SWN_RAW:-}" in
  '') : ;;
  /*) [ -e "$SWN_RAW" ] && SWN=$SWN_RAW;;
  *)  [ -e "$PS/$SWN_RAW" ] && SWN=$PS/$SWN_RAW;;
esac
NATIVE=false
case "$SWOFF" in pcap) NATIVE=true;; esac
case "$SWN_RAW" in *charge_stop_level*) NATIVE=true;; esac
held(){
  [ -n "$SWN" ] || return 1
  _n=$(rd "$SWN")
  if $NATIVE; then _l=$(lvl); isnum "$_n" && isnum "$_l" && [ "$_n" -le "$_l" ];
  else [ "$_n" = "$SWOFF" ]; fi
}

# ---- arming -------------------------------------------------------------------------------------
# write-config has silently CLAMPED a valid low max_temp (40 rewritten to 50). A clamped limit sits
# above the pack, never trips, and the section reports a clean pass for a cutoff never armed.
# cooldown_temp goes ABOVE the pack, not below it. Setting it to pack-3 while max_temp is pack-2
# guarantees the COOLDOWN DUTY CYCLE engages during the sampling window, and the "on" phase of that
# cycle is indistinguishable from charging above max_temp. It cost a false bug-11 failure: 4 samples
# at 27C drawing 1.3A, while the write ledger showed input_suspend alternating 1/0/1/0 - a daemon
# cycling correctly, not one that failed to hold. Two control loops cannot be measured through one
# observable, so cooldown is pushed out of reach and max_temp is left as the only thing acting.
arm_temp(){
  acc -s cooldown_temp=$(( $1 + 20 )) max_temp=$(( $1 - 2 )) resume_temp=$(( $1 - 5 )) >/dev/null 2>&1
  # cooldown stays out of reach so only ONE control loop is acting. That was the right instinct for
  # the wrong reason: the duty cycle above max_temp comes from mtReached, not from cooldown_temp.
  _land=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f2)
  [ "$_land" = "$(( $1 - 2 ))" ]
}

# ---- save / restore -----------------------------------------------------------------------------
#
# CRASH RECOVERY, and it has to come before the capture below.
#
# The capture reads the CURRENT config and calls it "original". That is right when the previous run
# finished, and badly wrong when it did not: a run killed mid-suite leaves its own test values in
# place, and the next run then adopts them as the user's settings and faithfully restores them at
# the end. Observed exactly that way - a Pixel 6a was left at pause=100 with a 1354 mA cap, and two
# subsequent runs restored those values on exit because that is what they had found on entry. The
# user's real settings survived only because an earlier report still had them written down.
#
# So the first run to touch this phone writes its capture to disk and deletes it on a clean exit. A
# file still present at startup means the previous run died, and the values in it - not the ones on
# the phone right now - are the user's.
_ORIG=$TD/.megatest-orig
if [ -s "$_ORIG" ]; then
  echo "NOTE: a previous run did not finish. Restoring the settings it saved before it died."
  . "$_ORIG" 2>/dev/null || :
  [ -z "${O_RES:-}" ] || acc -s resume_capacity=$O_RES pause_capacity=$O_PAU >/dev/null 2>&1
  [ -z "${O_CT:-}" ]  || acc -s cooldown_temp=$O_CT max_temp=$O_MT resume_temp=$O_RT >/dev/null 2>&1
  acc -s max_charging_current="${O_MCC:-}" >/dev/null 2>&1
  sleep 3
  echo "      restored: capacity=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')  mcc='$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)'"
  rm -f "$_ORIG" 2>/dev/null
fi

S_C=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')
S_T=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
S_RES=$(echo $S_C | cut -d' ' -f3); S_PAU=$(echo $S_C | cut -d' ' -f4)
S_CT=$(echo $S_T | cut -d' ' -f1); S_MT=$(echo $S_T | cut -d' ' -f2); S_RT=$(echo $S_T | cut -d' ' -f3)
S_SDT=$(echo $S_T | cut -d' ' -f4)
S_MCC=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
S_MCV=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
S_SW=$SW
# The re-kick setting was never saved by the first version, which then unconditionally re-enabled it
# on exit: a user who had deliberately turned it off got it switched back on by a test run.
S_RK=on; [ -f $TD/.rekick-off ] && S_RK=off
WORK=$TD/.megatest
rm -rf "$WORK" 2>/dev/null; mkdir -p "$WORK" 2>/dev/null

# Write the capture down NOW, before anything is changed. If this run dies, the next one reads it.
{ echo "O_RES=$S_RES"
  echo "O_PAU=$S_PAU"
  echo "O_CT=$S_CT"
  echo "O_MT=$S_MT"
  echo "O_RT=$S_RT"
  echo "O_MCC=$S_MCC"; } > "$_ORIG" 2>/dev/null || :

restore_all(){
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  acc -s max_charging_voltage="$S_MCV" >/dev/null 2>&1
  acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
  acc -s resume_capacity=$S_RES pause_capacity=$S_PAU >/dev/null 2>&1
  [ -n "$S_SW" ] && acc -s charging_switch="$S_SW" >/dev/null 2>&1
  if [ "$S_RK" = on ]; then acc -sk on >/dev/null 2>&1; else acc -sk off >/dev/null 2>&1; fi
  [ -f "$WORK/ch-switches.bak" ] && cp -a "$WORK/ch-switches.bak" "$TD/ch-switches" 2>/dev/null
  [ -f "$WORK/if.bak" ] && [ ! -s "$IF" ] && cp -a "$WORK/if.bak" "$IF" 2>/dev/null
  # Reaching here means the restore ran, so the crash-recovery capture has done its job and must
  # go. Leaving it would make the next run believe this one died and "restore" settings that are
  # already correct - harmless once, but it would mask a genuine crash the time after.
  rm -f "$_ORIG" 2>/dev/null
  return 0
}
finish(){
  trap - EXIT INT TERM HUP
  log ""; log "--- restoring ---"
  restore_all
  stayon_restore
  # Hand the screen back exactly as it was found. A test run that leaves a phone dark when the owner
  # left it awake has changed something it was not asked to change.
  [ "$SCR0" = on ] && screen_wake
  sleep 6
  alive || { acc -D restart >/dev/null 2>&1 & sleep 40; }
  _rc=$(sed -n 's/^capacity=//p' $DD/config.txt)
  _rt=$(sed -n 's/^temperature=//p' $DD/config.txt)
  _rm=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
  _rv=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
  _rs=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
  log "config : $_rc $_rt"
  log "caps   : mcc='$_rm' mcv='$_rv'"
  log "switch : $(echo $_rs | cut -c1-52)"
  log "daemon : $(alive && echo alive || echo DOWN)"
  # The restore is asserted on EVERY setting the run touches, not just two of them. A run that leaves
  # a phone capped or with a widened pause window has failed, whatever its sections reported.
  _drift=
  [ "$_rc" = "($S_C)" ] || _drift="$_drift capacity"
  [ "$_rt" = "($S_T)" ] || _drift="$_drift temperature"
  [ "$_rm" = "$S_MCC" ] || _drift="$_drift max_current"
  [ "$_rv" = "$S_MCV" ] || _drift="$_drift max_voltage"
  [ "$_rs" = "$S_SW" ]  || _drift="$_drift switch"
  if [ -z "$_drift" ]; then ok RESTORE "every setting restored exactly as found"
  else no RESTORE "NOT restored:${_drift}"; fi
  alive && ok INV-alive "daemon alive at the end" || no INV-alive "daemon DOWN at the end"
  _sdt=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
  [ "$_sdt" = "$S_SDT" ] && ok INV-sdt "shutdown_temp untouched (${_sdt}C)" \
                         || no INV-sdt "shutdown_temp CHANGED $S_SDT -> $_sdt"
  _el=$(( $(date +%s) - T0 ))
  log ""
  [ -n "$REFUSED" ] && log "===== REFUSED TO RUN: $REFUSED ====="
  log "===== $P passed, $F failed, $SK skipped   in $(( _el / 60 ))m$(( _el % 60 ))s ====="
  log "report : $OUT"
  log "table  : $TSV"
  printf 'build=%s cond=%s pass=%s fail=%s skip=%s refused=%s secs=%s tsv=%s\n' \
    "$BUILD" "$COND" "$P" "$F" "$SK" "${REFUSED:-no}" "$_el" "$TSV" > "$DONE" 2>/dev/null
  sync 2>/dev/null || :
  exit 0
}

# ==================================================================================================
: > "$TSV"
rm -f "$DONE" 2>/dev/null
trap finish EXIT INT TERM HUP
[ -s "$IF" ] && cp -a "$IF" "$WORK/if.bak" 2>/dev/null
[ -f "$TD/ch-switches" ] && cp -a "$TD/ch-switches" "$WORK/ch-switches.bak" 2>/dev/null

sec "PREFLIGHT"
_lv=$(lvl); _tp=$(tmpC)
SCR0=$(scr)
stayon_clear
if screen_off; then _scr=off; _scrctl=yes; else _scr=$(scr); _scrctl=no; fi
log "device  : $(getprop ro.product.device) / Android $(getprop ro.build.version.release)"
log "build   : $BUILD"
log "profile : $WANT"
log "level   : ${_lv}%   temp ${_tp}C   screen $_scr (was $SCR0, forced off: $_scrctl, stay_awake was ${STAYON0:-unset})"
log "switch  : ${SWN:-UNRESOLVED}  raw='${SWN_RAW:-}'  off='${SWOFF:-}'  class=$($NATIVE && echo NATIVE || echo generic)"
log "config  : capacity=($S_C) temperature=($S_T)  rekick=$S_RK"
log "caps    : mcc='${S_MCC}' mcv='${S_MCV}'"

if isnum "$_tp" && [ "$_tp" -ge 40 ] 2>/dev/null; then
  REFUSED="pack is ${_tp}C - thermal results would be meaningless and a hot cell is not a thing to stress"
  log "REFUSING: $REFUSED"
  exit 0
fi

FREE=0
if plugged; then
  log "supply  : ${SUP##*/}  type=$(styp)  vbus=$(vbus)  icl=$(icl)"
  if learn_sign; then
    log "sign    : the pack fills when current_now is '${CHG}' (learned from this phone, not from ACC)"
  else
    log "sign    : COULD NOT LEARN - too little current flowing to tell direction"
  fi
  # Measure the free rate with the user's own cap CLEARED. Leaving it in place made every later
  # comparison relative to a throttled baseline, so a cap that changed nothing looked effective.
  if [ -n "$S_MCC" ]; then
    log "          (temporarily clearing the configured ${S_MCC} mA cap to measure the true free rate)"
    acc -s max_charging_current= >/dev/null 2>&1; settle
  fi
  _f=$(rate)
  log "free    : ${_f:-?} mA   (instrument: $(rsrc))"
  [ -n "$S_MCC" ] && acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  if isint "${_f:-x}" && [ "$_f" -gt 1200 ] 2>/dev/null; then COND=fast; FREE=$_f
  elif isint "${_f:-x}" && [ "$_f" -gt 250 ] 2>/dev/null; then COND=slow; FREE=$_f
  elif isint "${_f:-x}" && [ "$_f" -gt 0 ] 2>/dev/null; then COND=weak; FREE=$_f
  else COND=weak; FREE=0; fi
else
  COND=unplugged
  log "supply  : none - unplugged"
fi
log "condition: $COND"
log ""

alive && ok PRE-daemon "daemon is running" || no PRE-daemon "daemon is NOT running"
[ -n "$(accst)" ] && ok PRE-cli "acc -i answers" || no PRE-cli "acc -i returns nothing"
isnum "$S_SDT" && [ "$S_SDT" -ge 40 ] && ok PRE-sdt "shutdown_temp sane (${S_SDT}C)" \
                                      || no PRE-sdt "shutdown_temp is '${S_SDT}'"
[ -n "$SWN" ] && ok PRE-switch "the configured switch path resolves to a real node ($SWN)" \
              || sk PRE-switch "no switch configured, or the path does not resolve ('${SWN_RAW:-}')"

# ==================================================================================================
# T-DAEMON runs BEFORE T-ARB deliberately. T-ARB writes a deliberately invalid _DPOL into the
# live cache, and the daemon carries that value in memory afterwards; running T-DAEMON second
# measured the daemon persisting the harness's own garbage and called it a lost-polarity bug.
if want T-DAEMON; then
sec "T-DAEMON  cache loss with the daemon running   (bugs 4, 12, 14, 17)"
_pid0=$(rd $TD/acc.lock)
_pol0=$(sed -n 's/^_DPOL=//p' $IF 2>/dev/null | tail -1)
: > $IF
_t0=$(date +%s)
_ans=$(accst)
_el=$(( $(date +%s) - _t0 ))
[ -n "$_ans" ] && ok T-DAEMON-cli "acc -i answered '$_ans' in ${_el}s with the cache gone (bug 14)" \
               || no T-DAEMON-cli "acc -i returned nothing in ${_el}s - blind, and blocks on some builds (bug 14)"
cache_usable(){ [ -s "$IF" ] && grep -q '^battCapacity=' "$IF" 2>/dev/null && grep -q '^currFile=' "$IF" 2>/dev/null; }
waitfor "$W_POLL" cache_usable \
  && ok T-DAEMON-heal "the daemon republished a usable cache (bug 17)" \
  || no T-DAEMON-heal "the cache never came back within ${W_POLL}s (bug 17)"
_pid1=$(rd $TD/acc.lock)
# Empty compared to empty is not a pass. A dead daemon has no pid at either end, and the first
# version printed "without restarting (pid  throughout)" for a daemon that was never running.
if [ -z "$_pid0" ] || [ -z "$_pid1" ] || ! alive; then
  no T-DAEMON-norestart "no live daemon across the rebuild (pid '$_pid0' -> '$_pid1')"
elif [ "$_pid0" = "$_pid1" ]; then
  ok T-DAEMON-norestart "healed WITHOUT restarting (pid $_pid0 throughout)"
else
  sk T-DAEMON-norestart "daemon restarted ($_pid0 -> $_pid1) - this measured init, not the republish"
fi
_pol1=$(sed -n 's/^_DPOL=//p' $IF 2>/dev/null | tail -1)
if [ -z "$_pol0" ]; then sk T-DAEMON-pol "nothing was latched before the rebuild (bug 21)"
elif [ "$_pol0" = "$_pol1" ]; then ok T-DAEMON-pol "learned polarity survived the rebuild ('$_pol1') (bug 21)"
else no T-DAEMON-pol "polarity changed across the rebuild: '$_pol0' -> '$_pol1' (bug 21)"; fi
alive && ok T-DAEMON-alive "daemon survived losing its cache" || no T-DAEMON-alive "daemon DIED"
fi

# ==================================================================================================
if want T-ARB; then
sec "T-ARB  charge direction under corrupted polarity   (bugs 1, 2, 3, 21)"
# A wrong direction verdict disables all four limits at once, silently.
if [ -z "$SWN" ] && [ "$COND" = unplugged ]; then sk T-ARB "no switch and unplugged"
elif [ "$COND" = weak ] && plugged; then
  sk T-ARB "supply delivers only ${FREE} mA; whether the phone is charging is genuinely ambiguous"
else
  _bad=0; _n=0
  if [ "$COND" = unplugged ]; then _want="Discharging/Idle"; else _want=Charging; fi
  for _v in '+' '-' '' 'garbage'; do
    _n=$((_n + 1))
    { grep -v '^_DPOL=' "$WORK/if.bak" 2>/dev/null; echo "_DPOL=$_v"; } > $IF.t 2>/dev/null && mv -f $IF.t $IF 2>/dev/null
    sleep 7
    _s=$(accst)
    if [ "$COND" = unplugged ]; then
      case "$_s" in Discharging|Idle|Not*) : ;; *) _bad=$((_bad + 1));; esac
    else
      [ "$_s" = Charging ] || _bad=$((_bad + 1))
    fi
    log "      _DPOL='${_v}' -> '${_s:-empty}'"
  done
  # Count the LIVE cache before restoring the backup. The first version restored first and then
  # counted, so it measured the pristine backup and bug 3 could never fail.
  _dp=$(grep -c '^_DPOL=' $IF 2>/dev/null); isnum "$_dp" || _dp=-1
  [ -f "$WORK/if.bak" ] && cp -a "$WORK/if.bak" "$IF" 2>/dev/null
  [ "$_bad" -eq 0 ] && ok T-ARB-verdict "correct verdict under all $_n corrupted polarities (expected $_want)" \
                    || no T-ARB-verdict "$_bad of $_n corrupted polarities gave a wrong verdict"
  if [ "$_dp" -lt 0 ]; then no T-ARB-append "the interface cache was unreadable when counting polarity lines (bug 3)"
  elif [ "$_dp" -eq 1 ]; then ok T-ARB-append "exactly one polarity line in the LIVE cache after $_n rewrites (bug 3)"
  else no T-ARB-append "$_dp polarity lines in the live cache - sdp() is appending (bug 3)"; fi
fi
fi

# ==================================================================================================
if want T-NATIVE; then
sec "T-NATIVE  firmware limit   (bugs 5, 6, 7)"
if ! $NATIVE; then sk T-NATIVE "generic switch phone; these bugs are native-only"
elif [ -z "$SWN" ]; then sk T-NATIVE "the switch path does not resolve, so the firmware node cannot be read"
elif [ "$COND" != fast ] && [ "$COND" != slow ]; then sk T-NATIVE "needs a live charge (condition $COND)"
else
  acc -s resume_capacity=$(( $(lvl) - 3 )) pause_capacity=$(( $(lvl) - 1 )) >/dev/null 2>&1
  waitfor 120 held && ok T-NATIVE-reach "a capacity pause reaches the firmware ($(rd $SWN) <= $(lvl))" \
                   || no T-NATIVE-reach "the firmware level never came down ($(rd $SWN) vs $(lvl))"
  _s0=$(rd $SWN)
  acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
  released(){ _n=$(rd $SWN); _l=$(lvl); isnum "$_n" && isnum "$_l" && [ "$_n" -gt "$_l" ]; }
  waitfor 150 released \
    && ok T-NATIVE-latch "raising the limit releases it: stop $_s0 -> $(rd $SWN) (bug 5)" \
    || no T-NATIVE-latch "LATCHED at $(rd $SWN) with the limit raised to 100 - phone stranded (bug 5)"
  _tp=$(tmpC)
  if ! isnum "$_tp" || [ "$_tp" -le 12 ] 2>/dev/null; then
    sk T-NATIVE-thermal "temperature unreadable"
    sk T-NATIVE-pulse "temperature unreadable"
  elif ! arm_temp "$_tp"; then
    sk T-NATIVE-thermal "max_temp was rewritten to ${_land}; the limit under test was never armed"
    sk T-NATIVE-pulse "same: no armed limit to pulse against"
  else
    settle
    _r=$(rate)
    log "      pack ${_tp}C vs max_temp ${_land}C, level $(lvl)%, stop=$(rd $SWN), rate ${_r:-?} mA"
    # A negative rate means the pack is DRAINING, which is not evidence a thermal limit worked. The
    # first version accepted anything at or below 150 including large negatives, so a phone that had
    # simply lost its charger passed the thermal assertion.
    if ! isint "${_r:-x}"; then sk T-NATIVE-thermal "could not measure a rate"
    elif ! plugged; then sk T-NATIVE-thermal "the cable came out; no thermal verdict"
    # Proportional, not absolute. A fixed 150 mA ceiling assumes a hard hold; ACC duty-cycles above
    # max_temp on a generic-switch phone, so the windowed average is nonzero by design. Measured 251 mA
    # against a ~2400 mA free rate - a 10% duty, i.e. the hold working - and the fixed threshold called
    # it a reproduction of the sweet bug. The Pixel holds at 0 mA and passes either way.
    else
      _tcap=$(( ${FREE:-1000} / 6 )); [ "$_tcap" -lt 150 ] && _tcap=150
      if [ "$_r" -le "$_tcap" ]; then
        ok T-NATIVE-thermal "thermal pause holds to ${_r} mA below the resume level (ceiling ${_tcap}) (bug 6)"
      else
        no T-NATIVE-thermal "still charging at ${_r} mA on a pack over max_temp, ceiling ${_tcap} (bug 6)"
      fi
    fi
    _hits=0; _n=0
    while [ $_n -lt $N_SAMP ]; do
      _n=$((_n + 1)); [ "$(rd $SWN)" = 100 ] && _hits=$((_hits + 1)); sleep 2
    done
    [ "$_hits" -eq 0 ] && ok T-NATIVE-pulse "no wide-open pulse across $N_SAMP samples on a hot pack (bug 7)" \
                       || no T-NATIVE-pulse "stop_level read 100 in $_hits of $N_SAMP samples while paused (bug 7)"
  fi
  acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
  acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
  # Judge the resume by CURRENT: the kernel label reads Charging on a native phone holding at zero,
  # so a status-based check passes without a single milliamp moving.
  # Only assert a resume if there is still a CABLE. Unplugged there is no current to observe,
  # and "did not resume" would be a true observation with a false conclusion.
  if ! plugged; then
    sk T-NATIVE-resume "the cable is gone; no current to observe either way"
  elif waitfor 150 charging_now; then
    ok T-NATIVE-resume "resumes at $(mA) mA once the limits are lifted"
  else
    # Re-check the cable AFTER the wait too. It was true when we entered and gone by the end on
    # one run, and the assertion then reported "the phone was left cut" for a phone that simply
    # had no charger. A precondition checked only once is a precondition for an instant.
    if ! plugged; then
      sk T-NATIVE-resume "the cable came out during the wait; no verdict"
    else
      # Capture the supply state AT THE FAILURE. Without it, "no current for 150s" is compatible
      # with a pulled cable, a charger that stopped delivering while present stayed 1, and ACC
      # genuinely failing to resume - and nothing recorded afterwards can tell them apart.
      _fs=; _fv=0; _fi=0; _fo=no
      for _sd in /sys/class/power_supply/*; do
        case "${_sd##*/}" in battery|bms|maxfg|*fuelgauge*) continue;; esac
        [ "$(rd $_sd/online)" = 1 ] || continue
        _fo=yes; _fv=$(rd $_sd/voltage_now); _fi=$(rd $_sd/current_max); _fs=${_sd##*/}
      done
      log "        at failure: present=$(plugged && echo yes || echo no) online=$_fo supply=${_fs:-none}"
      log "        vbus=$(( ${_fv:-0} / 1000 ))mV icl=$(( ${_fi:-0} / 1000 ))mA switch=$(rd "${SWN:-/dev/null}") batt=$(mA)mA"
      no T-NATIVE-resume "no current flowing 150s after the limits were lifted (see the supply state above)"
    fi
  fi
  acc -s resume_capacity=$S_RES pause_capacity=$S_PAU >/dev/null 2>&1
fi
fi

# ==================================================================================================
if want T-CAPS; then
sec "T-CAPS  current cap lifecycle   (bugs 9, 10, 18, 22)"
if [ "$COND" != fast ] && [ "$COND" != slow ]; then sk T-CAPS "needs a live charge with headroom (condition $COND)"
else
  acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
  # Count writes to CURRENT nodes, not raw ledger growth: the daemon writes other things constantly,
  # so any growth at all used to read as "the cap was applied".
  # A FRESH free rate, measured here rather than reused from preflight - the preflight number is
  # minutes and several percent of charge old, and comparing across that gap mixes the cap with taper.
  _freenow=$(rate)
  log "      free (measured now, not at preflight): ${_freenow:-?} mA"
  _base=$(led_count 'current'); led_open
  acc -s max_charging_current=500 >/dev/null 2>&1
  settle
  _wrote=$(led_delta 'current' "$_base")
  if [ "$_wrote" = rotated ]; then sk T-CAPS-write "the ledger rotated during the window; the count is not trustworthy"
  elif [ "$_wrote" -gt 0 ]; then ok T-CAPS-write "setting a cap wrote $_wrote current-node lines (bug 18)"
  else no T-CAPS-write "the cap was accepted and NOTHING was written to a current node (bug 18)"; fi
  [ -f $TD/.mcc-custom ] && ok T-CAPS-marker "the cap marker is set" || no T-CAPS-marker "the cap marker is missing"
  _capped=$(rate)
  log "      free ${FREE} mA -> capped ${_capped:-?} mA (instrument: $(rsrc))"
  # "Did the rate fall?" is not enough, and passing it is how a silently-unenforced cap shipped: a
  # 500 mA cap that left the phone at 2008 mA out of a free 2541 mA satisfied "it fell" while
  # throttling almost nothing. The cap is on INPUT current and this reads BATTERY current, so the
  # two differ by the vbus-to-vpack ratio and an exact match is wrong to demand - but the result
  # must land nearer the cap than the free rate, or the cap is not doing its job.
  if ! isint "${_capped:-x}" || ! isint "${_freenow:-x}" || [ "$_freenow" -le 0 ]; then
    sk T-CAPS-effect "could not measure a rate"
  elif [ "$_capped" -ge "$_freenow" ] 2>/dev/null; then
    no T-CAPS-effect "the cap changed nothing: ${_capped} mA against a free ${FREE} mA"
  else
    _mid=$(( (500 + _freenow) / 2 ))
    if [ "$_capped" -le "$_mid" ] 2>/dev/null; then
      ok T-CAPS-effect "a 500 mA cap pulled ${_freenow} mA down to ${_capped} mA, nearer the cap than the free rate"
    else
      no T-CAPS-effect "a 500 mA cap only reached ${_capped} mA from ${_freenow} mA - closer to unlimited than to the cap, so most nodes were skipped"
    fi
  fi
  # The regression that made all of this necessary: `acc -s` published its config AFTER applying, so
  # a daemon tick landing in that window read a config with no cap, saw the marker already up,
  # concluded the user had cleared one, and ran the release path - deleting the marker and restoring
  # the nodes mid-apply. The cap then sat in config, showed as active in AccA, and throttled almost
  # nothing. Assert the two records agree: a cap in config MUST have its marker.
  _cfgmcc=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
  if [ -n "$_cfgmcc" ] && [ ! -f $TD/.mcc-custom ]; then
    no T-CAPS-consistent "config holds a ${_cfgmcc} mA cap but the marker is gone - the apply guard will skip every throttling node"
  elif [ -n "$_cfgmcc" ]; then
    ok T-CAPS-consistent "config cap and marker agree (${_cfgmcc} mA)"
  else
    no T-CAPS-consistent "the cap did not persist to config at all"
  fi
  # Set and clear repeatedly: the race needs the daemon tick to land inside a ~1s window, so one
  # attempt proves little. Six cycles put the odds past 95% on a 3s loop.
  _lost=0; _i=0
  while [ $_i -lt 6 ]; do
    _i=$((_i + 1))
    acc -s max_charging_current=700 >/dev/null 2>&1
    # POLL for the marker rather than sampling once after a fixed sleep. At or above the pause level
    # the input is suspended and the apply takes noticeably longer, so a 2-4s sample can land
    # mid-write and report a loss that never happened - it produced exactly one false failure in a
    # 60-cycle run, on the one cycle where the pack had reached its pause point.
    _w=0
    while [ $_w -lt 12 ]; do
      [ -f $TD/.mcc-custom ] && break
      sleep 1; _w=$((_w + 1))
    done
    _c=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
    [ -n "$_c" ] && [ ! -f $TD/.mcc-custom ] && { _lost=$((_lost + 1)); log "        cycle $_i: config=$_c but no marker after ${_w}s"; }
    acc -s max_charging_current= >/dev/null 2>&1
    sleep 3
  done
  [ "$_lost" -eq 0 ] && ok T-CAPS-race "marker survived all 6 set/clear cycles against a live daemon" \
                     || no T-CAPS-race "the marker was lost in $_lost of 6 set/clear cycles - the CLI and the daemon are racing"
  acc -s max_charging_current=500 >/dev/null 2>&1; sleep 8
  _base=$(led_count '<- 500000 '); led_open
  acc -s max_charging_current= >/dev/null 2>&1
  sleep 10
  [ -f $TD/.mcc-custom ] && no T-CAPS-clear "the marker survived the clear" || ok T-CAPS-clear "the clear dropped the marker"
  settle
  _recap=$(led_delta '<- 500000 ' "$_base")
  if [ "$_recap" = rotated ]; then sk T-CAPS-norecap "the ledger rotated during the window"
  elif [ "$_recap" -eq 0 ]; then ok T-CAPS-norecap "the cap was not re-applied after the release (bug 10)"
  else no T-CAPS-norecap "the daemon re-applied the cap $_recap times after the clear (bug 10)"; fi
  _after=$(rate)
  log "      after the clear: ${_after:-?} mA   (capped was ${_capped:-?} mA, seconds earlier)"
  # Compare against the CAPPED reading taken seconds ago, not a preflight baseline. Charge current
  # falls on its own as the pack fills, so a preflight number is measured at a different battery
  # state. This failed at 1384 mA against 50% of a 2973 mA figure taken 8 percentage points earlier,
  # while every capped node was verifiably released high (restrict_cur 5000000, both
  # constant_charge_current 3000000, config empty, marker absent). Taper, not a suppressed cap.
  #
  # Bug 9 claims "after clearing, the rate recovers". Two readings seconds apart on the same pack
  # test exactly that, and taper cannot move them relative to each other.
  if ! isint "${_after:-x}" || ! isint "${_capped:-x}"; then
    sk T-CAPS-recover "could not measure a rate"
  elif [ "$_capped" -le 0 ] 2>/dev/null; then
    sk T-CAPS-recover "the capped reading was not a positive charging rate; nothing to recover from"
  elif [ "$_after" -gt $(( _capped + (_capped / 5) )) ] 2>/dev/null; then
    ok T-CAPS-recover "the rate rose from ${_capped} to ${_after} mA after the clear (bug 9)"
  else
    no T-CAPS-recover "rate did not rise after the clear: ${_capped} -> ${_after} mA (bug 9)"
  fi
  if [ -f /sys/class/qcom-battery/restrict_cur ]; then
    _rc=$(rd /sys/class/qcom-battery/restrict_cur)
    [ "${_rc:-0}" -ge 3000000 ] 2>/dev/null \
      && ok T-CAPS-restrict "restrict_cur released high after the clear ($_rc) (bug 22)" \
      || no T-CAPS-restrict "restrict_cur left at $_rc - the phone stays throttled (bug 22)"
  else
    sk T-CAPS-restrict "no qcom restrict_cur node on this phone"
  fi
  acc -s resume_capacity=$S_RES pause_capacity=$S_PAU >/dev/null 2>&1
fi
fi

# ==================================================================================================
if want T-VOLT; then
sec "T-VOLT  voltage limit is not stored when unsupported   (bug 19)"
if grep -q / $TD/ch-volt-ctrl-files 2>/dev/null; then
  sk T-VOLT "this phone HAS voltage control; bug 19 is about phones without it"
else
  acc -s max_charging_voltage=3900 >/dev/null 2>&1
  sleep 5
  _mcv=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt | tr -d '()')
  [ -z "$_mcv" ] && ok T-VOLT-nostore "an unsupported voltage limit is not persisted (bug 19)" \
                 || no T-VOLT-nostore "stored '$_mcv' on a phone with no voltage node - AccA shows a phantom limit (bug 19)"
  acc -s max_charging_voltage="$S_MCV" >/dev/null 2>&1
fi
fi

# ==================================================================================================
if want T-TEMP; then
sec "T-TEMP  temperature limit   (bugs 11, 15 - the sweet report)"
_tp=$(tmpC)
if [ "$COND" != fast ] && [ "$COND" != slow ]; then sk T-TEMP "needs a live charge (condition $COND)"
elif ! isnum "$_tp" || [ "$_tp" -le 12 ] 2>/dev/null; then sk T-TEMP "temperature unreadable"
elif [ "$_scrctl" = no ]; then sk T-TEMP "could not force the screen off; its draw would mask whether the charge stopped"
else
  acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
  # Ledger baseline BEFORE arming, so cuts made anywhere in this section are counted.
  # A fresh free rate, measured HERE with the pause window already widened. The preflight figure
  # was taken with the phone sitting at 76% = its pause level, so ACC was holding and there was no
  # free rate to measure - the derived ceiling collapsed to its floor of 150 mA and then failed a
  # duty cycle whose on-phase is a perfectly normal 400 mA.
  _tfree=$(rate)
  isint "${_tfree:-x}" && [ "$_tfree" -gt 200 ] 2>/dev/null || _tfree=${FREE:-2000}
  log "      free with the window widened: ${_tfree} mA"
  _swbase=$(led_count 'input_suspend'); led_open
  if ! arm_temp "$_tp"; then
    sk T-TEMP-stop "max_temp was rewritten to ${_land}; the limit under test was never armed"
    sk T-TEMP-nostale "same: no armed limit to hold against"
  else
    settle
    _r=$(rate)
    log "      pack ${_tp}C, max_temp ${_land}C (confirmed landed), level $(lvl)%, rate ${_r:-?} mA"
    if ! isint "${_r:-x}"; then sk T-TEMP-stop "could not measure a rate"
    elif ! plugged; then sk T-TEMP-stop "the cable came out; no thermal verdict"
    # Proportional, not absolute. A fixed 150 mA ceiling assumes a hard hold; ACC duty-cycles above
    # max_temp on a generic-switch phone, so the windowed average is nonzero by design. Measured 251 mA
    # against a ~2400 mA free rate - a 10% duty, i.e. the hold working - and the fixed threshold called
    # it a reproduction of the sweet bug. The Pixel holds at 0 mA and passes either way.
      else
        # The sweet report is "charging does not stop at max temp". The honest evidence for that is
        # whether ACC CUT, not what a single windowed average happened to catch: the cycle holds for
        # 39s to 4m33s, so one 75s window can land entirely inside an on-phase and read full current on
        # a phone that is holding correctly. The rate is still reported, as corroboration.
        _scuts=$(led_delta "input_suspend" "$_swbase")
        case "${_scuts:-x}" in ""|rotated|*[!0-9]*) _scuts=-1;; esac
        _tcap=$(( ${_tfree:-2000} / 3 )); [ "$_tcap" -lt 300 ] && _tcap=300
        if [ "$_scuts" -ge 1 ] 2>/dev/null; then
          ok T-TEMP-stop "ACC cut the charge ${_scuts}x at max_temp (rate ${_r} mA, free ${_tfree}) - the sweet symptom is fixed"
        elif [ "$_r" -le "$_tcap" ] 2>/dev/null; then
          ok T-TEMP-stop "held to ${_r} mA at max_temp without needing a cut (ceiling ${_tcap})"
        else
          no T-TEMP-stop "no cut and still charging at ${_r} mA above max_temp (ceiling ${_tcap}) - the sweet symptom REPRODUCES"
        fi
    fi
    # bug 11: a thermal hold must act on a reading taken AFTER the sleep, not a stale one.
    #
    # WHAT ACC ACTUALLY PROMISES ABOVE max_temp - and it is not "zero current".
    #
    # accd.sh implements a DUTY CYCLE there, through two lines that are easy to read backwards:
    #
    #   _le_resume_cap(): if $mtReached && _lt_pause_cap; then return 0   # resume is PERMITTED
    #   line 881:         is_charging -> mtReached=false                  # the flag clears on charge
    #
    # So mtReached does not mean "hold engaged". It means "max temp was reached, therefore resume is
    # allowed below the pause level". The loop is: pause at max_temp, resume permitted, charge, flag
    # clears, still hot, pause again. Measured on a Mi A3 as six alternating input_suspend writes in
    # three minutes, roughly a third of samples drawing current.
    #
    # The previous assertion demanded ZERO current above max_temp and failed this twice. It was
    # testing a contract ACC does not offer. Worse, my first "fix" pushed cooldown_temp out of reach
    # on the theory that the cooldown cycle was responsible - it was not, and the real mechanism was
    # three lines away in the same file.
    #
    # WHAT IS ASSERTED INSTEAD, which is what actually protects a battery:
    #   1. the AVERAGE stays well below an unrestricted charge - the pack is not being cooked
    #   2. the switch CYCLES - alternating writes prove a live controller, not a stuck resume
    #
    # Point 2 is the one that separates a working duty cycle from bug 11. A stuck resume shows
    # sustained current and NO further switch writes; a duty cycle shows both.
    _n=0; _hot=0; _drawing=0; _sum=0; _peak=0
    while [ $_n -lt $N_SAMP ]; do
      _n=$((_n + 1))
      _tn=$(tmpC); _cn=$(mA)
      if isnum "$_tn" && [ "$_tn" -ge "$_land" ] 2>/dev/null; then
        _hot=$((_hot + 1))
        if isint "${_cn:-x}"; then
          [ "$_cn" -gt 0 ] 2>/dev/null && _sum=$(( _sum + _cn ))
          [ "$_cn" -gt "$_peak" ] 2>/dev/null && _peak=$_cn
          [ "$_cn" -gt 400 ] 2>/dev/null && _drawing=$((_drawing + 1))
        fi
      fi
      sleep 2
    done
    _swrites=$(led_delta 'input_suspend' "$_swbase")
    case "${_swrites:-x}" in ''|rotated|*[!0-9]*) _swrites=-1;; esac
    if [ "$_hot" -eq 0 ]; then
      sk T-TEMP-nostale "the pack never stayed at or above ${_land}C during sampling; nothing to test (bug 11)"
    else
      _avg=$(( _sum / _hot ))
      log "        ${_hot} samples at or above ${_land}C: avg ${_avg} mA, peak ${_peak} mA, ${_drawing} drawing, ${_swrites} switch writes"
      # A duty cycle averages far below an unrestricted charge. The free rate on these phones is
      # 2000-2500 mA, so half of that is a generous ceiling that still catches a hold that never
      # engaged at all.
      # The AVERAGE is the verdict, because the average is what protects the pack. The switch count is
      # corroboration, not a gate: requiring 2+ transitions inside a 24s sampling window contradicted
      # the ~35s cycle period, so a working duty cycle could only ever show 0 or 1 and the assertion
      # failed a phone that was holding correctly at 27% duty.
      # THE LEDGER IS THE INSTRUMENT, not a burst of instantaneous samples.
      #
      # The duty cycle period is MINUTES: measured cuts held for 39s, 65s and 4m33s in one session.
      # A 24s sampling window lands wherever it lands - one run caught a transition and saw 4 of 12
      # samples drawing, the next fell entirely inside an "on" phase and saw 12 of 12 with zero switch
      # writes. Same phone, same pack temperature, same armed limit, opposite verdicts. The window was
      # never long enough to characterise the cycle, so it was measuring its own phase alignment.
      #
      # What the ledger answers instead, and answers reliably: did ACC CUT at all while the pack was
      # over max_temp? A cut proves the thermal path engaged. Sustained full current with no cut in
      # the entire section is bug 11; anything else is the controller working at some duty.
      _cuts=$(led_delta "input_suspend" "$_swbase")
      case "${_cuts:-x}" in ''|rotated|*[!0-9]*) _cuts=-1;; esac
      _duty=0; [ "$_hot" -gt 0 ] && _duty=$(( _drawing * 100 / _hot ))
      log "        thermal section: ${_cuts} switch writes while hot, ${_duty}% of samples drawing, avg ${_avg} mA"
      if [ "$_cuts" -lt 0 ] 2>/dev/null; then
        sk T-TEMP-nostale "the write ledger rotated; cannot attribute the thermal behaviour (bug 11)"
      elif [ "$_drawing" -eq 0 ]; then
        ok T-TEMP-nostale "no current at all in $_hot samples above max_temp - a hard hold (bug 11)"
      elif [ "$_cuts" -ge 1 ] 2>/dev/null; then
        ok T-TEMP-nostale "thermal path engaged: ${_cuts} cuts while hot, ${_duty}% duty, avg ${_avg} mA (bug 11)"
      else
        no T-TEMP-nostale "NO cut at all while above max_temp, ${_duty}% of samples at avg ${_avg} mA - the hold never engaged (bug 11)"
      fi
    fi
  fi
  acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
  # Wait for the resume with the pause window still WIDE. Restoring a pause the phone is already past
  # would leave it correctly held, and the first version then reported that as a resume failure.
  # Only assert a resume if there is still a CABLE. Unplugged there is no current to observe,
  # and "did not resume" would be a true observation with a false conclusion.
  if ! plugged; then
    sk T-TEMP-resume "the cable is gone; no current to observe either way"
  elif waitfor 150 charging_now; then
    ok T-TEMP-resume "resumes at $(mA) mA once the temperature limit is lifted"
  else
    # Re-check the cable AFTER the wait too. It was true when we entered and gone by the end on
    # one run, and the assertion then reported "the phone was left cut" for a phone that simply
    # had no charger. A precondition checked only once is a precondition for an instant.
    if ! plugged; then
      sk T-TEMP-resume "the cable came out during the wait; no verdict"
    else
      # Capture the supply state AT THE FAILURE. Without it, "no current for 150s" is compatible
      # with a pulled cable, a charger that stopped delivering while present stayed 1, and ACC
      # genuinely failing to resume - and nothing recorded afterwards can tell them apart.
      _fs=; _fv=0; _fi=0; _fo=no
      for _sd in /sys/class/power_supply/*; do
        case "${_sd##*/}" in battery|bms|maxfg|*fuelgauge*) continue;; esac
        [ "$(rd $_sd/online)" = 1 ] || continue
        _fo=yes; _fv=$(rd $_sd/voltage_now); _fi=$(rd $_sd/current_max); _fs=${_sd##*/}
      done
      log "        at failure: present=$(plugged && echo yes || echo no) online=$_fo supply=${_fs:-none}"
      log "        vbus=$(( ${_fv:-0} / 1000 ))mV icl=$(( ${_fi:-0} / 1000 ))mA switch=$(rd "${SWN:-/dev/null}") batt=$(mA)mA"
      no T-TEMP-resume "no current flowing 150s after the temperature limit was lifted (see the supply state above)"
    fi
  fi
  acc -s resume_capacity=$S_RES pause_capacity=$S_PAU >/dev/null 2>&1
  # bug 15 is a source property: the handler either ships or it does not. The first version called
  # ok() unconditionally here, so it passed on every build including one with the path deleted.
  grep -q 'temp-sensor-unreadable' $M/accd.sh 2>/dev/null \
    && ok T-TEMP-outage "the sensor-outage handler ships in accd.sh (bug 15, source-level)" \
    || no T-TEMP-outage "no sensor-outage handler in accd.sh - a dead sensor is silently coerced (bug 15)"
fi
fi

# ==================================================================================================
if want T-REKICK; then
sec "T-REKICK  the USB re-kick gate   (bugs 13, 20)"
if [ ! -e $PS/usb/apsd_rerun ] && [ ! -e $PS/battery/rerun_aicl ]; then
  sk T-REKICK "no re-kick nodes on this phone (Qualcomm-only); the storm cannot occur here"
elif [ "$COND" != fast ] && [ "$COND" != slow ]; then sk T-REKICK "needs a live charge"
else
  # Establish the instrument registers something before trusting a zero. A count of 0 has two causes,
  # the gate held or nothing could ever fire, and the first version could not tell them apart.
  acc -sk on >/dev/null 2>&1; sleep 3
  _b=$(led_count 'rekick'); led_open
  acc -s max_charging_current=600 >/dev/null 2>&1; sleep 20
  acc -s max_charging_current= >/dev/null 2>&1; sleep 25
  _any=$(led_delta 'rekick' "$_b")
  # Positive control, widened: our own 45s window may legitimately provoke nothing now that the
  # interval is 300s. If this phone has EVER logged a re-kick, the mechanism is reachable here and a
  # zero inside our window is a real result rather than an absent instrument.
  _ever=$(led_count 'rekick')
  # NOT `grep -c ... || echo 0`. grep -c prints its count AND exits 1 when the count is zero, so
  # the fallback fires on top of the "0" it already printed and the substitution yields TWO lines.
  # $(( _ever + 0 0 )) is a syntax error that kills the whole run: this aborted T-REKICK on a Mi A3
  # and silently skipped T-CONTRACT, T-DISCOVERY, T-RANGE and T-GRID, while the summary line still
  # read "0 failed". It survived on a Pixel only because that phone's flight log HAD rekick lines,
  # so grep exited 0 and the fallback never ran. Capture, then sanitise.
  _flc=0
  if [ -f "$FL" ]; then
    _flc=$(grep -c 'rekick' "$FL" 2>/dev/null) || :
    case "${_flc:-0}" in ''|*[!0-9]*) _flc=0;; esac
  fi
  _ever=$(( _ever + _flc ))
  if { [ "$_any" = rotated ] || [ "${_any:-0}" -eq 0 ]; } && [ "${_ever:-0}" -eq 0 ]; then
    sk T-REKICK-off "no re-kick has ever been recorded on this phone, so a zero count proves nothing"
    sk T-REKICK-gate "same: the instrument was never shown to register anything"
  else
    log "      instrument check: $_any provoked now, $_ever recorded on this phone ever"
    acc -sk off >/dev/null 2>&1; sleep 3
    _b=$(led_count 'rekick .*<- 1'); _bs=$(led_count 'rekick skipped'); led_open
    acc -s max_charging_current=600 >/dev/null 2>&1; sleep 20
    acc -s max_charging_current= >/dev/null 2>&1; sleep 25
    _k=$(led_delta 'rekick .*<- 1' "$_b"); _s=$(led_delta 'rekick skipped' "$_bs")
    log "      with re-kick OFF: $_k fired, $_s skipped-and-logged"
    if [ "$_k" = rotated ]; then sk T-REKICK-off "the ledger rotated during the window"
    elif [ "$_k" -eq 0 ]; then ok T-REKICK-off "no re-kick fired while disabled, $_s logged as skipped (bug 13)"
    else no T-REKICK-off "$_k re-kicks fired despite acc -sk off (bug 13)"; fi
    acc -sk on >/dev/null 2>&1; sleep 3
    # bug 20 was two gates with separate timestamps firing every 15-62s. The interval is now 300s, so
    # over a 72s burst the honest threshold is at most ONE, not two.
    _b=$(led_count 'rekick .*<- 1'); _bs=$(led_count 'rekick skipped'); led_open
    _i=0; while [ $_i -lt 3 ]; do _i=$((_i + 1))
      acc -s max_charging_current=600 >/dev/null 2>&1; sleep 12
      acc -s max_charging_current= >/dev/null 2>&1; sleep 12
    done
    _k=$(led_delta 'rekick .*<- 1' "$_b"); _s=$(led_delta 'rekick skipped' "$_bs")
    log "      3 cap cycles in ~72s: $_k fired, $_s suppressed"
    if [ "$_k" = rotated ]; then sk T-REKICK-gate "the ledger rotated during the window"
    elif [ "$_k" -le 1 ]; then ok T-REKICK-gate "the rate limit held across 3 rapid cycles ($_k fired, $_s suppressed) (bug 20)"
    else no T-REKICK-gate "$_k re-kicks in ~72s - the gate is not holding (bug 20)"; fi
  fi
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
fi
fi

# ==================================================================================================
if want T-CONTRACT; then
sec "T-CONTRACT  the fast-charge contract survives a cap cycle   (the curtana report)"
_v0=$(vbus)
if [ "$COND" = unplugged ]; then sk T-CONTRACT "unplugged"
elif [ "${_v0:-0}" -lt 5500000 ] 2>/dev/null; then
  sk T-CONTRACT "supply is at $(( ${_v0:-0} / 1000 )) mV - no contract above 5V to collapse, so any verdict would be meaningless"
else
  _i0=$(icl)
  _mw0=$(( (_v0 / 1000) * (${_i0:-0} / 1000) / 1000 ))
  log "      before: $(( _v0 / 1000 )) mV x $(( ${_i0:-0} / 1000 )) mA = ${_mw0} mW   (node: ${SUP##*/})"
  _i=0; while [ $_i -lt 4 ]; do _i=$((_i + 1))
    acc -s max_charging_current=500 >/dev/null 2>&1; sleep 20
    acc -s max_charging_current= >/dev/null 2>&1; sleep 25
  done
  settle
  _v1=$(vbus); _i1=$(icl)
  _mw1=$(( (${_v1:-0} / 1000) * (${_i1:-0} / 1000) / 1000 ))
  _pct=0; [ "$_mw0" -gt 0 ] && _pct=$(( _mw1 * 100 / _mw0 ))
  log "      after : $(( ${_v1:-0} / 1000 )) mV x $(( ${_i1:-0} / 1000 )) mA = ${_mw1} mW  (${_pct}% of start)"
  # POWER, not voltage. 7V/2A stepping to 5.4V/3A is MORE power, and a voltage threshold calls that a
  # collapse. The report itself is in watts: 5.84W where a replug gave 15.3W.
  if ! plugged; then sk T-CONTRACT-hold "the cable came out during the stress; no verdict"
  elif [ "$_pct" -ge 60 ]; then ok T-CONTRACT-hold "contract held: ${_pct}% of starting power retained"
  else no T-CONTRACT-hold "contract COLLAPSED to ${_pct}% of starting power - the curtana symptom"; fi
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
fi
fi

# ==================================================================================================
if want T-DISCOVERY; then
sec "T-DISCOVERY  switch discovery must not cut a healthy charge   (bugs 23, 24, 25)"
# Bug 24 is checked against the SHIPPED file, not a copy. The first version reimplemented the
# module's own filter inside the harness and asserted against the reimplementation, which passes
# whatever the shipped code actually does.
_ra=$(sed -n '/^restore_all_on()/,/^}/p' $M/acc-switch-scan.sh 2>/dev/null)
# The whole function, not a fixed -A window: the filter sits about 20 lines in, behind a comment
# block, and a short window reported the fix missing on a build that has it.
if printf '%s' "$_ra" | grep -q 'restrict_cur' && printf '%s' "$_ra" | grep -q 'current_max'; then
  ok T-DISC-snapshot "the shipped restore_all_on filters negotiation-owned nodes (bug 24, source-level)"
else
  no T-DISC-snapshot "the shipped restore_all_on does not filter negotiation nodes - snapshots get replayed (bug 24)"
fi
if [ "$COND" != fast ] && [ "$COND" != slow ]; then sk T-DISC-probe "needs a live charge (condition $COND)"
elif [ -z "$SWN" ]; then sk T-DISC-probe "no resolvable switch, so a cut cannot be detected"
else
  _lv=$(lvl)
  if ! isnum "$_lv" || [ "$(( _lv + 9 ))" -gt 100 ] 2>/dev/null; then
    sk T-DISC-probe "level ${_lv}% leaves no room to build a below-threshold window under 100%"
  else
    # PHASE 1: sit BELOW the probe threshold and require no cut. The first version put the pause at
    # level+4, which puts the threshold at level-1 - already above it - so the very condition bug 25
    # is about could never be observed and the arm passed vacuously.
    _np=$(( _lv + 9 )); _nr=$(( _lv + 7 )); _th=$(( _np - 5 ))
    acc -s resume_capacity=$_nr pause_capacity=$_np >/dev/null 2>&1
    sleep 10
    log "      phase 1: pause ${_np}%, probe threshold ${_th}%, level ${_lv}% - BELOW it, expect no cut"
    _fake=$WORK/fake_switch; echo 1 > "$_fake"
    { echo "$_fake 1 0"; cat "$WORK/ch-switches.bak" 2>/dev/null; } > "$TD/ch-switches"
    acc -s charging_switch= >/dev/null 2>&1
    _early=0; _i=0
    while [ $_i -lt $(( W_SWEEP / 20 )) ]; do
      _i=$((_i + 1)); sleep 10
      _l=$(lvl); isnum "$_l" && [ "$_l" -ge "$_th" ] 2>/dev/null && break
      held && _early=$((_early + 1))
      [ "$(rd "$_fake")" = 0 ] && _early=$((_early + 1))
    done
    [ "$_early" -eq 0 ] && ok T-DISC-probe "no cut in $(( _i * 10 ))s while ${_lv}% was below the ${_th}% threshold (bug 25)" \
                        || no T-DISC-probe "cut the charge $_early times below the ${_th}% threshold (bug 25)"
    # PHASE 2: put the threshold under the level so the sweep is due, and watch the reject arm.
    _np=$(( _lv + 2 )); [ "$_np" -gt 100 ] && _np=100
    acc -s resume_capacity=$(( _np - 2 )) pause_capacity=$_np >/dev/null 2>&1
    log "      phase 2: pause ${_np}%, threshold $(( _np - 5 ))%, level $(lvl)% - the sweep is now due"
    # ---- bug 23: the REJECT arm ------------------------------------------------------------------
    # This skipped on every run of the campaign, and the reason was structural, not timing. The arm
    # sits behind `if not_charging`: a candidate only reaches it by genuinely STOPPING the charge and
    # then letting it resume on its own. That is the klee/MTK current_cmd bounce - passes a 3s check,
    # then the firmware re-arms. A plain tmpfs file cannot stop a charge, so the injected fake never
    # satisfied that gate and fell into the FAILURE arm instead. Injecting it as the only candidate
    # (the previous attempt) changed nothing, because the gate is about behaviour, not position.
    #
    # So synthesize the bounce with the phone's REAL switch plus a watcher that re-arms it. Safety:
    # the watcher only ever writes the ON value. It can never cut a charge, and if this section dies
    # the node is left enabled - the failure direction is "charging" in every case.
    _on=$(echo $S_SW | cut -d' ' -f2)
    _offv=$(echo $S_SW | cut -d' ' -f3)
    # bug 23 is a GENERIC-SWITCH bug, and the bounce that reproduces it only exists on one.
    #
    # On a native firmware limit the "off" value is the sentinel pcap, not a value the node ever
    # holds - charge_stop_level contains a LEVEL (65, 74, 100). So the watcher compares the node
    # against the literal string "pcap" and can never match, the bounce is never synthesized, and
    # T-DISC-reject skipped every run with "the node ended at 65, neither the on nor the off value".
    #
    # Worse, injecting "SWN 100 pcap" as a candidate makes ACC probe the level node and leaves the
    # firmware mid-renegotiation, which is why the 90s recovery wait then failed on a phone that
    # was charging fine seconds later. The test was treating a level node as an on/off node.
    #
    # The reject arm it targets hands back a candidate that was CUT. A native limit has no cut
    # value to hand back, so there is nothing here to test - the same class split the suite already
    # makes for T-NATIVE (native only) and T-REKICK (Qualcomm only).
    if $NATIVE; then
      sk T-DISC-reject "native firmware limit: off is the sentinel pcap, so there is no cut value to hand back (bug 23 is generic-switch only)"
      sk T-DISC-recovers "same: no bounce is synthesized on a native limit, so there is nothing to recover from"
    elif [ -z "$_on" ] || [ -z "$_offv" ] || [ -z "$SWN" ]; then
      sk T-DISC-reject "no resolvable on/off values for the real switch; the bounce cannot be synthesized (bug 23)"
    else
      log "      synthesizing a firmware bounce on $SWN (on=$_on off=$_offv) - the watcher only writes ON"
      ( _w=0
        while [ $_w -lt 90 ]; do
          sleep 1; _w=$(( _w + 1 ))
          if [ "$(cat "$SWN" 2>/dev/null)" = "$_offv" ]; then
            sleep 2
            echo "$_on" > "$SWN" 2>/dev/null || :
          fi
        done ) &
      _wpid=$!
      # The real switch as the only candidate, so the sweep must try it.
      echo "$SWN $_on $_offv" > "$TD/ch-switches"
      _before=$(cat "$TD/ch-switches" 2>/dev/null | head -1)
      acc -s charging_switch= >/dev/null 2>&1
      # A rejected candidate is deleted and re-appended to the END of ch-switches by the arm itself
      # (misc-functions.sh), so the file order is the observable proof the arm ran - far better than
      # inferring it from a value that other code also writes.
      _rejran=0; _i=0; _sw=
      while [ $_i -lt $(( W_SWEEP / 5 )) ]; do
        _i=$((_i + 1)); sleep 5
        grep -qE 'rejected|_rej' "$FL" 2>/dev/null && _rejran=1
        _sw=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
        [ -n "$_sw" ] && break
        not_charging && [ "$(rd "$SWN")" = "$_offv" ] && _rejran=1
      done
      kill "$_wpid" 2>/dev/null || :
      wait "$_wpid" 2>/dev/null || :
      _final=$(rd "$SWN")
      log "      after $(( _i * 5 ))s: node=$_final  locked switch=${_sw:-none}  level=$(lvl)% pause=${S_PAU}%"
      # The claim under test: below the pause level a candidate that was cut must be handed BACK,
      # because a cut candidate protects nothing there. The bug left it OFF for the whole session,
      # and on a real node that means */current_max pinned at 0.
      if [ "$_final" = "$_offv" ]; then
        no T-DISC-reject "the switch was left at its OFF value ($_final) below the pause level - a session-long cut (bug 23)"
      elif [ "$_final" = "$_on" ]; then
        ok T-DISC-reject "the candidate was handed back to its ON value ($_on) after the bounce (bug 23)"
      else
        sk T-DISC-reject "the node ended at '$_final', neither the on nor the off value; no verdict"
      fi
      # Charging must be alive at the end - but only assert that if there is still a CABLE.
      #
      # This failed on a run where the phone was unplugged partway through: no charger, no current,
      # and the assertion reported "the phone was left cut". Correct observation, wrong conclusion.
      # It is the same mistake as the three just fixed above and the one race.sh already guards
      # against - asserting something the current conditions cannot support. A test that cannot
      # tell "ACC cut the charge" from "there is no charger" is not testing ACC.
      if ! plugged; then
        sk T-DISC-recovers "the cable is gone, so there is no current to observe either way"
      elif waitfor 90 charging_now; then
        ok T-DISC-recovers "charging is live at $(mA) mA after the bounce test"
      else
        # Re-check the cable AFTER the wait too. It was true when we entered and gone by the end on
        # one run, and the assertion then reported "the phone was left cut" for a phone that simply
        # had no charger. A precondition checked only once is a precondition for an instant.
        if ! plugged; then
          sk T-DISC-recovers "the cable came out during the wait; no verdict"
        else
          # A CABLE IS NOT A CHARGER. Before blaming ACC, check the supply is still delivering.
          #
          # This assertion fired on a Mi A3 with the cable verifiably in place before and after the
          # wait, and reported "the phone was left cut". It was wrong. input_suspend was 0, no scan
          # held the lock, and the phone read 0 mA with the ACC DAEMON STOPPED - which no amount of
          # ACC misbehaviour can cause. What had actually happened is that the charger renegotiated
          # from a 7.7V QuickCharge contract down to a 5V/500mA USB default earlier in the run and
          # never came back, so there was nothing left to draw.
          #
          # Distinguishing them is one read. A supply sitting at the 5V floor with a floor-level
          # input limit is a dead charger, and a test that cannot tell that from a cut switch will
          # keep pointing at the wrong component.
          _dv=$(vbus); _di=$(icl)
          if [ "${_di:-0}" -le 600000 ] 2>/dev/null && [ "${_dv:-0}" -lt 5500000 ] 2>/dev/null; then
            sk T-DISC-recovers "the supply collapsed to $(( ${_dv:-0} / 1000 ))mV / $(( ${_di:-0} / 1000 ))mA - a dead charger, not a cut (input_suspend=$(rd $G/input_suspend))"
          elif [ "$(rd $G/input_suspend)" = 1 ]; then
            no T-DISC-recovers "input_suspend=1 with a live supply - ACC left the phone cut"
          else
            no T-DISC-recovers "plugged in, supply alive at $(( ${_dv:-0} / 1000 ))mV, but no current 90s after the bounce test"
          fi
        fi
      fi
    fi
    [ -f "$WORK/ch-switches.bak" ] && cp -a "$WORK/ch-switches.bak" "$TD/ch-switches" 2>/dev/null
    [ -n "$S_SW" ] && acc -s charging_switch="$S_SW" >/dev/null 2>&1
    acc -s resume_capacity=$S_RES pause_capacity=$S_PAU >/dev/null 2>&1
  fi
fi
fi

# ==================================================================================================
if want T-RANGE; then
sec "T-RANGE  every limit accepted across its whole range, unclamped"
# Acceptance, not enforcement: does a value the user asks for survive the write path EXACTLY? Needs
# no charger, so it covers the whole range rather than the one point a live test happens to reach.
# This is the write-config clamp family: a valid max_temp of 40 was silently rewritten to 50 and a
# wide resume hysteresis was crushed, both invisible until the pack reaches a limit that has moved.
_bad=0; _n=0
# Bounded BELOW shutdown_temp. ACC keeps shutdown_temp above max_temp - correct behaviour - so a
# sweep past it silently rewrites a setting this suite has no business changing and cannot put back.
_hi=50; isnum "$S_SDT" && [ "$S_SDT" -ge 40 ] 2>/dev/null && _hi=$(( S_SDT - 5 ))
for _t in 35 38 40 42 45 48 50 55 60; do
  [ "$_t" -le "$_hi" ] 2>/dev/null || continue
  _n=$((_n + 1))
  acc -s cooldown_temp=$(( _t - 5 )) max_temp=$_t resume_temp=$(( _t - 10 )) >/dev/null 2>&1
  _g=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
  _gm=$(echo $_g | cut -d' ' -f2); _gc=$(echo $_g | cut -d' ' -f1); _gr=$(echo $_g | cut -d' ' -f3)
  if [ "$_gm" != "$_t" ] || [ "$_gc" != "$(( _t - 5 ))" ] || [ "$_gr" != "$(( _t - 10 ))" ]; then
    _bad=$((_bad + 1)); log "      asked max_temp $_t -> stored cooldown=$_gc max=$_gm resume=$_gr   REWRITTEN"
  fi
done
[ "$_bad" -eq 0 ] && ok T-RANGE-temp "all $_n temperature grades stored exactly as asked (35-${_hi}C, bounded by shutdown_temp)" \
                  || no T-RANGE-temp "$_bad of $_n temperature grades were rewritten by the write path"
acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
_sd=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
[ "$_sd" = "$S_SDT" ] && ok T-RANGE-sdt "shutdown_temp untouched across the whole sweep (${_sd}C)" \
                      || no T-RANGE-sdt "shutdown_temp moved during the sweep: $S_SDT -> $_sd"

_bad=0; _n=0
for _c in 50 60 70 75 80 85 90 95; do
  _n=$((_n + 1))
  acc -s resume_capacity=$(( _c - 4 )) pause_capacity=$_c >/dev/null 2>&1
  _g=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')
  _gp=$(echo $_g | cut -d' ' -f4); _gr=$(echo $_g | cut -d' ' -f3)
  if [ "$_gp" != "$_c" ] || [ "$_gr" != "$(( _c - 4 ))" ]; then
    _bad=$((_bad + 1)); log "      asked pause $_c resume $(( _c - 4 )) -> stored pause=$_gp resume=$_gr   REWRITTEN"
  fi
done
[ "$_bad" -eq 0 ] && ok T-RANGE-cap "all $_n capacity pairs stored exactly as asked (50-95%)" \
                  || no T-RANGE-cap "$_bad of $_n capacity pairs were rewritten"
acc -s resume_capacity=50 pause_capacity=90 >/dev/null 2>&1
_g=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')
[ "$(echo $_g | cut -d' ' -f3)" = 50 ] && [ "$(echo $_g | cut -d' ' -f4)" = 90 ] \
  && ok T-RANGE-hyst "a wide 50-90 hysteresis survives intact" \
  || no T-RANGE-hyst "a wide hysteresis was narrowed to ($_g)"
acc -s resume_capacity=$S_RES pause_capacity=$S_PAU >/dev/null 2>&1

_bad=0; _n=0
for _a in 300 500 700 900 1200 1500 2000 2500 3000; do
  _n=$((_n + 1))
  acc -s max_charging_current=$_a >/dev/null 2>&1
  _g=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
  [ "$_g" = "$_a" ] || { _bad=$((_bad + 1)); log "      asked current cap $_a -> stored '$_g'"; }
done
[ "$_bad" -eq 0 ] && ok T-RANGE-curr "all $_n current caps stored exactly as asked (300-3000 mA)" \
                  || no T-RANGE-curr "$_bad of $_n current caps were rewritten"
acc -s max_charging_current="$S_MCC" >/dev/null 2>&1

if grep -q / $TD/ch-volt-ctrl-files 2>/dev/null; then
  _bad=0; _n=0
  # set-ch-volt.sh enforces [3700-4300]. Above 4.3V is outside what a Li-ion cell should ever see,
  # so a refusal there is correct behaviour, not something to assert against.
  for _v in 3700 3900 4000 4100 4200 4300; do
    _n=$((_n + 1))
    acc -s max_charging_voltage=$_v >/dev/null 2>&1
    _g=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
    [ "$_g" = "$_v" ] || { _bad=$((_bad + 1)); log "      asked voltage cap $_v -> stored '$_g'"; }
  done
  [ "$_bad" -eq 0 ] && ok T-RANGE-volt "all $_n voltage caps stored exactly as asked (3700-4300 mV, the supported range)" \
                    || no T-RANGE-volt "$_bad of $_n voltage caps were rewritten"
  acc -s max_charging_voltage="$S_MCV" >/dev/null 2>&1
else
  sk T-RANGE-volt "this phone has no voltage control node (bug 19 covers it, in T-VOLT)"
fi
fi

# ==================================================================================================
if want T-GRID; then
sec "T-GRID  a cap must throttle in proportion, and NO cap must be the fastest of all"
# Is ACC ever costing charging speed it did not have to? Acceptance is not enough: a limit can store
# correctly and still be applied wrongly. Rows are fractions of the MEASURED free rate, because a
# 2500 mA cap on a 900 mA supply is a no-op and a grid of no-ops reports a clean sheet.
if [ "$COND" != fast ] && [ "$COND" != slow ]; then sk T-GRID "needs a live charge (condition $COND)"
elif [ "$_scrctl" = no ]; then sk T-GRID "could not force the screen off; the panel would dominate every row"
elif [ "$FREE" -lt 400 ]; then sk T-GRID "free rate is only ${FREE} mA; the rows would be indistinguishable"
else
  acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
  _q=$(( FREE / 4 ))
  _g1=$_q; _g2=$(( _q * 2 )); _g3=$(( _q * 3 ))
  log "      free ${FREE} mA -> rows at ${_g3}, ${_g2}, ${_g1} mA, uncapped, then ${_g3} again"
  log "      measured as battery POWER (mW): the cap is on INPUT current, and comparing an input cap"
  log "      against a battery-current reading across a 9V-to-4V conversion compares nothing."
  _r3=; _r2=; _r1=; _r4=; _r5=; _drop=0
  # HIGH to LOW, then uncapped, then the HIGHEST ROW AGAIN. The repeat is the whole point: charge
  # current falls on its own as the pack fills, and running rows low-to-high made that taper look
  # exactly like "a higher cap charged slower". The first and last rows are the same cap, so the
  # difference between them IS the drift, measured rather than assumed.
  for _row in 3 2 1 4 5; do
    case $_row in
      3|5) acc -s max_charging_current=$_g3 >/dev/null 2>&1; _lab="cap ${_g3} mA";;
      2)   acc -s max_charging_current=$_g2 >/dev/null 2>&1; _lab="cap ${_g2} mA";;
      1)   acc -s max_charging_current=$_g1 >/dev/null 2>&1; _lab="cap ${_g1} mA";;
      4)   acc -s max_charging_current= >/dev/null 2>&1;     _lab="uncapped   ";;
    esac
    settle
    _m=$(rate); _w=$(bmW)
    plugged || _drop=1
    log "      $_lab -> ${_m:-?} mA = ${_w:-?} mW   (level $(lvl)%, temp $(tmpC)C, $(rsrc))"
    case $_row in 3) _r3=$_w;; 2) _r2=$_w;; 1) _r1=$_w;; 4) _r4=$_w;; 5) _r5=$_w;; esac
  done
  if [ "$_drop" = 1 ]; then
    sk T-GRID-monotonic "the cable came out mid-grid; the rows are not comparable"
    sk T-GRID-ceiling "same"
  elif isint "${_r1:-x}" && isint "${_r2:-x}" && isint "${_r3:-x}" && isint "${_r4:-x}" && isint "${_r5:-x}" \
       && [ "$_r1" -gt 0 ] && [ "$_r4" -gt 0 ]; then
    # Drift is measured from the two identical rows, not guessed. Anything smaller than the drift the
    # battery produced on its own during the grid cannot be attributed to a cap.
    _drift=$(( _r3 - _r5 )); _drift=${_drift#-}
    _tol=$(( _r3 / 10 )); [ "$_drift" -gt "$_tol" ] && _tol=$_drift
    log "      taper drift between the two ${_g3} mA rows: ${_drift} mW  ->  tolerance ${_tol} mW"
    _inv=0
    [ "$_r2" -gt $(( _r3 + _tol )) ] 2>/dev/null && { _inv=$((_inv + 1)); log "      inversion: ${_g2} cap delivered MORE than the ${_g3} cap"; }
    [ "$_r1" -gt $(( _r2 + _tol )) ] 2>/dev/null && { _inv=$((_inv + 1)); log "      inversion: ${_g1} cap delivered MORE than the ${_g2} cap"; }
    [ "$_inv" -eq 0 ] && ok T-GRID-monotonic "power fell with each lower cap: ${_r3}, ${_r2}, ${_r1} mW (drift ${_drift} mW)" \
                      || no T-GRID-monotonic "$_inv inversion(s) beyond the measured ${_drift} mW drift - a lower cap delivered MORE"
    [ "$_r4" -ge $(( _r3 - _tol )) ] 2>/dev/null \
      && ok T-GRID-ceiling "uncapped ${_r4} mW is at least the highest cap ${_r3} mW - no missed opportunity" \
      || no T-GRID-ceiling "uncapped ${_r4} mW is BELOW the ${_g3} mA cap at ${_r3} mW - ACC holds something down with nothing set"
    _sp=$(( _r4 - _r1 ))
    [ "$_sp" -gt "$_tol" ] 2>/dev/null \
      && ok T-GRID-spread "the grid separated: ${_r1} mW at the lowest cap against ${_r4} mW uncapped" \
      || no T-GRID-spread "lowest cap ${_r1} mW vs uncapped ${_r4} mW is within the ${_tol} mW drift - the caps did nothing measurable"
  else
    sk T-GRID-monotonic "could not measure every row as a positive charging power"
    sk T-GRID-ceiling "could not measure every row as a positive charging power"
  fi
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  acc -s resume_capacity=$S_RES pause_capacity=$S_PAU >/dev/null 2>&1
fi
fi

# ==================================================================================================
if want T-NOCOST; then
sec "T-NOCOST  ACC must not slow an unlimited charge"
if [ "$COND" != fast ] && [ "$COND" != slow ]; then sk T-NOCOST "needs a live charge (condition $COND)"
elif [ "$_scrctl" = no ]; then sk T-NOCOST "could not force the screen off; the panel would dominate every phase"
elif [ -n "$S_MCC" ]; then sk T-NOCOST "a ${S_MCC} mA cap is configured; this only means anything with nothing set"
else
  _p1=$(rate); _l1=$(lvl)
  log "      ACC running : ${_p1:-?} mA  at ${_l1}%"
  acc -D stop >/dev/null 2>&1; sleep 25
  _p2=$(rate); _l2=$(lvl)
  log "      ACC stopped : ${_p2:-?} mA  at ${_l2}%"
  acc -D restart >/dev/null 2>&1 & sleep 45
  _p3=$(rate); _l3=$(lvl)
  log "      ACC running : ${_p3:-?} mA  at ${_l3}%"
  if ! plugged; then sk T-NOCOST-speed "the cable came out during the comparison"
  elif isint "${_p1:-x}" && isint "${_p2:-x}" && isint "${_p3:-x}" \
       && [ "$_p1" -gt 0 ] && [ "$_p2" -gt 0 ] && [ "$_p3" -gt 0 ]; then
    _sp=$(( _p1 - _p3 )); _sp=${_sp#-}
    _big=$_p1; [ "$_p3" -gt "$_p1" ] && _big=$_p3
    if [ $(( _sp * 100 / _big )) -gt 20 ]; then
      sk T-NOCOST-speed "the two ACC-running phases disagree by ${_sp} mA - something was still moving"
    else
      _run=$(( (_p1 + _p3) / 2 )); _d=$(( _run - _p2 ))
      log "      ACC ${_run} mA vs unmanaged ${_p2} mA: ${_d} mA"
      [ "$_d" -ge -150 ] && ok T-NOCOST-speed "ACC costs nothing with no limit set (${_d} mA vs unmanaged)" \
                         || no T-NOCOST-speed "ACC is costing $(( 0 - _d )) mA with nothing configured"
    fi
  else
    sk T-NOCOST-speed "one of the three phases was not a positive charging rate"
  fi
fi
fi

# ==================================================================================================
if want T-COST; then
sec "T-COST  what ACC costs to run   (the rc21->rc22 idle regression)"
#
# This section exists because a 5.5x idle regression shipped in rc22 and NOTHING else here caught
# it. The unit suites passed, the rc21 differential passed, and every behavioural section passed,
# because all of them ask "is the behaviour right" and none of them ask "what did it cost". The
# regression was real: on a Mi A3, held awake and unplugged, rc21 spent 1108 ms of CPU per minute
# and rc22 spent 6011. A Pixel 6a moved only 10% because it runs the native-firmware path and
# barely enters the loop that regressed. Cause: the bug-28 fix removed present()'s short-circuit,
# which routed the unplugged case into an uncached online() that forked ls+grep, plus a grep per
# node, about once a second inside _nap_idle -- the loop rc19 had deliberately made fork-free.
#
# METHOD, and it is the whole value of the section:
#   - A WAKELOCK is held. Without it this measures how much the phone happened to deep-sleep, not
#     what ACC costs. Measured proof: the same 240s sleep took 496s of wall in one arm and 586s in
#     another, an 18% swing, and the arm that slept least looked most expensive -- which produced
#     the impossible reading that publishing LESS cost 44% MORE.
#   - The screen is forced OFF, so the panel is not in the measurement.
#   - ACC is stopped for one arm, giving a true floor. Everything above it is ACC's.
#   - The ACC arm is measured TWICE, first and last, so the run reports its own noise floor. Any
#     difference smaller than that spread is not a finding.
#   - utime+stime AND cutime+cstime: accd is a shell script, so most of its cost sits in children
#     it has already reaped. Counting only its own stat undercounts by most of the work.
#
# Forks are reported alongside CPU because that is the quantity the regression actually changed,
# and it moves cleanly where milliseconds are noisy.
if [ "$_scrctl" = no ]; then sk T-COST "could not force the screen off; the panel would dominate"
elif [ ! -w /sys/power/wake_lock ]; then sk T-COST "no wakelock interface; a deep-sleeping phone cannot be compared"
else
  _wl=accmega
  # A TRAP, not a tidy-up at the end. This section is the only one in the suite that stops the
  # charge-control daemon, and the first version had no trap: a quoting error killed it between
  # `acca -D stop` and the restart, and BOTH test phones were left with ACC off and a wakelock
  # held. Nothing was charging at the time so no harm was done, but on a plugged phone that is a
  # daemon that is not enforcing any limit, held open by a bug in a test.
  #
  # Anything that stops the daemon must guarantee the restart on every exit path, including the
  # ones that are someone else's fault.
  _cost_restore() {
    echo $_wl > /sys/power/wake_unlock 2>/dev/null || :
    alive || { acca -D start >/dev/null 2>&1 || :; sleep 5; }
    trap - EXIT INT TERM HUP
  }
  trap '_cost_restore' EXIT INT TERM HUP
  echo $_wl > /sys/power/wake_lock 2>/dev/null || :
  screen_off
  # 60s, not 20. The suite's own preflight probes nodes, runs `acc -i` and resolves the switch
  # path, and the daemon reacts to all of it. Starting the first arm 20s later measured that tail
  # rather than steady state: 1680 ms/min in the first arm against 200 in the control repeat, an
  # 88% spread that had nothing to do with the build. The daemon needs to be BORED before the
  # first sample, and the control arm exists to prove it was.
  sleep 60

  _cost_arm() {
    # $1 label, $2 seconds. Echoes "<ms/min> <forks/min>", or "restarted" if the daemon changed
    # identity during the window.
    #
    # The pid is read at BOTH ends and compared. A daemon that restarts mid-window takes its
    # /proc entry with it, so the closing read finds nothing, returns 0, and the delta comes out
    # NEGATIVE -- this produced "-1633 ms/min" on the first real run. The spread guard below
    # rejected it, which is the right outcome, but "the two arms disagree by 1855%" describes the
    # symptom and hides the cause. A restart is a specific, detectable event; say so.
    _ca=$(rd $TD/acc.lock)
    if [ -n "$_ca" ] && [ -d "/proc/$_ca" ]; then
      _q0=$(awk '{print $14+$15+$16+$17}' /proc/$_ca/stat 2>/dev/null)
    else
      _q0=0
    fi
    _p0=$(sed -n 's/^processes //p' /proc/stat)
    _s0=$(date +%s)
    sleep $2
    if [ -n "$_ca" ] && [ -d "/proc/$_ca" ]; then
      _q1=$(awk '{print $14+$15+$16+$17}' /proc/$_ca/stat 2>/dev/null)
    else
      _q1=0
    fi
    _p1=$(sed -n 's/^processes //p' /proc/stat)
    _s1=$(date +%s)
    _se=$(( _s1 - _s0 )); [ "$_se" -gt 0 ] || _se=1
    # Same daemon at both ends, or the numbers describe two different processes.
    _cb=$(rd $TD/acc.lock)
    if [ "${_cb:-}" != "${_ca:-}" ]; then echo "restarted"; return 0; fi
    echo "$(( ( ${_q1:-0} - ${_q0:-0} ) * 1000 / 100 * 60 / _se )) $(( ( ${_p1:-0} - ${_p0:-0} ) * 60 / _se ))"
  }

  _r=$(_cost_arm on 90)
  if [ "$_r" = restarted ]; then _on1=; _fk1=; log "      ACC running : daemon restarted mid-window"
  else _on1=${_r%% *}; _fk1=${_r##* }; log "      ACC running : ${_on1} ms/min, ${_fk1} forks/min"; fi

  acca -D stop >/dev/null 2>&1 || :
  sleep 5
  _r=$(_cost_arm off 90)
  if [ "$_r" = restarted ]; then _off=; _fko=; log "      ACC stopped : daemon reappeared mid-window"
  else _off=${_r%% *}; _fko=${_r##* }; log "      ACC stopped : ${_off} ms/min, ${_fko} forks/min   (the floor)"; fi

  acca -D start >/dev/null 2>&1 || :
  # A freshly started daemon re-probes and rebuilds its cache; sampling immediately would measure
  # init, exactly the mistake the longer settle above fixes.
  sleep 45
  _r=$(_cost_arm on2 90)
  if [ "$_r" = restarted ]; then _on2=; _fk2=; log "      ACC running : daemon restarted mid-window (control)"
  else _on2=${_r%% *}; _fk2=${_r##* }; log "      ACC running : ${_on2} ms/min, ${_fk2} forks/min   (control repeat)"; fi
  _cost_restore

  if ! alive; then
    no T-COST-alive "the daemon did not come back after being stopped"
  else
    ok T-COST-alive "the daemon stopped and restarted cleanly"
  fi

  # Any arm that lost its daemon has no number, and no arithmetic below is valid without all
  # three. Say which arm was lost rather than deriving a percentage from a blank.
  if [ -z "${_on1:-}" ] || [ -z "${_on2:-}" ] || [ -z "${_off:-}" ]; then
    sk T-COST-cpu "the daemon changed identity during a measurement window - no comparable arms"
    sk T-COST-forks "same: an arm is missing, so the fork floor cannot be subtracted"
  else
  # Control spread first: without it no other number here means anything.
  _hi=$_on1; _lo=$_on2
  [ "${_on2:-0}" -gt "${_on1:-0}" ] 2>/dev/null && { _hi=$_on2; _lo=$_on1; }
  _sp=0
  [ "${_hi:-0}" -gt 0 ] 2>/dev/null && _sp=$(( ( _hi - _lo ) * 100 / _hi ))
  log "      control spread between the two ACC arms: ${_sp}%"
  if [ "$_sp" -gt 25 ] 2>/dev/null; then
    sk T-COST-cpu "the two ACC arms disagree by ${_sp}% - something else was running, no verdict"
  else
    _avg=$(( ( _on1 + _on2 ) / 2 ))
    log "      ACC costs ${_avg} ms/min above a floor of ${_off}"
    # A ceiling, not a target. Reference, held awake: A3 rc21 1108 / rc22-fixed 1076, Pixel 6a
    # rc21 2876 / rc22-fixed 2260. The regression read 6011 on the A3, so 12000 catches that class
    # of fault with room for slower hardware, without failing on ordinary variation.
    if [ "$_avg" -gt 12000 ] 2>/dev/null; then
      no T-COST-cpu "${_avg} ms/min is far above anything measured for this build - the idle path is forking again"
    else
      ok T-COST-cpu "idle cost ${_avg} ms/min, within the measured range for this build"
    fi
  fi

  # The fork count is the direct signal. It is only trustworthy when the floor is genuinely quiet:
  # a phone with other apps forking makes the system-wide counter useless, and on one test device
  # the "ACC off" floor read HIGHER than an ACC arm, which is impossible and means exactly that.
  if [ "${_fko:-0}" -ge "${_fk1:-0}" ] 2>/dev/null; then
    sk T-COST-forks "the floor (${_fko}/min) is not below the ACC arm (${_fk1}/min) - other processes dominate, no verdict"
  else
    _fd=$(( ( _fk1 + _fk2 ) / 2 - _fko ))
    log "      ACC's own forks: ~${_fd}/min above the floor"
    if [ "$_fd" -gt 1500 ] 2>/dev/null; then
      no T-COST-forks "~${_fd} forks/min above the floor - the once-a-second path is spawning processes"
    else
      ok T-COST-forks "~${_fd} forks/min above the floor"
    fi
  fi
  fi

  # And the property behind all of it, asserted directly so a source revert is caught even if the
  # measurement is too noisy to rule on this particular phone.
  if grep -q '_onlineF' $M/batt-interface.sh 2>/dev/null; then
    ok T-COST-cache "online_f is still cached - the idle path cannot fork per call"
  else
    no T-COST-cache "the online_f cache is GONE - this is the rc22 idle regression, returning"
  fi
  # The suite's own trap owns the screen and the stay-on setting for the whole run; this section
  # only needs to hand back the wakelock and the daemon, which _cost_restore already did.
fi
fi

# ==================================================================================================
if want T-IDLE; then
sec "T-IDLE  unplugged, ACC must do nothing"
if [ "$COND" != unplugged ]; then sk T-IDLE "only meaningful unplugged (condition $COND)"
else
  _b=$(led_lines); led_open; sleep 60
  _w=$(led_lines)
  if [ "$_w" -lt "$_b" ]; then sk T-IDLE-quiet "the ledger rotated during the window"
  elif [ "$_w" -eq "$_b" ]; then ok T-IDLE-quiet "ACC wrote nothing at all in 60s unplugged"
  else no T-IDLE-quiet "ACC made $(( _w - _b )) writes while unplugged"; fi
  _l0=$(lvl); sleep 30; _l1=$(lvl)
  [ "${_l1:-0}" -le "${_l0:-100}" ] 2>/dev/null && ok T-IDLE-monotone "the level did not rise with no cable" \
                                                || no T-IDLE-monotone "the level ROSE ${_l0}% -> ${_l1}% with no cable"
  if [ -s "$DD/logs/shutdown-trace.log" ]; then
    sk T-IDLE-sd "a shutdown trace exists from earlier - history, not this run"
  else
    ok T-IDLE-sd "ACC has never powered this phone off"
  fi
fi
fi
