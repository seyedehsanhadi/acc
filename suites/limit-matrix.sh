#!/system/bin/sh
# acc-limit-matrix.sh - all 15 combinations of ACC's four charging limits, on real hardware.
#
#   su -c 'sh "$(ls /sdcard/Download/acc-limit-matrix.sh /storage/emulated/0/Download/acc-limit-matrix.sh /data/media/0/Download/acc-limit-matrix.sh 2>/dev/null | head -1)"'
#
# WHAT IT ANSWERS
#   Users set capacity, temperature, current and voltage limits together, and expect the result to
#   be predictable. Which one wins? Do two throttles compose or fight? Does a setting that cannot
#   possibly act say so, or does it just sit there looking applied? This runs every subset of the
#   four and checks the outcome against what the daemon's logic says it should be.
#
# THE LOGIC BEING TESTED (accd.sh)
#   PAUSE   = mt_reached OR _ge_pause_cap                       an OR of the two binary limits
#   RESUME  = _le_resume_cap AND temp <= resume_temp            an AND of both
#   both of those sit inside `if is_charging`, and the throttles (current, voltage) are only
#   applied in the charging branch. So the precedence is:
#       PAUSE (capacity | temperature)  >  THROTTLE (current, voltage)
#   A pause is binary and dominates. A throttle only shapes a charge that is already permitted.
#
# HOW CHARGE DIRECTION IS DECIDED
#   Never from the current magnitude, and never from an assumed sign. current_now's convention is
#   per-device, and on dual-path PMICs it FLIPS with the charge mode (curtana: positive on the 5V
#   trickle path, negative on the 9V fast path). Magnitude alone is worse: a phone running off its
#   own battery reports a healthy-looking current flowing the wrong way, which produced a page of
#   confident nonsense here on an A3 that was sitting at a capacity pause throughout.
#   charge_counter is sign-convention-free ground truth, but it is not always fast enough to judge a
#   single case: the same A3 at ~370mA moved it 0 uAh across 31s.
#   So the two are combined. ONE long counter window at the baseline, taken while the phone is
#   provably charging with every limit lifted, establishes which current sign means charging on this
#   phone. Every case after that reads the signed current, which is fast and fine-grained. ACC's own
#   arbitrated verdict is recorded alongside, and a disagreement is reported, never resolved
#   silently -- a pack that is provably filling while ACC says Discharging is the failure that makes
#   all four limits blind at once.
#
# HOW A PAUSE IS DETECTED, AND WHY IT IS NOT ONE TEST
#   Generic switch: paused when the node reads its recorded off value (input_suspend 1).
#   Native firmware limit: there is no off value. ACC records the sentinel `pcap`, which
#   charge_stop_level never contains, so "node != off value" is ALWAYS true and says nothing. The
#   pause there is charge_stop_level <= level. Measured on a Pixel 6a, where the single generic test
#   called a perfectly correct temperature pause "the switch is still ON".
#
# THE FOUR OBSERVABLE STATES
#   PAUSED    ACC is holding charging off       a capacity or temperature limit acted
#   BLOCKED   not paused, yet nothing flows     a throttle is tight enough to stop the charge
#   THROTTLED not paused, filling below free    a current/voltage cap is shaping the rate
#   FULL      not paused, filling at free rate  nothing is limiting
#   Separating PAUSED from BLOCKED is the whole point: they look identical on a current meter and
#   mean completely different things.
#
# SAFETY
#   shutdown_temp is never written. Every setting is saved before anything changes and restored on
#   EXIT/INT/TERM/HUP. Only ACC settings are written; no charging node is touched directly.

DL=
for _d in /sdcard/Download /storage/emulated/0/Download /storage/self/primary/Download \
          /data/media/0/Download /sdcard/download /data/local/tmp; do
  [ -d "$_d" ] && [ -w "$_d" ] && { DL=$_d; break; }
done
[ -n "$DL" ] || DL=/data/local/tmp
OUT=$DL/acc-matrix-$(date +%Y%m%d-%H%M%S).txt

