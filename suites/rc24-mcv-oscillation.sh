#!/system/bin/sh
# rc24-mcv-oscillation.sh - reproduce the Pixel 4a 5G report: charging alternating every few
#                           seconds while draining down to the pause level.
#
#   su -c 'sh /data/local/tmp/suites/rc24-mcv-oscillation.sh'      # PLUGGED, above the pause level
#
# THE FIELD REPORT (bramble, Pixel 4a 5G, ACC rc23 + AccA 2.0.1-rc22)
#   "When draining to pcap (idle not allowed above pcap), it alternates every few seconds between
#    draining & charging. It does reach pcap and settles-in to bypass from then on."
#
# WHAT THE DIAGNOSTIC SHOWED
#   flight.log alternated present=1/Idle with present=0/Discharging roughly every 15-30s for four
#   minutes, then stopped the moment the charger renegotiated USB_DCP 1.5A -> USB_PD 3A.
#   The write ledger over the same window shows the voltage cap being flipped:
#       11:18:11  main/voltage_max <- 4200000 (was 3600000)
#       11:18:15  main/voltage_max <- 4000000 (was 4200000)
#       11:22:36  main/voltage_max <- 4200000 (was 4000000)
#       11:22:37  main/voltage_max <- 4000000 (was 4200000)
#   Their pack reads 3.73V at 41%, so a 4.0V cap sits essentially AT the pack voltage.
#
#   Two things that do not fit a simple "the cap stops charging" story, and are why this suite
#   exists rather than a patch:
#     - there were 3 write episodes against about 8 alternations, so the writes cannot be causing
#       every one of them;
#     - three nodes read 3600000 before a restore, a value ACC never logged writing, and
#       battery/constant_charge_voltage read -1 twice, which is a driver returning an error.
#
# WHAT THIS SUITE DOES
#   Recreates the conditions on a phone we own and WATCHES, sampling once a second: the supply
#   nodes, the voltage-cap nodes, and the write ledger. It does not assume the cap is the cause.
#   It reports whether an alternation happens at all, how it correlates with ACC writes, and
#   whether it survives with the cap removed - which is the experiment that separates "ACC's cap
#   is driving it" from "this charger/driver flaps and the cap is incidental".
#
# CONDITIONS IT NEEDS
#   plugged in, and the battery ABOVE the pause level so the drain-to-pcap situation exists.
#   It forces that by lowering the pause below the current level, and puts it back afterwards.
#
# EVERYTHING IT TOUCHES IS RESTORED
#   pause, resume, shutdown capacity (ACC drags it when the pause moves), the voltage cap, and
#   allowIdleAbovePcap. The restore is verified and printed.

set +e
ID=rc24-mcv-oscillation
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
info(){ echo "  ....  $*"; }
sec(){ echo; echo "===== $* ====="; }

M=${M:-/data/adb/vr25/acc}
DD=${DD:-/data/adb/vr25/acc-data}
PS=/sys/class/power_supply
CFG=$DD/config.txt
AA=$M/acca.sh
LEDGER=$DD/logs/write-ledger.txt
W=/data/local/tmp/rc24osc
WATCH=${WATCH:-180}

rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
lines(){ _n=$(wc -l < "$1" 2>/dev/null); case "${_n:-x}" in ''|*[!0-9]*) echo 0;; *) echo "$_n";; esac; }
capf(){ sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk -v n=$1 '{print $n}'; }
cfgv(){ sed -n "s/^$1=//p" $CFG 2>/dev/null | tr -d '()'; }
setk(){ "$AA" -s "$@" >/dev/null 2>&1; }
daemon_pid(){ pgrep -f "$M/accd.sh" 2>/dev/null | head -1; }
present_any(){ _p=no; for _n in $PS/*/present; do case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac; [ -f "$_n" ] || continue; [ "$(rd "$_n")" = 1 ] && _p=yes; done; echo $_p; }
online_any(){ _o=no; for _n in $PS/*/online; do case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac; [ -f "$_n" ] || continue; [ "$(rd "$_n")" = 1 ] && _o=yes; done; echo $_o; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

ORIG_SC=$(capf 1); ORIG_CC=$(capf 2); ORIG_RC=$(capf 3); ORIG_PC=$(capf 4)
ORIG_MCV=$(cfgv maxChargingVoltage)
ORIG_AIAPC=$(cfgv allowIdleAbovePcap)

restore(){
  trap - EXIT INT TERM HUP
  sec "RESTORE"
  setk mcv=
  [ -n "$ORIG_MCV" ] && setk mcv="${ORIG_MCV%% *}"
  setk pc="$ORIG_PC" rc="$ORIG_RC" cc="$ORIG_CC"
  [ -n "$ORIG_AIAPC" ] && setk allow_idle_above_pcap="$ORIG_AIAPC"
  sleep 3
  _sc=$(capf 1)
  if [ "$_sc" != "$ORIG_SC" ]; then
    echo "  shutdown_capacity moved $ORIG_SC -> $_sc while the pause was forced; putting it back"
    setk sc="$ORIG_SC"; sleep 2
  fi
  echo "  capacity=$(sed -n 's/^capacity=//p' $CFG)  (shutdown cool resume pause aiapc)"
  echo "  maxChargingVoltage=$(cfgv maxChargingVoltage)"
  echo "  allowIdleAbovePcap=$(cfgv allowIdleAbovePcap)"
  [ -n "$(daemon_pid)" ] || { sh $M/service.sh >/dev/null 2>&1; sleep 5; }
  echo "  daemon=$(daemon_pid || echo DOWN)  cap=$(rd $PS/battery/capacity)%  st=$(rd $PS/battery/status)"
  echo
  echo "$ID: $P passed, $F failed, $S skipped"
  [ "$F" -eq 0 ] && exit 0 || exit 1
}
trap restore EXIT INT TERM HUP

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)"
echo "build  : $(sed -n 's/^version=//p' $M/module.prop)  ($(sed -n 's/^versionCode=//p' $M/module.prop))"
echo "config : capacity=$(sed -n 's/^capacity=//p' $CFG)  mcv=[$ORIG_MCV]  aiapc=[$ORIG_AIAPC]"

sec "0  CONDITIONS"
[ "$(id -u)" = 0 ] || { no "not root"; exit 1; }
[ -n "$(daemon_pid)" ] || { no "no daemon running"; exit 1; }
[ "$(present_any)" = yes ] || { no "not plugged in - this reproduces a plugged-in oscillation"; exit 1; }
ok "plugged in, daemon running"

_gcsl=
for _gd in /sys/devices/platform/google,charger /sys/devices/platform/soc/soc:google,charger; do
  [ -f "$_gd/charge_stop_level" ] && [ -f "$_gd/charge_start_level" ] && { _gcsl=$_gd/charge_stop_level; break; }
done
if [ -n "$_gcsl" ]; then
  ok "native firmware limit present ($_gcsl) - same class as the reporting phone"
else
  sk "no native firmware limit on this phone - the report is from a firmware-limit phone, so this is a weaker reproduction"
fi

CAP=$(rd $PS/battery/capacity)
PACKV=$(rd $PS/battery/voltage_now)
PACKMV=$(( PACKV / 1000 ))
info "level ${CAP}%  pack ${PACKMV}mV  status $(rd $PS/battery/status)"

sec "1  RECREATING THE REPORTED SITUATION"
# The reporter is above the pause level with idle-above-pause disallowed, and a voltage cap set at
# essentially the pack's own voltage. Force the same shape from whatever this phone is at now.
NEWPC=$(( CAP - 2 ))
NEWRC=$(( CAP - 5 ))
if [ "$NEWPC" -lt 10 ] 2>/dev/null; then
  no "battery is only ${CAP}% - too low to place a pause below it safely"
  exit 1
fi
# Round the cap to the nearest 50mV at or just under the pack, exactly the relationship the
# reporter has (3.73V pack against a 4.0V cap on a pack that reaches 4.0V around 46%).
CAPMV=$(( (PACKMV / 50) * 50 ))
info "forcing pause=${NEWPC}% resume=${NEWRC}% (level is ${CAP}%), aiapc=false, mcv=${CAPMV}mV"
setk allow_idle_above_pcap=false
setk pc="$NEWPC" rc="$NEWRC"
setk mcv="$CAPMV"
sleep 5
info "config now: capacity=$(sed -n 's/^capacity=//p' $CFG) mcv=$(cfgv maxChargingVoltage | cut -c1-40) aiapc=$(cfgv allowIdleAbovePcap)"
[ "$(cfgv allowIdleAbovePcap)" = false ] && ok "allowIdleAbovePcap is false, as in the report" \
                                        || no "allowIdleAbovePcap did not take (is $(cfgv allowIdleAbovePcap))"

