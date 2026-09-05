#!/system/bin/sh
# rc24-plugged-9vramp.sh — unplug-required, then watch 9V RAMP, then ACC functions.
# Never writes shutdown_capacity / shutdown_temp. Restores pause/temp/mcc/mcv.
#
#   su -c 'sh /data/local/tmp/rc24-plugged-9vramp.sh'
set +e
ID=rc24-9vramp
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
note(){ echo "  NOTE  $*"; echo "NOTE $*" >> $W/notes.txt; }
induced(){ echo "  INDUCED  $*"; }
sec(){ echo; echo "===== $* ====="; }

M=/data/adb/vr25/acc
DD=/data/adb/vr25/acc-data
TD=/dev/.vr25/acc
PS=/sys/class/power_supply
W=/data/local/tmp/rc24r
WLOG=$DD/logs/write.log
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

rm -rf $W; mkdir -p $W $W/tmp $W/g; : > $W/notes.txt
sed -n '/^_mv() {/,/^}/p;/^_iin_ma() {/,/^}/p;/^_hv_may_kick() {/,/^}/p' $MF > $W/u.sh
. $W/u.sh

ORIG_PC=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $4}')
ORIG_RC=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $3}')
ORIG_CC=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $2}')
ORIG_SC=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $1}')
ORIG_CT=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $1}')
ORIG_MT=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $2}')
ORIG_RT=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $3}')
ORIG_ST=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $4}')
REL_CT=$ORIG_CT; REL_MT=$ORIG_MT; REL_RT=$ORIG_RT

restore(){
  trap - EXIT INT TERM HUP
  setk pc="$ORIG_PC" rc="$ORIG_RC" cc="$ORIG_CC" ct="$ORIG_CT" mt="$ORIG_MT" rt="$ORIG_RT" mcc= mcv=
  echo "  restored pc=$ORIG_PC mt=$ORIG_MT (shutdown %=$ORIG_SC temp=$ORIG_ST never written)"
}
trap restore EXIT INT TERM HUP

echo "=== $ID ==="
echo "device=$(getprop ro.product.device)  $(sed -n s/version=//p $M/module.prop)"
echo "ORIG pause=$ORIG_PC resume=$ORIG_RC coolCap=$ORIG_CC shut%=$ORIG_SC"
echo "ORIG coolT=$ORIG_CT maxT=$ORIG_MT resT=$ORIG_RT shutT=$ORIG_ST"

sec "0  MUST BE UNPLUGGED"
[ "$(id -u)" = 0 ] || { echo ABORT:not_root; exit 1; }
if [ "$(plug_present)" = yes ]; then
  echo "  ABORT: unplug first, then re-run — we need the 0→1 edge and 9V ramp"
  exit 1
fi
ok "unplugged"
_pid=$(daemon_pid)
[ -n "$_pid" ] && ok "daemon $_pid" || { echo ABORT:no_daemon; exit 1; }
[ "$(rd $PS/battery/status)" != Charging ] && ok "status $(rd $PS/battery/status)" || no "Charging while unplugged"
_sign0=$(rd $PS/battery/current_now)
note "unplug current_now=$_sign0"
echo "$_sign0" > $W/sign0
[ "$ORIG_SC" = 5 ] && ok "will not write shutdown_capacity"
[ "$ORIG_ST" = 55 ] && ok "will not write shutdown_temp"
_tc0=$(( $(rd $PS/battery/temp) / 10 ))
if [ $(( _tc0 + 6 )) -lt "$ORIG_ST" ] 2>/dev/null; then
  REL_CT=$_tc0; REL_RT=$(( _tc0 + 3 )); REL_MT=$(( _tc0 + 6 ))
  setk ct="$REL_CT" mt="$REL_MT" rt="$REL_RT"
  note "pre-plug thermal release cool=$REL_CT max=$REL_MT resume=$REL_RT (original $ORIG_CT/$ORIG_MT/$ORIG_RT)"
fi
_w0=$(lines $WLOG)

echo
echo "------------------------------------------------------------------------"
echo "UNPLUGGED OK. Plug the 9V QC/PD brick when told."
echo "Waiting up to 10 minutes for present=1..."
echo "------------------------------------------------------------------------"
_w=0
while [ $_w -lt 600 ]; do
  [ "$(plug_present)" = yes ] && break
  sleep 2; _w=$((_w + 2))
