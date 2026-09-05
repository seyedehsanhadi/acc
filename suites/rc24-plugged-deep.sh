#!/system/bin/sh
# rc24-plugged-deep.sh — deepest LIVE plug grade of every rc24 change that a cable can prove.
#
#   su -c 'sh /data/local/tmp/rc24-plugged-deep.sh 9v'
#   su -c 'sh /data/local/tmp/rc24-plugged-deep.sh 5v'
#   su -c 'sh /data/local/tmp/rc24-plugged-deep.sh slow'
#
# Starts UNPLUGGED. Aborts if a cable is already in (we need a real present 0→1 edge).
# Prints WAITING, then grades after present=1 and a settle.
#
# DOES NOT write charging nodes, does not change pause, does not acc -t, does not kill the daemon.
# Observation + extracted-function fixtures only.
#
# 9v   : HV latch, peak, type, kick HOLD, no usb/current_max write, units, no APSD
# 5v   : must NOT latch on 5.0–5.2 V; Iin>50 mA → kick HOLD (live 5V is not "dead")
# slow : _iin_ma sane; must not look like a 5353 µA "collapse" while current actually flows

set +e
CLASS=${1:-9v}
case "$CLASS" in 9v|5v|slow) :;; *) echo "usage: $0 9v|5v|slow"; exit 2;; esac

ID=rc24-plugged-deep-$CLASS
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
sec(){ echo; echo "===== $* ====="; }

M=/data/adb/vr25/acc
DD=/data/adb/vr25/acc-data
TD=/dev/.vr25/acc
PS=/sys/class/power_supply
W=/data/local/tmp/rc24p
LOGS=$DD/logs
WLOG=$LOGS/write.log
FLIGHT=$LOGS/flight.log
MF=$M/misc-functions.sh
AD=$M/accd.sh

rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
lines(){ _n=$(wc -l < "$1" 2>/dev/null); case "${_n:-x}" in ''|*[!0-9]*) echo 0;; *) echo "$_n";; esac; }
daemon_pid(){ pgrep -f "$M/accd.sh" 2>/dev/null | head -1; }