sec "2  WATCHING FOR THE ALTERNATION  (${WATCH}s, sampled every second)"
_l0=$(lines $LEDGER)
_t0=$(date +%s)
_prev=; _flips=0; _pdrop=0; _n=0
: > $W/trace.txt
while [ $(( $(date +%s) - _t0 )) -lt $WATCH ]; do
  _n=$((_n+1))
  _st=$(rd $PS/battery/status); _pr=$(present_any); _on=$(online_any)
  _cur=$(rd $PS/battery/current_now)
  _state="$_st/$_pr/$_on"
  echo "$(date +%s) $_state cur=$_cur cap=$(rd $PS/battery/capacity)" >> $W/trace.txt
  if [ -n "$_prev" ] && [ "$_state" != "$_prev" ]; then
    _flips=$((_flips+1))
    echo "    flip $_flips at +$(( $(date +%s) - _t0 ))s : $_prev -> $_state"
  fi
  [ "$_pr" = no ] && _pdrop=$((_pdrop+1))
  _prev=$_state
  sleep 1
done
_l1=$(lines $LEDGER)
_lgrew=$(( _l1 - _l0 ))
info "$_n samples in ${WATCH}s: $_flips state changes, $_pdrop samples with the supply absent"
info "write ledger grew $_lgrew line(s) during the watch"
[ "$_lgrew" -gt 0 ] && tail -n $_lgrew $LEDGER | sed 's/^/      /'

sec "3  VERDICT"
if [ "$_flips" -ge 4 ]; then
  no "REPRODUCED: $_flips state changes in ${WATCH}s - the reported alternation happens on this phone"
  echo "      trace: $W/trace.txt"
elif [ "$_flips" -ge 1 ]; then
  info "$_flips state change(s) - some movement, but not the every-few-seconds alternation reported"
  ok "no sustained alternation at this cap setting"
else
  ok "no alternation at all in ${WATCH}s with the cap at the pack voltage and idle-above-pause disallowed"
fi
if [ "$_pdrop" -gt 0 ]; then
  no "the supply read ABSENT in $_pdrop of $_n samples while the cable was in - the port is dropping"
else
  ok "the supply stayed present in all $_n samples"
fi

sec "4  THE CONTROL: SAME SITUATION, NO VOLTAGE CAP"
# If the cap is what drives it, removing the cap must stop it. If the alternation continues without
# a cap, the cap was incidental and the cause is the charger or the driver.
setk mcv=
sleep 5
info "mcv cleared: $(cfgv maxChargingVoltage | cut -c1-40)"
_t0=$(date +%s); _prev=; _flips2=0; _pdrop2=0; _n2=0
while [ $(( $(date +%s) - _t0 )) -lt $WATCH ]; do
  _n2=$((_n2+1))
  _state="$(rd $PS/battery/status)/$(present_any)/$(online_any)"
  [ -n "$_prev" ] && [ "$_state" != "$_prev" ] && _flips2=$((_flips2+1))
  [ "$(present_any)" = no ] && _pdrop2=$((_pdrop2+1))
  _prev=$_state
  sleep 1
done
info "without a voltage cap: $_flips2 state changes, $_pdrop2 absent samples in ${WATCH}s"
if [ "$_flips" -ge 4 ] && [ "$_flips2" -lt 2 ]; then
  no "ATTRIBUTED: the alternation needs the voltage cap ($_flips with it, $_flips2 without)"
elif [ "$_flips" -ge 4 ] && [ "$_flips2" -ge 4 ]; then
  no "NOT the cap: it alternates with and without it ($_flips vs $_flips2) - the charger or driver is flapping"
else
  ok "no alternation in either arm on this phone ($_flips with the cap, $_flips2 without)"
fi

restore