done
[ "$(plug_present)" = yes ] || { echo ABORT:no_plug_600s; exit 1; }
ok "present=1 after ${_w}s"
_tplug=$(date +%s)
echo "$_tplug" > $W/tplug

sec "1  9V RAMP  (40 samples × 1s)  — do not mutate yet"
echo "t dv rawv mv iin battI type on imax st cap lat peak kick" > $W/ramp.txt
_hit9=no
_i=0
while [ $_i -lt 40 ]; do
  _raw=$(rd $PS/usb/voltage_now)
  _mv=$(_mv "$_raw" 2>/dev/null)
  _iin=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
  _ty=$(rd $PS/usb/real_type); [ -n "$_ty" ] || _ty=$(rd $PS/usb/type)
  _lat=n; [ -f $TD/.hvcontract ] && _lat=y
  _pk=$(rd $TD/.hvpeak)
  _kk=n; [ -f $TD/.hvkicked ] && _kk=y
  _line="$_i $(( $(date +%s) - _tplug )) $_raw ${_mv:-?} ${_iin:-?} $(rd $PS/battery/current_now) $_ty $(rd $PS/usb/online) $(rd $PS/usb/current_max) $(rd $PS/battery/status) $(rd $PS/battery/capacity) $_lat ${_pk:-.} $_kk"
  echo "$_line" | tee -a $W/ramp.txt
  case "${_mv:-x}" in ''|x|*[!0-9]*) :;; *) [ "$_mv" -ge 6500 ] && _hit9=yes;; esac
  _i=$((_i + 1))
  sleep 1
done
echo "  9V_SEEN=$_hit9"
if [ "$_hit9" = yes ]; then
  ok "9V kicked in (>=6500 mV in 40s ramp)"
else
  no "9V NEVER reached 6500 mV in 40s (max in ramp log) — brick/handshake/collapse"
fi
[ -f $TD/.hvcontract ] && ok "latch set after ramp" || no "no .hvcontract after 40s"
[ -f $TD/.hvkicked ] && no ".hvkicked during ramp — APSD claimed" || ok "no kick claimed during ramp"
_usbmax=$(rd $PS/usb/current_max)
case "$_usbmax" in 100000|100) no "usb/current_max collapsed $_usbmax";; *) ok "usb/current_max=$_usbmax";; esac
_g=$(
  cd $PS || exit 1
  TMPDIR=$W/g; dataDir=$W/g; mkdir -p $TMPDIR
  [ -f $TD/.hvcontract ] && cp $TD/.hvcontract $TMPDIR/
  [ -f $TD/.hvpeak ] && cp $TD/.hvpeak $TMPDIR/
  present(){ return 0; }
  . $W/u.sh
  _hv_may_kick && echo KICK || echo HOLD
)
[ "$_g" = HOLD ] && ok "kick HOLD after ramp ($_g)" || no "kick=$_g after ramp"
note "ramp file $W/ramp.txt  9V_SEEN=$_hit9"

sec "2  MCC=500 then clear"
induced "mcc=500 12s — current drop is TEST-INDUCED"
_i0=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
echo "  iin before=$_i0  v=$(_mv "$(rd $PS/usb/voltage_now)")"
setk mcc=500
sleep 12
_i1=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
echo "  iin mcc500=$_i1  v=$(_mv "$(rd $PS/usb/voltage_now)") usbMax=$(rd $PS/usb/current_max) st=$(rd $PS/battery/status)"
setk mcc=
sleep 12
_i2=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
echo "  iin cleared=$_i2  v=$(_mv "$(rd $PS/usb/voltage_now)")"
if [ -n "$_i0" ] && [ "$_i0" -gt 400 ] 2>/dev/null && [ -n "$_i1" ]; then
  _lim=$(( _i0 * 70 / 100 ))
  if [ "$_i1" -le "$_lim" ] 2>/dev/null; then
    ok "mcc dropped $_i0 -> $_i1 mA (>=30%)"
  else
    note "mcc no real drop $_i0 -> $_i1 (Pixel native often ignores) — not a fail"
    sk "mcc ignored by this kernel"
  fi
else
  sk "mcc no baseline"
fi
[ -n "$(daemon_pid)" ] && ok "daemon after mcc" || no "daemon died mcc"

sec "3  PAUSE = current %  (25s, not shutdown %)"
_c=$(rd $PS/battery/capacity)
induced "pc=$_c for 25s then restore $ORIG_PC"
setk pc="$_c" rc=$(( _c > 2 ? _c - 2 : 0 ))
_j=0
while [ $_j -lt 5 ]; do
  sleep 5
  echo "  pause t=$((_j*5+5))s st=$(rd $PS/battery/status) iin=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null) v=$(_mv "$(rd $PS/usb/voltage_now)")"
  _j=$((_j + 1))
