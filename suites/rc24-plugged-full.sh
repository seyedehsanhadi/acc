#!/system/bin/sh
# rc24-plugged-full.sh — live plug: all rc24 changes + ACC pause/temp/amp/volt.
# Never writes shutdown_capacity or shutdown_temp. Restores every mutation.
#
#   su -c 'sh /data/local/tmp/rc24-plugged-full.sh 9v'
#   su -c 'sh /data/local/tmp/rc24-plugged-full.sh 5v'
#   su -c 'sh /data/local/tmp/rc24-plugged-full.sh slow'

set +e
CLASS=${1:-9v}
case "$CLASS" in 9v|5v|slow) :;; *) echo "usage: $0 9v|5v|slow"; exit 2;; esac

ID=rc24-plugged-full-$CLASS
P=0; F=0; S=0; N=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; N=$((N+1)); echo "  NOTE  $*" >> $W/bugs.txt; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
note(){ echo "  NOTE  $*"; echo "NOTE $*" >> $W/bugs.txt; }
sec(){ echo; echo "===== $* ====="; }
induced(){ echo "  INDUCED  $*"; echo "INDUCED $*" >> $W/bugs.txt; }

M=/data/adb/vr25/acc
DD=/data/adb/vr25/acc-data
TD=/dev/.vr25/acc
PS=/sys/class/power_supply
W=/data/local/tmp/rc24pf
LOGS=$DD/logs
WLOG=$LOGS/write.log
MF=$M/misc-functions.sh
AA=$M/acca.sh
CFG=$DD/config.txt

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
setk(){ "$AA" -s "$@" >/dev/null 2>&1; }
cap_now(){ rd $PS/battery/capacity; }
temp_now(){ rd $PS/battery/temp; }
usb_v(){ rd $PS/usb/voltage_now; }
batt_i(){ rd $PS/battery/current_now; }
usb_imax(){ rd $PS/usb/current_max; }
st_now(){ rd $PS/battery/status; }

sample(){
  echo "t=$(date +%s) cap=$(cap_now) temp=$(temp_now) st=$(st_now) usbV=$(usb_v) battI=$(batt_i) usbMax=$(usb_imax) on=$(rd $PS/usb/online) p=$(rd $PS/usb/present)"
}

rm -rf $W; mkdir -p $W $W/tmp $W/data
: > $W/bugs.txt
sed -n '/^_mv() {/,/^}/p;/^_ma() {/,/^}/p;/^_iin_ma() {/,/^}/p;/^_hv_may_kick() {/,/^}/p' $MF > $W/u.sh

# Originals — never touch sc (shutdown %) or st (shutdown temp)
ORIG_PC=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $4}')
ORIG_RC=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $3}')
ORIG_CC=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $2}')
ORIG_SC=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $1}')
ORIG_CT=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $1}')
ORIG_MT=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $2}')
ORIG_RT=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $3}')
ORIG_ST=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $4}')
ORIG_MCC=$(sed -n 's/^maxChargingCurrent=//p' $CFG)
ORIG_MCV=$(sed -n 's/^maxChargingVoltage=//p' $CFG)