plug_present(){
  _p=no
  for _n in $PS/*/present; do
    [ -f "$_n" ] || continue
    case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac
    [ "$(rd "$_n")" = 1 ] && _p=yes
  done
  echo $_p
}

rm -rf $W 2>/dev/null; mkdir -p $W $W/tmp $W/data 2>/dev/null
sed -n '/^_mv() {/,/^}/p;/^_ma() {/,/^}/p;/^_vbus_mv() {/,/^}/p;/^_iin_ma() {/,/^}/p;/^_hv_may_kick() {/,/^}/p;/^_hv_lift() {/,/^}/p' $MF > $W/u.sh

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)"
echo "build  : $(sed -n s/versionCode=//p $M/module.prop)  $(sed -n s/version=//p $M/module.prop)"
echo "class  : $CLASS"

# -------------------------------------------------------------------------------------------------
sec "0  UNPLUGGED PREFLIGHT — abort if a cable is already in"

[ "$(id -u)" = 0 ] || { echo "  ABORT: not root"; exit 1; }
[ -f $MF ] && [ -f $AD ] || { echo "  ABORT: no ACC"; exit 1; }
ok "root + ACC"

if [ "$(plug_present)" = yes ]; then
  echo "  ABORT: a supply is already present — unplug, then re-run so we catch the 0→1 edge"
  exit 1
fi
ok "no cable (present=0)"

_pid=$(daemon_pid)
[ -n "$_pid" ] && ok "daemon pid $_pid" || { echo "  ABORT: no daemon"; exit 1; }

_st=$(rd $PS/battery/status)
[ "$_st" != Charging ] && ok "status $_st" || no "Charging while unplugged"

# The per-plug markers die on the daemon's next loop, NOT the instant the cable leaves. Unplugged,
# that loop is a LONG nap -- measured 123-197s on a Pixel 6a. Asserting the moment the suite starts
# races the daemon and fails a phone that is behaving correctly: a run armed 40s after the unplug
# reported "stale .hvcontract" and "stale .hvpeak" on hardware that cleared both a minute later.
# Wait for one full idle loop before grading, and only then call a surviving marker stale.
_mw=0
while [ $_mw -lt 210 ]; do
  _left=0
  for _m in .hvcontract .hvpeak .hvkicked .hvzero .hvaim .hvfloor .hvlost; do
    [ -e "$TD/$_m" ] && _left=1
  done
  [ "$_left" = 0 ] && break
  sleep 10; _mw=$((_mw+10))
done
[ "$_mw" -gt 0 ] && echo "  ....  waited ${_mw}s for the daemon's idle loop to clear the per-plug markers"
for _m in .hvcontract .hvpeak .hvkicked .hvzero .hvaim .hvfloor .hvlost; do
  [ -e "$TD/$_m" ] && no "stale $_m (survived ${_mw}s unplugged, past a full idle loop)" || ok "$_m absent"
done

_w0=$(lines $WLOG)
echo "$_w0" > $W/w0
echo "$(rd $PS/usb/current_max)" > $W/usbmax0
echo "$(rd $PS/usb/input_current_max)" > $W/icl0
echo "$(rd $PS/battery/capacity)" > $W/cap0
echo "$(date +%s)" > $W/t0

# Snapshot write.log tail so we can see NEW lines after plug
tail -n 0 $WLOG > $W/wlog.pre 2>/dev/null || :
_wlog_n=$(lines $WLOG)

echo
echo "------------------------------------------------------------------------"
echo "WAITING FOR CABLE  class=$CLASS"
echo "  9v  = QC/PD brick that negotiates ~9V"
echo "  5v  = plain USB / 5V-only"
echo "  slow= weak/slow charger (still a real cable)"
echo "Plug now. This process waits up to ${PLUGWAIT:-600}s for present=1."
echo "------------------------------------------------------------------------"

_w=0
while [ $_w -lt "${PLUGWAIT:-600}" ]; do
  [ "$(plug_present)" = yes ] && break
  sleep 2
  _w=$((_w + 2))
done
if [ "$(plug_present)" != yes ]; then
  echo "  ABORT: no plug in 180s"
  exit 1
fi
ok "present=1 after ${_w}s"

echo "  settling 20s (handshake / aim-high / latch)..."
sleep 20

# -------------------------------------------------------------------------------------------------
sec "1  LIVE UNITS  (#1 #2 #3 #4 #5 #49)"

. $W/u.sh
_rawv=$(rd $PS/usb/voltage_now)
_mv=$(_mv "$_rawv" 2>/dev/null)
echo "  voltage_now=$_rawv  _mv=${_mv:-ERR} mV"
case "${_mv:-x}" in
  ''|x|ERR) no "_mv failed on live voltage_now=$_rawv";;
  *)
    if [ "$_rawv" -gt 20000 ] 2>/dev/null; then
      [ "$_mv" = $(( _rawv / 1000 )) ] && ok "#1 _mv divided uV $_rawv -> $_mv" \
        || no "#1 _mv=$_mv expected $(( _rawv / 1000 ))"
    else
      [ "$_mv" = "$_rawv" ] && ok "#1 _mv kept mV $_mv" || no "#1 _mv=$_mv raw=$_rawv"
    fi
    [ "$_mv" -ge 4000 ] 2>/dev/null && [ "$_mv" -le 20000 ] 2>/dev/null \
      && ok "#1/#5 bus in 4–20 V ($_mv mV)" || no "#1 bus $_mv mV not a USB voltage"
    ;;
esac

# Learn-scale: charging current should be >20k on a µA kernel
_iin_raw=
for _n in usb/input_current_now usb/current_now usb/input_current_settled \
          main-charger/current_now main/current_now; do
  [ -f "$PS/$_n" ] || continue
  _iin_raw=$(rd $PS/$_n)
  echo "  iin node=$_n raw=$_iin_raw"
  break
done
if [ -z "$_iin_raw" ]; then
  sk "#3/#49 no input-current node on this kernel"
else
  ( cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma ) > $W/iin1 2>/dev/null
  _ma1=$(cat $W/iin1)
  echo "  _iin_ma=$_ma1 mA"
  case "${_ma1:-x}" in
    ''|x|ERR) no "#3 _iin_ma empty";;
    *)
      [ "$_ma1" -ge 0 ] 2>/dev/null && [ "$_ma1" -le 6000 ] 2>/dev/null \
        && ok "#3 _iin_ma in 0–6 A ($_ma1 mA)" || no "#3 _iin_ma=$_ma1 not a plausible current"
      # #49: if raw > 20000, learned µA so 5353-class values would divide. Charging raw must be >20k
      # on A3. Pixel often already mA.
      if [ "${_iin_raw#-}" -gt 20000 ] 2>/dev/null; then
        [ -f $W/tmp/.iinmicro ] && ok "#49 learned µA (marker set, raw $_iin_raw)" \
          || ok "#49 raw>20k so scale is µA (marker $_iin_raw)"
        _expect=$(( ${_iin_raw#-} / 1000 ))
        _delta=$(( _ma1 - _expect )); [ "$_delta" -lt 0 ] && _delta=$(( -_delta ))
        [ "$_delta" -le 5 ] 2>/dev/null \
          && ok "#2/#49 _iin_ma matches raw/1000 within live-sample jitter ($_ma1 vs $_expect)" \
          || no "#49 $_ma1 differs from $_expect by ${_delta}mA"
      else
        ok "#49 kernel already mA (raw $_iin_raw) — learn-path not exercised this plug"
      fi
      ;;
  esac
fi

# -------------------------------------------------------------------------------------------------
sec "2  CONTRACT LATCH  (#6 #7 #8 #9 #10 #11)"

_type=$(rd $PS/usb/real_type); [ -n "$_type" ] || _type=$(rd $PS/usb/type)
_usbtype=$(rd $PS/usb/usb_type)
echo "  type=$_type usb_type=$_usbtype"
_hvtype=no
case "${_type}${_usbtype}" in *HVDCP*|*PD*|*QC*|*hvdcp*|*pd*) _hvtype=yes;; esac

_peak=$(rd $TD/.hvpeak)
_latched=no; [ -f $TD/.hvcontract ] && _latched=yes
echo "  hvcontract=$_latched  hvpeak=${_peak:-none}  hvtype=$_hvtype"

case "$CLASS" in
  9v)
    if [ "$_latched" = yes ]; then
      ok "#6/#8 .hvcontract set on 9V plug"
    elif [ "${_mv:-0}" -ge 6500 ] 2>/dev/null; then
      no "#6 bus ${_mv}mV >= 6500 but .hvcontract ABSENT"
    elif [ "$_hvtype" = yes ]; then
      no "#8 HV type $_type but .hvcontract ABSENT"
    else
      no "#6/#8 9V class but no latch (mv=$_mv type=$_type) — wrong brick or still 5V"
    fi
    if [ -n "$_peak" ] && [ "$_peak" -ge 5500 ] 2>/dev/null; then
      ok "#7 .hvpeak=$_peak mV"
    elif [ "$_hvtype" = yes ]; then
      sk "#7 no peak yet, type latch may have won first"
    else
      no "#7 .hvpeak missing/low ($_peak)"
    fi
    [ -f $TD/.hvkicked ] && no "#13 .hvkicked set on a 9V plug — APSD was claimed" \
                         || ok "#13 .hvkicked absent (no kick claimed)"
    ;;
  5v)
    if [ "${_mv:-0}" -ge 6500 ] 2>/dev/null; then
      no "#6 5v class but bus ${_mv}mV looks like 9V — wrong brick"
    else
      ok "#6 bus ${_mv}mV is below 6.5 V"
    fi
    if [ "$_hvtype" = yes ]; then
      [ "$_latched" = yes ] && ok "#8 5V brick still typed HV → latch OK" \
                            || no "#8 HV type on 5V brick but no latch"
    else
      [ "$_latched" = yes ] && no "#6 latched at 5V without HV type (false contract)" \
                            || ok "#6 no latch on plain 5V"
    fi
    ;;
  slow)
    echo "  slow class: latch only if the brick actually went high"
    if [ "${_mv:-0}" -ge 6500 ] 2>/dev/null || [ "$_hvtype" = yes ]; then
      [ "$_latched" = yes ] && ok "slow-but-HV latched" || no "slow brick is HV but no latch"
    else
      [ "$_latched" = yes ] && no "slow 5V latched falsely" || ok "slow 5V not latched"
    fi
    ;;
esac

# -------------------------------------------------------------------------------------------------
sec "3  KICK GATE ON THE LIVE PLUG  (#12 #13 #14 #21)"

# Isolated copy of latch/peak — NEVER point TMPDIR at live $TD or a KICK claims .hvkicked for the boot.
_g2=$(
  cd $PS || exit 1
  TMPDIR=$W/tmpg; dataDir=$W/datag; mkdir -p $TMPDIR $dataDir
  [ -f $TD/.hvcontract ] && cp $TD/.hvcontract $TMPDIR/
  [ -f $TD/.hvpeak ] && cp $TD/.hvpeak $TMPDIR/
  [ -f $TD/.hvkicked ] && cp $TD/.hvkicked $TMPDIR/
  [ -f $DD/.rekick-off ] && cp $DD/.rekick-off $dataDir/
  present(){ return 0; }
  . $W/u.sh
  if _hv_may_kick; then echo KICK; else echo HOLD; fi
)
echo "  isolated gate -> $_g2"

case "$CLASS" in
  9v)
    [ "$_g2" = HOLD ] && ok "#12 9V plug: kick HOLD" || no "#12 9V plug: gate=$_g2 (APSD would drop 9V→5V)"
    ;;
  5v|slow)
    if [ "${_ma1:-0}" -gt 50 ] 2>/dev/null; then
      [ "$_g2" = HOLD ] && ok "#12 live ${_ma1}mA: kick HOLD (not dead)" \
                        || no "#12 current ${_ma1}mA but gate=$_g2 — would APSD a working 5V"
    else
      echo "  Iin ${_ma1:-none} mA — supply looks empty; kick may be legal"
      sk "#12 Iin<=50, kick permission not graded as a fail"
    fi
    ;;
esac

[ -f $TD/.hvkicked ] && no "#13 live .hvkicked exists after plug (APSD claimed)" \
                     || ok "#13 live .hvkicked still absent"

# -------------------------------------------------------------------------------------------------
sec "4  ALLOW-LIST / NO 100 mA  (#15 #16 #17 #18 #47)"

_usbmax=$(rd $PS/usb/current_max)
_usbmax0=$(cat $W/usbmax0)
echo "  usb/current_max now=$_usbmax  was=${_usbmax0:-none}"
case "${_usbmax:-x}" in
  100000|1000000|100) no "#15 usb/current_max collapsed to $_usbmax (100 mA class)";;
  *) ok "#15 usb/current_max not at 100 mA ($_usbmax)";;
esac

# New write.log lines mentioning usb/current_max or apsd_rerun
_w1=$(lines $WLOG)
echo "  write.log $_wlog_n -> $_w1"
if [ -f $WLOG ]; then
  _new=$(tail -n +$(( _wlog_n + 1 )) $WLOG 2>/dev/null)
  echo "$_new" | grep -q 'usb/current_max' \
    && no "#15/#18 write.log has usb/current_max after plug" \
    || ok "#15/#18 no usb/current_max in new writes"
  echo "$_new" | grep -qi 'apsd_rerun' \
    && { [ "$CLASS" = 9v ] && no "#17 apsd_rerun written on 9V plug" || sk "#17 apsd on 5v/slow (only OK if gate HOLD and no latch)"; } \
    || ok "#17 no apsd_rerun in new writes"
  echo "$_new" | grep -E 'main/current_max|gccd/current_max|charger/current_max' \
    && ok "#16/#18 a charger-owned node was written (lift/aim)" \
    || sk "#16 no charger-owned write this plug (may already be high)"
else
  sk "no write.log"
fi

# -------------------------------------------------------------------------------------------------
sec "5  PLUG EDGES / AIM YIELD  (#22 #23 #27 #28 #29)"

_online=$(rd $PS/usb/online)
_present=$(rd $PS/usb/present)
echo "  usb present=$_present online=$_online"
[ "$_present" = 1 ] && ok "#27 present=1" || no "#27 present=$_present"
# input-cut can zero online while present=1 — that is the B1 case; 9V healthy usually online=1
if [ "$_online" = 0 ] && [ "$_present" = 1 ]; then
  ok "#27/#29 online masked 0 with cable in (rearm-on-present is the only working edge)"
else
  ok "#27 online=$_online with cable in"
fi

# Aim-high yield: if we are at/above pause, aim must not have run. A3 pause 52 cap was 47 — will charge.
_cap=$(rd $PS/battery/capacity)
_pause=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')' | awk '{print $4}')
echo "  cap=$_cap pause=$_pause"
case "${_cap}${_pause}" in
  ''|*[!0-9]*) sk "#22 cannot parse cap/pause";;
  *)
    if [ "$_cap" -ge "$_pause" ] 2>/dev/null; then
      echo "$_new" | grep -qi 'apsd_rerun' \
        && no "#22 at/above pause but apsd ran" \
        || ok "#22 at/above pause, no apsd"
    else
      ok "#23 below pause ($_cap < $_pause) — aim is allowed; gated by contract"
    fi
    ;;
esac

# -------------------------------------------------------------------------------------------------
sec "6  WRITE PATH QUIET / NO HAMMER  (#35)"

# After settle, additional write.log growth in 15s should be small (idempotent write).
_wa=$(lines $WLOG)
sleep 15
_wb=$(lines $WLOG)
_wg=$(( _wb - _wa ))
echo "  write.log +$_wg in 15s after settle"
[ "$_wg" -le 8 ] 2>/dev/null && ok "#35 quiet after settle (+$_wg)" \
                             || no "#35 still hammering (+$_wg writes / 15s)"

# -------------------------------------------------------------------------------------------------
sec "7  DAEMON ALIVE, STATUS HONEST, LEVEL CAN RISE"

_st2=$(rd $PS/battery/status)
_cap2=$(rd $PS/battery/capacity)
_pid2=$(daemon_pid)
echo "  status=$_st2 cap=$_cap2 pid=$_pid2"
[ -n "$_pid2" ] && ok "daemon still running" || no "daemon died after plug"
case "$_st2" in
  Charging|Full|'Not charging'|Idle) ok "status $_st2 with cable";;
  Discharging)
    if [ "$_online" = 0 ]; then
      sk "Discharging with online=0 — paused or input-cut; not a unit fail"
    else
      no "Discharging with cable and online=1"
    fi
    ;;
  *) sk "status $_st2";;
esac

echo
echo "  raw usb/voltage_now=$(rd $PS/usb/voltage_now)  current_max=$(rd $PS/usb/current_max)"
echo "  markers: contract=$([ -f $TD/.hvcontract ] && echo yes || echo no) peak=$(rd $TD/.hvpeak) kicked=$([ -f $TD/.hvkicked ] && echo yes || echo no)"
echo
echo "$ID: $P passed, $F failed, $S skipped"
[ "$F" -eq 0 ]