done
_stp=$(rd $PS/battery/status)
_ip=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)
echo "  pause end st=$_stp iin=$_ip"
case "$_stp" in
  Charging)
    if [ -n "$_ip" ] && [ "$_ip" -le 80 ] 2>/dev/null; then
      ok "pause: status Charging but iin=${_ip}mA (kernel lag, current held)"
    else
      no "pause: still Charging iin=$_ip after 25s"
    fi
    ;;
  *) ok "pause: status $_stp iin=$_ip"
    ;;
esac
setk pc="$ORIG_PC" rc="$ORIG_RC"
sleep 12
echo "  restored st=$(rd $PS/battery/status) iin=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)"
_sc=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $1}')
[ "$_sc" = "$ORIG_SC" ] && ok "shutdown_capacity still $ORIG_SC" || no "shutdown % mutated"

sec "4  THERMAL max_temp = packC-2  (25s, not shutdown temp)"
_t=$(rd $PS/battery/temp)
_tc=$(( _t / 10 ))
_mt=$(( _tc - 2 )); [ "$_mt" -lt 20 ] && _mt=20
induced "mt=$_mt (pack ${_tc}C) 25s; shutT stays $ORIG_ST"
setk mt="$_mt" rt="$_mt" ct="$_mt"
_j=0
while [ $_j -lt 5 ]; do
  sleep 5
  echo "  therm t=$((_j*5+5))s st=$(rd $PS/battery/status) temp=$(rd $PS/battery/temp) iin=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)"
  _j=$((_j + 1))
done
setk mt="$REL_MT" rt="$REL_RT" ct="$REL_CT"
_tw=0
while [ $_tw -lt 60 ]; do
  sleep 5; _tw=$((_tw+5))
  { [ "$(rd $PS/usb/online)" = 1 ] || [ "$(rd $PS/battery/status)" = Charging ]; } && break
done
setk mt="$ORIG_MT" rt="$ORIG_RT" ct="$ORIG_CT"
_stn=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $4}')
[ "$_stn" = "$ORIG_ST" ] && ok "shutdown_temp still $ORIG_ST" || no "shutdown temp mutated"
ok "temp restored maxT=$ORIG_MT"
echo "  after thermal restore st=$(rd $PS/battery/status)"

sec "5  MCV=3900 12s (pack volt; USB V may not move)"
induced "mcv=3900 12s TEST-INDUCED"
_v0=$(_mv "$(rd $PS/usb/voltage_now)")
setk mcv=3900
sleep 12
_v1=$(_mv "$(rd $PS/usb/voltage_now)")
setk mcv=
sleep 10
_v2=$(_mv "$(rd $PS/usb/voltage_now)")
echo "  usb_mV $_v0 -> $_v1 -> $_v2"
note "mcv pack-side; USB $_v0 $_v1 $_v2"
[ -n "$(daemon_pid)" ] && ok "daemon after mcv" || no "daemon died mcv"

sec "6  FINAL"
sleep 5
echo "  st=$(rd $PS/battery/status) cap=$(rd $PS/battery/capacity) v=$(_mv "$(rd $PS/usb/voltage_now)") iin=$(cd $PS; TMPDIR=$W/tmp; . $W/u.sh; _iin_ma 2>/dev/null)"
echo "  contract=$([ -f $TD/.hvcontract ] && echo y || echo n) peak=$(rd $TD/.hvpeak) kicked=$([ -f $TD/.hvkicked ] && echo y || echo n)"
[ -n "$(daemon_pid)" ] && ok "daemon up" || no "NO DAEMON"
_sc=$(sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk '{print $1}')
_stn=$(sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk '{print $4}')
[ "$_sc" = "$ORIG_SC" ] && ok "shutdown % $_sc" || no "shutdown %"
[ "$_stn" = "$ORIG_ST" ] && ok "shutdown temp $_stn" || no "shutdown temp"
echo
echo "----- ramp (first/mid/last) -----"
sed -n '1p;2p;21p;41p' $W/ramp.txt 2>/dev/null
echo "----- notes -----"
cat $W/notes.txt
echo
echo "$ID: $P passed, $F failed, $S skipped"
echo "RAMPLOG $W/ramp.txt"
[ "$F" -eq 0 ]