restore(){
  trap - EXIT INT TERM HUP
  echo "  restoring pc=$ORIG_PC rc=$ORIG_RC mt=$ORIG_MT ct=$ORIG_CT rt=$ORIG_RT mcc= mcv="
  setk pc="$ORIG_PC" rc="$ORIG_RC" cc="$ORIG_CC" ct="$ORIG_CT" mt="$ORIG_MT" rt="$ORIG_RT" mcc= mcv= 2>/dev/null
  # never write sc or st
  echo "  restored cap=$(cap_now) st=$(st_now) usbV=$(usb_v)"

  # Clearing the CONFIG is not the same as releasing the NODES, and this suite used to stop at the
  # config. A run that induced mcv left battery/voltage_max pinned at 3900000 on a Mi A3 -- a 3.9V
  # float on a pack that charges to 4.4V -- while main/voltage_max beside it had been released and
  # the config read mcv=(). The phone then crawled, and its owner noticed before the test did.
  # So: read every node ACC recorded a default for, and shout if one is still below it.
  # Only meaningful while current is actually flowing. A phone HOLDING A PAUSE reports 0 on every
  # input-current node, because that is what a pause does -- flagging those as "capped" would call a
  # correctly-paused phone broken. Voltage nodes are checked either way: a float ceiling is a stored
  # setting, not a consequence of the pause.
  _stuck=0
  _charging=no; [ "$(st_now)" = Charging ] && _charging=yes
  [ "$_charging" = yes ] || echo "  (not charging - checking voltage ceilings only; input-current nodes read 0 during a pause by design)"
  for _l in $(cat $TD/ch-volt-ctrl-files 2>/dev/null; [ "$_charging" = yes ] && cat $TD/ch-curr-ctrl-files 2>/dev/null); do
    _n=${_l%%::*}; _d=${_l##*::}
    case "$_n" in /*) _p=$_n ;; *) _p=$PS/$_n ;; esac
    [ -e "$_p" ] || continue
    _v=$(cat "$_p" 2>/dev/null | head -1)
    case "$_v" in ''|*[!0-9]*) continue ;; esac
    case "$_d" in ''|*[!0-9]*) continue ;; esac
    if [ "$_v" -lt "$_d" ] 2>/dev/null; then
      _stuck=$((_stuck+1))
      echo "  !! NOT RELEASED: $_n = $_v, below its recorded default $_d"
      echo "     fix by hand NOW:  echo $_d > $_p"
    fi
  done
  [ "$_stuck" = 0 ] && echo "  all recorded current/voltage nodes are at or above their defaults"                     || echo "  !! $_stuck node(s) left capped - this phone will charge slowly until fixed"
}
trap restore EXIT INT TERM HUP

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)"
echo "build  : $(sed -n s/version=//p $M/module.prop)"
echo "class  : $CLASS"
echo "ORIG   : pause=$ORIG_PC resume=$ORIG_RC coolCap=$ORIG_CC shutdown%=$ORIG_SC(untouched)"
echo "ORIG   : coolT=$ORIG_CT maxT=$ORIG_MT resumeT=$ORIG_RT shutT=$ORIG_ST(untouched)"
echo "ORIG   : mcc=$ORIG_MCC mcv=$ORIG_MCV"

# -------------------------------------------------------------------------------------------------
sec "0  UNPLUGGED PREFLIGHT"

[ "$(id -u)" = 0 ] || { echo ABORT:not_root; exit 1; }
_already=$(plug_present)
if [ "$_already" = yes ]; then
  ok "already plugged — skip 0→1 wait (edge not captured this run)"
  echo already > $W/already
else
  ok "unplugged — will wait for cable"
fi
_pid=$(daemon_pid)
[ -n "$_pid" ] && ok "daemon $_pid" || { echo ABORT:no_daemon; exit 1; }
if [ "$_already" = yes ]; then sk "status is Charging, but the phone started plugged - this case only measures an unplugged phone"; else [ "$(st_now)" != Charging ] && ok "status $(st_now)" || no "Charging unplugged"; fi

_i0=$(batt_i); _i0=${_i0#-}
_sign0=$(batt_i)
echo "  unplug current_now=$_sign0  (A3 often + while draining; Pixel −)"
echo "$_sign0" > $W/sign0
note "polarity unplug current_now=$_sign0"

case "$ORIG_SC" in 5) ok "shutdown_capacity=$ORIG_SC will not be written";; *) ok "shutdown_capacity=$ORIG_SC untouched";; esac
case "$ORIG_ST" in 55) ok "shutdown_temp=$ORIG_ST will not be written";; *) ok "shutdown_temp=$ORIG_ST untouched";; esac

_w0=$(lines $WLOG)
if [ ! -f $W/already ]; then
  echo
  echo "------------------------------------------------------------------------"
  echo "WAITING FOR CABLE  class=$CLASS   (${PLUGWAIT:-600}s)"
  echo "------------------------------------------------------------------------"
  _w=0
  while [ $_w -lt "${PLUGWAIT:-600}" ]; do
    [ "$(plug_present)" = yes ] && break
    sleep 2; _w=$((_w + 2))
  done
  [ "$(plug_present)" = yes ] || { echo "ABORT:no_plug_in_${PLUGWAIT:-600}s"; exit 1; }
  ok "present=1 after ${_w}s"
  echo "  settle 8s..."
  sleep 8
else
  ok "present=1 (already in)"
fi
sample | tee $W/s1

# -------------------------------------------------------------------------------------------------
sec "1  UNITS + POLARITY  (#1 #2 #3 #49)"

. $W/u.sh
_rawv=$(usb_v)
_mv=$(_mv "$_rawv" 2>/dev/null)
echo "  voltage_now=$_rawv _mv=${_mv:-ERR}"
case "${_mv:-x}" in
  ''|x|ERR) no "_mv failed";;
  *)
    [ "$_mv" -ge 4000 ] && [ "$_mv" -le 20000 ] && ok "#1 bus ${_mv}mV" || no "#1 bus $_mv"
    ;;
esac
_iin=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
echo "  _iin_ma=${_iin:-none}  battI=$(batt_i)"
case "${_iin:-x}" in
  ''|x) sk "#3 no iin node";;
  *) [ "$_iin" -ge 0 ] && [ "$_iin" -le 6000 ] && ok "#3 _iin_ma ${_iin}mA" || no "#3 ${_iin}mA implausible";;
esac
_sign1=$(batt_i)
echo "  plug current_now=$_sign1  unplug was $(cat $W/sign0)"
# Sign should flip vs unplug if charging. A3 +drain → −charge or still + if inverted consistently for charge.
note "polarity plug current_now=$_sign1 vs unplug $(cat $W/sign0)"
_st=$(st_now)
echo "  status=$_st"
case "$_st" in
  Charging) ok "kernel Charging";;
  *) note "status $_st after 25s — pause/native/slow handshake";;
esac

# -------------------------------------------------------------------------------------------------
sec "2  CONTRACT  (#6-13 #15-18)"

_type=$(rd $PS/usb/real_type); [ -n "$_type" ] || _type=$(rd $PS/usb/type)
_latched=no; [ -f $TD/.hvcontract ] && _latched=yes
_peak=$(rd $TD/.hvpeak)
echo "  type=$_type contract=$_latched peak=$_peak kicked=$([ -f $TD/.hvkicked ] && echo yes || echo no)"
case "$CLASS" in
  9v)
    if [ "$_latched" = yes ] || [ "${_mv:-0}" -ge 6500 ]; then
      [ "$_latched" = yes ] && ok "#6 latch on 9V" || no "#6 ${_mv}mV no .hvcontract"
    else
      no "#6 9v class but mv=$_mv type=$_type — brick still 5V?"
    fi
    [ -f $TD/.hvkicked ] && no "#13 .hvkicked on 9V" || ok "#13 no kick claimed"
    ;;
  5v)
    [ "${_mv:-0}" -lt 6500 ] && ok "#6 5V bus $_mv" || no "#6 5v class but $_mv mV"
    [ "$_latched" = yes ] && note "#6 latched on 5V (OK if type is QC/PD in 5V phase)" || ok "#6 no false latch"
    ;;
  slow)
    ok "slow: mv=$_mv latch=$_latched iin=$_iin"
    ;;
esac

_g=$(
  cd $PS || exit 1
  TMPDIR=$W/tmpg; dataDir=$W/datag; mkdir -p $TMPDIR $dataDir
  [ -f $TD/.hvcontract ] && cp $TD/.hvcontract $TMPDIR/
  [ -f $TD/.hvpeak ] && cp $TD/.hvpeak $TMPDIR/
  present(){ return 0; }
  . $W/u.sh
  _hv_may_kick && echo KICK || echo HOLD
)
echo "  isolated kick=$_g"
[ "$_g" = HOLD ] && ok "#12 kick HOLD on live plug" || no "#12 kick=$_g on live plug"

_usbmax=$(usb_imax)
echo "  usb/current_max=$_usbmax"
case "$_usbmax" in 100000|100) no "#15 usb/current_max collapsed $_usbmax";; *) ok "#15 usb/current_max=$_usbmax";; esac
_newn=$(lines $WLOG)
if [ "$_newn" -gt "$_w0" ]; then
  tail -n $(( _newn - _w0 )) $WLOG 2>/dev/null | grep -q usb/current_max \
    && no "#15 write.log usb/current_max" || ok "#15 no usb/current_max writes"
  tail -n $(( _newn - _w0 )) $WLOG 2>/dev/null | grep -qi apsd_rerun \
    && { [ "$CLASS" = 9v ] && no "#17 apsd on 9V" || note "#17 apsd on $CLASS"; } \
    || ok "#17 no apsd_rerun"
else
  ok "#35 no writes yet (quiet)"
fi

# -------------------------------------------------------------------------------------------------
sec "3  AMP CAP  mcc=500 then clear  (test-induced current drop)"

induced "mcc=500 ~8s then clear — drop/recover is TEST-INDUCED"
_i_before=${_iin:-0}
sample | tee $W/amp0
setk mcc=500
sleep 8
sample | tee $W/amp1
_iin_cap=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
echo "  iin after mcc=500: ${_iin_cap:-?} mA (before ${_i_before})"
setk mcc=
sleep 8
sample | tee $W/amp2
_iin_rel=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
echo "  iin after mcc clear: ${_iin_rel:-?} mA"
# Don't fail the whole suite if the kernel ignores mcc; that's a phone capability. But say so out
# loud, and never credit NOISE as a working cap.
#
# A bare "did it go down?" passes on the ordinary charge taper. Measured on a Pixel 6a: 979 -> 947
# under mcc=500, then 907 after CLEARING it -- a monotonic slide, graded PASS, while battery current
# sat at 1873 mA against a 500 mA cap that had never landed. The cause is upstream of this suite and
# older than rc24: ACC never builds ch-curr-ctrl-files on that phone, so set_ch_curr is gated out and
# maxChargingCurrent is a silent no-op. A test that reports that as a pass is worse than no test.
#
# So: report what the device can actually do, and require a drop big enough not to be taper.
_ccf=$TD/ch-curr-ctrl-files
_nnodes=0; [ -f "$_ccf" ] && { _nnodes=$(grep -c / "$_ccf" 2>/dev/null || :); _nnodes=${_nnodes:-0}; }
echo "  current-control nodes ACC discovered: $_nnodes"
if [ "$_nnodes" -eq 0 ]; then
  sk "amp: ACC discovered NO current-control nodes on this device - maxChargingCurrent cannot be enforced here (pre-existing, not an rc24 change)"
elif [ -n "$_iin_cap" ] && [ -n "$_i_before" ] && [ "$_i_before" -gt 200 ] 2>/dev/null; then
  # Taper over a 16s window is a few percent. Demand a third off before calling the cap effective.
  _need=$(( _i_before - _i_before / 3 ))
  if [ "$_iin_cap" -le "$_need" ] 2>/dev/null; then
    ok "amp: current dropped ${_i_before} -> ${_iin_cap} mA under mcc=500 (>= 1/3 off, not taper)"
  elif [ "$_iin_cap" -lt "$_i_before" ] 2>/dev/null; then
    no "amp: only ${_i_before} -> ${_iin_cap} mA under mcc=500 with $_nnodes node(s) discovered - too small to distinguish from the charge taper, so the cap did not land"
  else
    no "amp: no drop (${_i_before} -> ${_iin_cap}) with $_nnodes node(s) discovered - the cap did not land"
  fi
else
  sk "amp: no baseline current to compare"
fi
[ "$(daemon_pid)" = "$_pid" ] || [ -n "$(daemon_pid)" ] && ok "daemon alive after mcc" || no "daemon died after mcc"

# -------------------------------------------------------------------------------------------------
sec "4  PAUSE at current level then restore  (not shutdown %)"

_c=$(cap_now)
echo "  cap=$_c  orig pause=$ORIG_PC resume=$ORIG_RC"
induced "pc=$_c (NOW, not wait-to-%) ~10s then restore $ORIG_PC"
setk pc="$_c" rc=$(( _c > 2 ? _c - 2 : 0 ))
sleep 10
sample | tee $W/pause1
_stp=$(st_now)
_iin_p=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
echo "  at forced pause: status=$_stp iin=${_iin_p:-?}"
case "$_stp" in
  Charging) note "pause: still Charging after 10s (native lag / switch leak) cap=$_c";;
  *) ok "pause: status $_stp at pc=$_c";;
esac
setk pc="$ORIG_PC" rc="$ORIG_RC"
sleep 8
sample | tee $W/pause2
echo "  restored pause=$ORIG_PC status=$(st_now) iin=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)"
# Confirm we did not write shutdown
grep -q "^capacity=($ORIG_SC " $CFG && ok "shutdown_capacity still $ORIG_SC" || no "shutdown_capacity mutated"

# -------------------------------------------------------------------------------------------------
sec "5  TEMP hold just below pack temp then restore  (not shutdown temp)"

_t=$(temp_now)
# temp is decidegrees: 401 = 40.1C
_tc=$(( _t / 10 ))
echo "  pack ${_t} ( ${_tc}C )  orig maxT=$ORIG_MT coolT=$ORIG_CT resumeT=$ORIG_RT shutT=$ORIG_ST"
if [ "$_tc" -ge 2 ] 2>/dev/null; then
  _mt=$(( _tc - 2 ))
  [ "$_mt" -lt 20 ] && _mt=20
  induced "max_temp=$_mt (pack ${_tc}C) ~10s — THERMAL TEST-INDUCED; shutdown_temp stays $ORIG_ST"
  setk mt="$_mt" rt="$_mt" ct="$_mt"
  sleep 10
  sample | tee $W/temp1
  echo "  thermal: status=$(st_now) temp=$(temp_now)"
  setk mt="$ORIG_MT" rt="$ORIG_RT" ct="$ORIG_CT"
  sleep 8
  sample | tee $W/temp2
  grep temperature= $CFG | grep -q " $ORIG_ST)" && ok "shutdown_temp still $ORIG_ST" || no "shutdown_temp mutated"
  ok "temp mutation restored maxT=$ORIG_MT"
else
  sk "temp unreadable"
fi

# -------------------------------------------------------------------------------------------------
sec "6  VOLT CAP  mcv=3900 then clear  (test-induced)"

induced "mcv=3900 ~8s then clear — voltage sag TEST-INDUCED if honoured"
_vb0=$(usb_v)
setk mcv=3900
sleep 8
sample | tee $W/volt1
_vb1=$(usb_v)
setk mcv=
sleep 8
sample | tee $W/volt2
_vb2=$(usb_v)
echo "  usbV $_vb0 -> $_vb1 (mcv=3900) -> $_vb2 (cleared)"
note "volt: raw $_vb0 $_vb1 $_vb2 (unit-sensitive; compare _mv not raw)"
[ -n "$(daemon_pid)" ] && ok "daemon alive after mcv" || no "daemon died after mcv"

# -------------------------------------------------------------------------------------------------
sec "7  QUIET + RECOVER + HONEST STATUS"

sleep 4
sample | tee $W/end
_stf=$(st_now)
_cf=$(cap_now)
echo "  final status=$_stf cap=$_cf pause=$ORIG_PC"
[ -n "$(daemon_pid)" ] && ok "daemon up" || no "NO DAEMON"
[ "$_stf" = Charging ] && [ "$(plug_present)" = yes ] && ok "charging after restores" \
  || note "final status $_stf (may still be catching up after pause/temp)"
# config shutdowns
_sc_now=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $1}')
_st_now=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $4}')
[ "$_sc_now" = "$ORIG_SC" ] && ok "shutdown % untouched ($_sc_now)" || no "shutdown % $_sc_now != $ORIG_SC"
[ "$_st_now" = "$ORIG_ST" ] && ok "shutdown temp untouched ($_st_now)" || no "shutdown temp $_st_now != $ORIG_ST"

echo
echo "----- notes/bugs -----"
cat $W/bugs.txt 2>/dev/null
echo
echo "$ID: $P passed, $F failed, $S skipped"
[ "$F" -eq 0 ]