PS=/sys/class/power_supply
TD=/dev/.vr25/acc
CFG=/data/adb/vr25/acc-data/config.txt
IFACE=$TD/.batt-interface.sh
P=0; F=0; SKIP=0
SETTLE=40
WIN=20
CCWIN=150        # CEILING for the counter window, not a fixed cost: measure_cc returns as soon
                 # as the answer is unambiguous, which is usually within 10-25s
USE_CC=false

log(){ echo "$*" >> "$OUT"; }
say(){ echo "$*"; log "$*"; }
ok(){   P=$((P+1)); say "  PASS  $*"; }
no(){   F=$((F+1)); say "  FAIL  $*"; }
skip(){ SKIP=$((SKIP+1)); say "  skip  $*"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
abspath(){ case "${1:-}" in ''|/*) echo "${1:-}";; *) echo "$PS/$1";; esac; }

# ---- resolve the battery interface the way ACC does -------------------------------------------------
N_CAP=; N_ST=; N_CUR=; N_TEMP=; N_VOLT=; N_CC=; AMPF=
if [ -f "$IFACE" ]; then
  . "$IFACE" 2>/dev/null || :
  N_CAP=$(abspath "${battCapacity:-}"); N_ST=$(abspath "${battStatus:-}")
  N_CUR=$(abspath "${currFile:-}");     N_TEMP=$(abspath "${temp:-}")
  N_VOLT=$(abspath "${voltNow:-}");     AMPF=${ampFactor_:-}
  unset batt battCapacity battStatus currFile curThen temp voltNow ampFactor_ idleThreshold
fi
[ -n "$(rd "$N_CAP")" ] || { for _d in $PS/*; do
    isnum "$(rd "$_d/capacity")" && [ -n "$(rd "$_d/status")" ] || continue
    N_CAP=$_d/capacity; N_ST=$_d/status; N_TEMP=$_d/temp
    N_CUR=$_d/current_now; N_VOLT=$_d/voltage_now; break
  done; }
N_CC=${N_CAP%capacity}charge_counter
isnum "$AMPF" || AMPF=1000000

lvl(){ rd "$N_CAP"; }
kst(){ rd "$N_ST"; }
tempC(){ _t=$(rd "$N_TEMP"); isnum "$_t" && echo $((_t / 10)) || echo ""; }
mV(){ _v=$(rd "$N_VOLT"); isnum "$_v" && echo $((_v / 1000)) || echo ""; }
mAmag(){ _c=$(rd "$N_CUR"); _c=${_c#-}; isnum "$_c" || { echo ""; return; }
         [ "$AMPF" = 1000 ] && echo "$_c" || echo $((_c / 1000)); }
cc(){ _c=$(rd "$N_CC"); _c=${_c#-}; isnum "$_c" && echo "$_c" || echo ""; }
accstat(){ acc -i 2>/dev/null | sed -n 's/^status //p' | head -1; }

SWSPEC=$(sed -n 's/^chargingSwitch=(//p' "$CFG" 2>/dev/null | tr -d ')' | sed 's/ --$//')
SWN=$(echo "$SWSPEC" | cut -d' ' -f1); SWOFF=$(echo "$SWSPEC" | cut -d' ' -f3)
case "$SWN" in ''|/*) : ;; *) SWN=$PS/$SWN ;; esac
SWOK=false; [ -n "$SWN" ] && [ -n "$(rd "$SWN")" ] && SWOK=true

# Switch CLASS. A generic switch holds a real off value (input_suspend 1, charging_enabled 0) and
# reading the node tells you what ACC decided. A native firmware limit does not: its recorded off
# value is the sentinel `pcap`, a string charge_stop_level never contains, so "node != off value" is
# ALWAYS true there and cannot distinguish a pause from a throttle. On native the pause is
# charge_stop_level <= level. Measured on a Pixel 6a, where the naive test called a correct
# temperature pause "the switch is still ON".
NATIVE=false
case "$SWOFF" in ''|*[!0-9]*) $SWOK && NATIVE=true;; esac
paused(){
  if $NATIVE; then
    _sv=$(rd "$SWN"); _lv=$(lvl)
    isnum "$_sv" && isnum "$_lv" || { [ "$(kst)" != Charging ]; return; }
    [ "$_sv" -le "$_lv" ]
  elif $SWOK; then
    [ "$(rd "$SWN")" = "$SWOFF" ]
  else
    [ "$(kst)" != Charging ]
  fi
}
sw_on(){ ! paused; }

cfg(){ sed -n "s/^$1=//p" "$CFG" 2>/dev/null | head -1; }
cfgT(){ sed -n 's/^temperature=(//p' "$CFG" 2>/dev/null | tr -d ')' | cut -d' ' -f"$1"; }
cfgC(){ sed -n 's/^capacity=(//p'    "$CFG" 2>/dev/null | tr -d ')' | cut -d' ' -f"$1"; }
cfg1(){ cfg "$1" | tr -d '()' | cut -d' ' -f1; }

S_SHUT=$(cfgC 1); S_COOL=$(cfgC 2); S_RES=$(cfgC 3); S_PAUSE=$(cfgC 4)
S_CT=$(cfgT 1); S_MT=$(cfgT 2); S_RT=$(cfgT 3); S_ST=$(cfgT 4)
S_MCC=$(cfg1 maxChargingCurrent); S_MCV=$(cfg1 maxChargingVoltage)
TOUCHED=false
restore(){
  $TOUCHED || return 0
  acc -s shutdown_capacity="$S_SHUT" cooldown_capacity="$S_COOL" \
         resume_capacity="$S_RES" pause_capacity="$S_PAUSE" >/dev/null 2>&1
  acc -s cooldown_temp="$S_CT" max_temp="$S_MT" resume_temp="$S_RT" shutdown_temp="$S_ST" >/dev/null 2>&1
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  acc -s max_charging_voltage="$S_MCV" >/dev/null 2>&1
}
finish(){
  trap - EXIT INT TERM HUP
  [ "$(cat $LOCK 2>/dev/null)" = "$$" ] && rm -f $LOCK 2>/dev/null
  say ""; say "--- restoring your settings ---"
  restore; sleep 10
  say "capacity   : $(cfg capacity)"
  say "temperature: $(cfg temperature)"
  say "current    : $(cfg maxChargingCurrent)   voltage: $(cfg maxChargingVoltage)"
  D=$(rd $TD/acc.lock)
  { [ -n "$D" ] && [ -d "/proc/$D" ] && say "daemon     : alive"; } || say "daemon     : DOWN  <-- mention this"
  say ""; say "=== $P passed, $F failed, $SKIP skipped ==="
  say "$OUT"
  exit 0
}
# Two of these running at once fight over the same config: the second reads the first's temporary
# values as "saved" and restores those at the end, leaving the phone on settings the user never
# chose. Seen for real on a Pixel 6a. One at a time.
LOCK=$TD/.matrix-lock
_lp=$(cat $LOCK 2>/dev/null)
if [ -n "$_lp" ] && [ -d "/proc/$_lp" ]; then
  echo "This test is already running (pid $_lp). Wait for it to finish, or: kill $_lp"
  exit 0
fi
echo $$ > $LOCK 2>/dev/null || :
trap finish EXIT INT TERM HUP

# ---- direction: calibrated once, then read from the current sign ------------------------------------
# charge_counter is sign-convention-free ground truth, but on some gauges it only updates coarsely:
# the Mi A3 charging at ~370mA moved it 0 uAh across 31s. Too slow to judge a case on, and judging a
# case on |current| instead is what produced a page of confident nonsense on a phone that was sitting
# at a capacity pause the whole time.
# So: spend one LONG counter window at the baseline, while the phone is provably charging with every
# limit lifted, to learn which current SIGN means charging on this phone. After that the signed
# current is both fast and trustworthy, and the kernel status is kept as a cross-check.
POL=; CALW=120
calibrate(){
  _c0=$(cc)
  _sum=0; _n=0; _i=0
  while [ $_i -lt $CALW ]; do
    _s=$(rd "$N_CUR")
    case "${_s:-x}" in ''|x|*[!0-9-]*) : ;; *) _sum=$(( _sum + _s )); _n=$((_n + 1));; esac
    _i=$((_i + 5)); sleep 5
  done
  _c1=$(cc)
  [ "$_n" -gt 0 ] || { echo "  calibration: current unreadable"; return 1; }
  _avg=$(( _sum / _n ))
  _d=
  [ -n "$_c0" ] && [ -n "$_c1" ] && _d=$(( _c1 - _c0 ))
  log "  calibration: charge_counter moved ${_d:-?} uAh in ${CALW}s, mean current ${_avg}"
  if [ -n "$_d" ] && [ "$_d" -ge 2000 ]; then
    case "$_avg" in -*) POL=-;; *) POL=+;; esac
    log "  the counter proves the pack was FILLING, and the current read ${_avg}: charging is '${POL}'"
  elif [ -n "$_d" ] && [ "$_d" -le -2000 ]; then
    case "$_avg" in -*) POL=+;; *) POL=-;; esac
    log "  the counter proves the pack was DRAINING with current ${_avg}: charging is '${POL}'"
  elif [ "$(kst)" = Charging ] && [ "$_avg" != 0 ]; then
    case "$_avg" in -*) POL=-;; *) POL=+;; esac
    log "  the counter is too coarse to move here; the kernel says Charging, so charging is '${POL}'"
  else
    return 1
  fi
  return 0
}

# signed charging rate in mA: positive = pack filling, negative = draining
rate(){
  _s=$(rd "$N_CUR")
  case "${_s:-x}" in ''|x|*[!0-9-]*) echo ""; return;; esac
  case "$POL" in
    -) case "$_s" in -*) _s=${_s#-};; *) _s=-$_s;; esac;;
  esac
  [ "$AMPF" = 1000 ] && echo "$_s" || echo $(( _s / 1000 ))
}
# Counter-based rate. The charge counter has no sign convention to get wrong, so this is the only
# honest instrument on a phone whose current sign moves. It needs a long window: the counter is
# quantised (a Mi A3 steps 28600 uAh at a time, roughly once a minute), so a short window reads
# either zero or one whole quantum and nothing in between.
measure_cc(){
  # Adaptive, not a flat window. The counter is quantised (a Mi A3 steps 28600 uAh at a time), so the
  # old fixed 180s was sized for the worst case and paid it on every row - an hour for 16 cases.
  # Poll instead, and stop the moment the answer is unambiguous:
  #   - the counter has moved at all          -> the sign is settled, return the rate
  #   - nothing has moved AND |I| is tiny     -> not filling; that IS the answer, return 0
  # Only a slow, genuinely ambiguous case pays the full ceiling.
  _ca=$(cc); _ta=$(date +%s); _el=0
  while [ $_el -lt $CCWIN ]; do
    sleep 5; _el=$(( _el + 5 ))
    _cb=$(cc)
    case "${_ca:-x}${_cb:-x}" in *x*) echo ""; return;; esac
    _d=$(( _cb - _ca ))
    if [ "$_d" -ne 0 ]; then
      _tb=$(date +%s); _dt=$(( _tb - _ta )); [ "$_dt" -gt 0 ] 2>/dev/null || _dt=$_el
      echo $(( _d * 3600 / _dt / 1000 ))
      return
    fi
    # Counter still. If the current sensor also reads near zero, nothing is flowing either way and
    # waiting longer cannot change that. Needs a few seconds of agreement, not one sample.
    if [ $_el -ge 20 ] && [ "$(mAmag)" -lt "$NOISE" ] 2>/dev/null; then echo 0; return; fi
  done
  echo 0
}

# median-ish of several samples, so one blip cannot decide a case
measure(){
  # On a phone where the current sign is not stable, the signed-current path below is measuring a
  # convention that changed underneath it. POL is calibrated ONCE at baseline, so a flip mid-run
  # inverts every case after it -- which is how a phone charging at full rate reported PAUSED, and
  # an unlimited control case reported THROTTLED. ACC arms .dpol_unstable when it sees the sign
  # flip, so that marker is the signal to switch instruments rather than a guess of our own.
  $USE_CC && { measure_cc; return; }
  _lo=; _hi=; _tot=0; _cnt=0; _i=0
  while [ $_i -lt $WIN ]; do
    _r=$(rate)
    if [ -n "$_r" ]; then _tot=$(( _tot + _r )); _cnt=$((_cnt + 1)); fi
    _i=$((_i + 4)); sleep 4
  done
  [ "$_cnt" -gt 0 ] && echo $(( _tot / _cnt )) || echo ""
}

# A quick counter sample, for reporting a row whose verdict is already settled by the switch state.
# Not a precise rate and not used as one: classify() has already decided PAUSED before this is read.
measure_short(){
  _sa=$(cc); _st0=$(date +%s); _sel=0
  while [ $_sel -lt 25 ]; do
    sleep 5; _sel=$(( _sel + 5 ))
    _sb=$(cc)
    case "${_sa:-x}${_sb:-x}" in *x*) echo ""; return;; esac
    [ "$(( _sb - _sa ))" -ne 0 ] && break
  done
  _st1=$(date +%s); _sdt=$(( _st1 - _st0 )); [ "$_sdt" -gt 0 ] 2>/dev/null || _sdt=$_sel
  echo $(( (_sb - _sa) * 3600 / _sdt / 1000 ))
}

# classify: $1 = mean charging rate in mA -> PAUSED | BLOCKED | THROTTLED | FULL | DRAINING | UNKNOWN
classify(){
  _d=$1
  [ -n "$_d" ] || { echo UNKNOWN; return; }
  if paused; then echo PAUSED; return; fi
  if [ "$_d" -le "-$NOISE" ]; then echo DRAINING; return; fi
  if [ "$_d" -lt "$NOISE" ]; then echo BLOCKED; return; fi
  if [ "$_d" -lt $(( FREE * 70 / 100 )) ]; then echo THROTTLED; else echo FULL; fi
}

# ---- header -------------------------------------------------------------------------------------------
{
  echo "=== ACC limit matrix ==="
  echo "date   : $(date)"
  echo "acc    : $(sed -n 's/^versionCode=//p' /data/adb/vr25/acc/module.prop 2>/dev/null)"
  echo "device : $(getprop ro.product.device 2>/dev/null) / android $(getprop ro.build.version.release 2>/dev/null)"
  echo "switch : ${SWN:-none} off=$SWOFF readable=$SWOK"
  echo "gauge  : level=$N_CAP temp=$N_TEMP volt=$N_VOLT current=$N_CUR ampFactor=$AMPF"
  echo "         charge_counter=$N_CC -> $(cc)"
  echo "saved  : capacity=($S_SHUT $S_COOL $S_RES $S_PAUSE) temperature=($S_CT $S_MT $S_RT $S_ST)"
  echo "         current=$S_MCC voltage=$S_MCV"
  echo "start  : $(lvl)% $(tempC)C $(mV)mV kernel=$(kst) acc=$(accstat) |$(mAmag)|mA switch=$(rd "$SWN")"
  echo
} >> "$OUT"

[ -n "$(cc)" ] || { say "This phone has no charge_counter, so charging cannot be measured honestly here."; say "Nothing was changed."; exit 0; }
[ -f $TD/.testingsw ] && { say "ACC is probing charging switches. Let it finish and re-run."; exit 0; }

L=$(lvl)
isnum "$L" || { say "Cannot read the battery level. Nothing changed."; exit 0; }
[ "$L" -lt 90 ] || { say "Battery is ${L}% -- too full for a meaningful matrix. Use it to ~60% and re-run."; exit 0; }

# ---- baseline: every limit lifted, measure the free rate ------------------------------------------------
say "Running the 15-combination matrix. About 20 minutes. Keep it plugged in and leave it alone."
say "Settings are saved and restored, even if you stop it early."
say ""
TOUCHED=true
acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
acc -s cooldown_temp=58 max_temp=60 resume_temp=55 >/dev/null 2>&1
acc -s max_charging_current= >/dev/null 2>&1
acc -s max_charging_voltage= >/dev/null 2>&1
sleep $SETTLE

say "baseline (all limits lifted): switch=$(rd "$SWN") kernel=$(kst) acc=$(accstat)"
say "  switch class: $($NATIVE && echo 'native firmware limit (pause = stop_level <= level)' || echo "generic (paused when the node reads $SWOFF)")"
say "  calibrating charge direction over ${CALW}s..."
NOISE=30
if ! calibrate; then
  no "baseline: could not establish which way the charge is flowing"
  say ""
  say "The charge counter did not move enough to prove a direction and the kernel is not reporting"
  say "Charging. Without that, every measurement below would be guessing at the sign of a current."
  say "Check the cable, or use the phone down to ~60% so it draws properly, and re-run."
  exit 0
fi
ok "baseline: charge direction established (charging reads '${POL}')"
# Pick the instrument before the baseline rate is taken. ACC arms .dpol_unstable after it has seen
# the current sign flip more than once; on such a phone every signed-current reading here is suspect,
# so switch to the counter, which has no sign convention. It costs a much longer window per case.
if [ -e /dev/.vr25/acc/.dpol_unstable ]; then
  USE_CC=true
  say "  this phone's current sign is not stable (ACC has flagged it), so every rate below is"
  say "  measured from the charge counter instead, over ${CCWIN}s per case. The run takes longer."
fi
FREE=$(measure)
if [ -z "$FREE" ] || [ "$FREE" -lt 150 ]; then
  no "baseline: only ${FREE}mA flowing with every limit lifted"
  say ""
  say "Nothing below could be trusted without a real charge to limit. A slow port at a high state"
  say "of charge simply may not deliver enough to measure a throttle against."
  exit 0
fi
ok "baseline: charging at ${FREE}mA with nothing limiting it"
NOISE=$(( FREE / 8 )); [ "$NOISE" -ge 30 ] || NOISE=30
PACKT=$(tempC); PACKV=$(mV)
say "  pack ${PACKT}C ${PACKV}mV, level ${L}%, noise floor ${NOISE}mA"
say ""

# ---- capability probe: which limits can this phone even honour? -----------------------------------------
CAN_A=false; CAN_V=false
acc -s max_charging_current=500 >/dev/null 2>&1; sleep 5
[ -n "$(cfg1 maxChargingCurrent)" ] && CAN_A=true
acc -s max_charging_current= >/dev/null 2>&1
acc -s max_charging_voltage=4100 >/dev/null 2>&1; sleep 5
[ -n "$(cfg1 maxChargingVoltage)" ] && CAN_V=true
acc -s max_charging_voltage= >/dev/null 2>&1
sleep 25
say "capability: current limit supported=$CAN_A   voltage limit supported=$CAN_V"
ACAP=$(( FREE / 3 )); [ "$ACAP" -ge 300 ] || ACAP=300
VCAP=$(( PACKV - 80 ))
THROTTLE_OK=true
[ "$FREE" -ge $(( ACAP * 4 / 3 )) ] || THROTTLE_OK=false
say "  when active: current cap ${ACAP}mA, voltage cap ${VCAP}mV, temperature cap $((PACKT - 2))C,"
say "               capacity cap tracks the live level (it moves during a run); no-capacity cases pin pause at 100%"
$THROTTLE_OK || say "  NOTE: at ${FREE}mA this supply has no headroom for a ${ACAP}mA cap to act on."
$THROTTLE_OK || say "        Current and voltage cases will be skipped. Re-run on a wall charger to cover them."
say ""

# ---- apply a combination --------------------------------------------------------------------------------
apply(){   # $1 = CTAV flags string, e.g. "C--V"
  _f=$1
  # Read the level FRESH for every case. It moves a lot during a run: fast charging raises it, and a
  # capacity pause lowers it again while the pack runs the phone. Sizing both margins off a level
  # captured once at the start is what made the no-limits control row fail on a QC charger - the pack
  # climbed from 55% to the L+10 "capacity must not act" threshold within four cases, so ACC paused,
  # correctly, on a limit the grid intended to be inert. The margin was sized for a slow supply and
  # 20s windows; at 2A with a 180s counter window the level moves about 3% per case.
  _L=$(lvl)
  isnum "$_L" || _L=$L
  case "$_f" in
    # Capacity MUST act: pause just below where the pack is right now.
    *C*) acc -s resume_capacity=$((_L - 3)) pause_capacity=$((_L - 1)) >/dev/null 2>&1;;
    # Capacity must NOT act: put the pause where the level cannot reach it during a case. A relative
    # margin is a race against the charger; 100 is not, because the level cannot exceed it.
    *) acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1;;
  esac
  case "$_f" in
    *T*) _pt=$(tempC); _mt=$((_pt - 2)); _ct=$((_mt - 2)); _rt=$((_mt - 5))
         [ "$_rt" -ge 15 ] || { _rt=15; _ct=17; _mt=19; }
         acc -s cooldown_temp=$_ct max_temp=$_mt resume_temp=$_rt >/dev/null 2>&1;;
      *) acc -s cooldown_temp=58 max_temp=60 resume_temp=55 >/dev/null 2>&1;;
  esac
  case "$_f" in *A*) acc -s max_charging_current=$ACAP >/dev/null 2>&1;;
                  *) acc -s max_charging_current= >/dev/null 2>&1;; esac
  case "$_f" in *V*) acc -s max_charging_voltage=$VCAP >/dev/null 2>&1;;
                  *) acc -s max_charging_voltage= >/dev/null 2>&1;; esac
}

run_case(){   # $1 = flags  $2 = human label
  _f=$1; _lbl=$2
  case "$_f" in *A*) $CAN_A || { skip "$_lbl -- this phone has no current limit"; return; };; esac
  case "$_f" in *V*) $CAN_V || { skip "$_lbl -- this phone has no voltage limit"; return; };; esac
  # A throttle can only be demonstrated against a supply with headroom to lose. ACC's smallest
  # current cap is 300mA, so on a port already delivering less than that there is nothing to cap:
  # writing the nodes only re-triggers AICL, the negotiated rate collapses, and with the phone still
  # drawing its own keep-alive the pack goes net negative. Measured on a Mi A3 on a PC USB port at
  # 157mA, where a 300mA "cap" produced a 57mA drain and read as a failure. Cases with a binary
  # limit in them are unaffected, so they still run.
  case "$_f" in
    *C*|*T*) : ;;
    *A*|*V*) $THROTTLE_OK || { skip "$_lbl -- the supply is only ${FREE}mA, below the ${ACAP}mA floor a cap could act on. Use a wall charger."; return; };;
  esac
  apply "$_f"
  # Wait for ACC to act rather than sleeping a flat SETTLE. Its loop is ~9s while charging, so the
  # switch usually settles inside 15s; the old fixed 40s paid the worst case on all 16 rows. Poll for
  # the switch to reach the state this combination implies, then give it one short beat to stabilise.
  case "$_f" in
    *C*|*T*)
      # A binary limit changes the switch, so poll for exactly that. This is where the time was:
      # these are the majority of rows and they settle in a loop or two.
      _sl=0
      while [ $_sl -lt $SETTLE ]; do sleep 3; _sl=$(( _sl + 3 )); paused && break; done
      sleep 4
      ;;
    *)
      # A throttle NEVER moves the switch, so polling `paused` here breaks on the first iteration and
      # gives the row ~7s. That is not enough for ACC to write the nodes and the supply to re-settle,
      # and it produced a false "the cap did NOT act" on a row whose sibling passed with the same cap.
      # Poll for the thing that actually changes - the cap marker - then let the input re-negotiate.
      _sl=0
      while [ $_sl -lt 20 ]; do
        sleep 2; _sl=$(( _sl + 2 ))
        [ -f "$TD/.mcc-custom" ] && break
        case "$_f" in *V*) [ -f "$TD/.volt-custom" ] && break;; esac
      done
      sleep 18
      ;;
  esac
  _cfg="cap=$(cfgC 3)/$(cfgC 4) temp=$(cfgT 1)/$(cfgT 2)/$(cfgT 3) A=$(cfg1 maxChargingCurrent) V=$(cfg1 maxChargingVoltage)"
  # A cut switch already answers the question. classify() checks `paused` before it looks at the
  # rate anyway, so measuring one first is pure waiting - and it is the majority of rows: every case
  # containing a capacity or temperature limit ends paused. Take a short sample for the report and
  # move on. Only a row that is actually PASSING CURRENT needs the slow counter measurement.
  if paused; then
    _d=$(measure_short)
  else
    _d=$(measure)
  fi
  _st=$(classify "$_d")
  _as=$(accstat)
  _t=$(tempC)
  log "  $_lbl [$_f]"
  log "      config landed: $_cfg"
  # Level goes in every row. It moves during a run, it is what the capacity margins are sized
  # against, and near taper the free rate falls on its own - so a reader can tell a real throttle
  # from a full battery without having to trust that nothing drifted.
  _win=$WIN; $USE_CC && _win=$CCWIN
  log "      switch=$(rd "$SWN") kernel=$(kst) acc=$_as  |I|=$(mAmag)mA  ${_t}C  level=$(lvl)%  charge=${_d}mA/${_win}s"

  case "$_f" in
    *C*|*T*)
      # A binary limit must dominate every throttle. This is the precedence claim.
      if [ "$_st" = PAUSED ]; then
        ok "$_lbl -> PAUSED, as a capacity/temperature limit must (${_d} mA)"
      elif [ "$_st" = BLOCKED ] || [ "$_st" = DRAINING ]; then
        # Not filling, and the switch was never cut. The binary limit did not act; a throttle is
        # holding the charge down instead. DRAINING is the same finding as BLOCKED, just further
        # along: the cap held input below what the phone consumes, so the pack went net negative,
        # ACC concluded it is not charging, and the whole `if is_charging` block - which is where
        # both pauses live - was skipped. Reporting that as "still charging" was simply wrong; the
        # pack is going backwards.
        no "$_lbl -> the pause was NOT applied (switch still ON), a throttle is stopping the charge instead: ${_d}mA"
      else
        no "$_lbl -> still charging at ${_d}mA (free ${FREE}) with a binary limit active"
      fi
      ;;
    *V*|*A*)
      # A throttle must shape the rate WITHOUT cutting the switch. If the switch goes off here, the
      # two classes are not separated and a user cannot reason about which limit acted.
      if sw_on; then
        ok "$_lbl -> throttle left the switch ON, as it must"
      else
        no "$_lbl -> a throttle-only limit CUT THE SWITCH; capacity/temperature and current/voltage must not be interchangeable"
      fi
      # Blocked and throttled are both "the cap acted": where a cap sits relative to the pack's own
      # terminal voltage decides which, and that is hardware, not policy. Only FULL is a failure.
      case "$_st" in
        THROTTLED) ok "$_lbl -> rate cut to ${_d}mA from a free ${FREE}";;
        BLOCKED)   ok "$_lbl -> cap tight enough to stop the charge entirely (${_d}mA), switch still ON";;
        FULL)      no "$_lbl -> the cap did NOT act: still ${_d}mA against a free ${FREE}";;
        *)         no "$_lbl -> measured $_st (${_d}mA/${WIN}s)";;
      esac
      ;;
    *)
      if [ "$_st" = FULL ]; then
        ok "$_lbl -> charging freely (${_d} mA)"
      else
        no "$_lbl -> nothing is set, yet the pack measured $_st (${_d} mA vs free ${FREE})"
      fi
      ;;
  esac

  # ACC's own arbitrated verdict against the gauge. A pack that is provably filling while ACC says
  # Discharging is the polarity failure that makes every limit blind at once.
  #
  # Only meaningful while charging is PERMITTED. An input-cut switch does not zero the current, it
  # REVERSES it -- the phone runs off the pack and the sign flips -- so during a pause the signed
  # rate says "gaining" when the pack is draining, and this check fires on a perfectly correct
  # pause. Measured on a Mi A3: switch=1, kernel Discharging, acc Discharging, everything agreeing
  # the phone was held, and the rate still read +530mA. The matrix header warns about exactly this
  # for the classification; the cross-check needed the same guard.
  if ! paused && [ -n "$_d" ] && [ "$_d" -ge "$NOISE" ] && [ "$_as" = Discharging ]; then
    no "$_lbl -> ACC reports Discharging while the pack gained ${_d}mA: polarity arbitration is wrong here, and every limit is blind while it is"
  fi
}

say "--- the 15 combinations (C=capacity T=temperature A=current V=voltage) ---"
run_case "----" "none: no limit set"
run_case "C---" "capacity only"
run_case "-T--" "temperature only"
run_case "--A-" "current only"
run_case "---V" "voltage only"
run_case "CT--" "capacity + temperature"
run_case "C-A-" "capacity + current"
run_case "C--V" "capacity + voltage"
run_case "-TA-" "temperature + current"
run_case "-T-V" "temperature + voltage"
run_case "--AV" "current + voltage"
run_case "CTA-" "capacity + temperature + current"
run_case "CT-V" "capacity + temperature + voltage"
run_case "C-AV" "capacity + current + voltage"
run_case "-TAV" "temperature + current + voltage"
run_case "CTAV" "all four"

finish
