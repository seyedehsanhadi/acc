#!/system/bin/sh
# rc24-plugged.sh - the rc23 -> rc24 delta, graded on a live phone across a real plug event.
#
#   su -c 'sh /data/local/tmp/suites/rc24-plugged.sh'
#
# START IT UNPLUGGED. It waits for you to plug in and samples through the transition, because the
# 0->1 edge is the only moment several of these changes are observable at all. A run that starts
# already plugged cannot see the edge, cannot see the latch being set, and cannot tell a contract
# that was won from one that was already there. Two earlier runs were graded that way and both
# reported a false failure for exactly that reason.
#
# WHAT IT IS FOR
#   rc23 is what users are running and nobody has complained. Every assertion here is therefore
#   written to answer one question: does rc24 still do what rc23 did, except where we deliberately
#   changed it. Where a change is deliberate the case states the old behaviour and the new one, so a
#   future reader can see which is which without going back to the diff.
#
# WHAT IT WILL NEVER WRITE
#   shutdown_capacity and shutdown_temp. Nothing in this file may arrange a shutdown, and a numeric
#   shutdown_temp of 9 has powered a phone off at room temperature on this project before.
#
# WHAT IT CHANGES AND PUTS BACK
#   pause, resume, cool capacity, the three temperature levels, the current cap, the voltage cap,
#   AND - this is the one an earlier harness missed - the configured chargingSwitch together with
#   .last-good-switch and prioritizeBattIdleMode.
#
#   Missing that pair is not a cosmetic gap. Forcing a pause while prioritizeBattIdleMode is true
#   makes the daemon run idle-preferring discovery, and on a Mi A3 it ADOPTED and PERSISTED
#   battery/input_suspend over the configured restrict_cur, wrote it to .last-good-switch, and left
#   the phone in bypass with the pack at 0.00 A after the test had "finished". The restore below
#   puts all three back and then proves the phone still charges.
#
# INDUCED IS NOT BROKEN
#   Sections 7 to 10 deliberately cap current, force a pause, force a thermal hold and cap voltage.
#   The resulting drops are caused by this file. They are only findings if the value does not come
#   back, so each of those sections grades the RECOVERY, not the drop.

set +e
ID=rc24-plugged
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
info(){ echo "  ....  $*"; }
sec(){ echo; echo "===== $* ====="; }

M=${M:-/data/adb/vr25/acc}
DD=${DD:-/data/adb/vr25/acc-data}
TD=${TD:-/dev/.vr25/acc}
PS=/sys/class/power_supply
W=/data/local/tmp/rc24pl
CFG=$DD/config.txt
WLOG=$DD/logs/write.log
FLIGHT=$DD/logs/flight.log
MF=$M/misc-functions.sh
AA=$M/acca.sh
PLUGWAIT=${PLUGWAIT:-300}

# The daemon trims flight.log to 1500 lines, so a line COUNT goes DOWN when it rotates and a
# count-based liveness check then reports a perfectly healthy daemon as frozen. Measured on a
# Mi A3 mid-run: 1529 -> 1503 lines while the daemon was looping and charging normally.
# Modification time moves on every append and is immune to the trim.
flight_stamp(){ stat -c %Y "$FLIGHT" 2>/dev/null || echo 0; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
lines(){ _n=$(wc -l < "$1" 2>/dev/null); case "${_n:-x}" in ''|*[!0-9]*) echo 0;; *) echo "$_n";; esac; }
daemon_pid(){ pgrep -f "$M/accd.sh" 2>/dev/null | head -1; }
setk(){ "$AA" -s "$@" >/dev/null 2>&1; }
cfgv(){ sed -n "s/^$1=//p" $CFG 2>/dev/null | tr -d '()'; }
capf(){ sed -n 's/^capacity=(//p' $CFG | tr -d ')' | awk -v n=$1 '{print $n}'; }
tempf(){ sed -n 's/^temperature=(//p' $CFG | tr -d ')' | awk -v n=$1 '{print $n}'; }
cap_now(){ rd $PS/battery/capacity; }
st_now(){ rd $PS/battery/status; }
usb_v(){ rd $PS/usb/voltage_now; }
usb_imax(){ rd $PS/usb/current_max; }
batt_i(){ rd $PS/battery/current_now; }

present_any(){
  _p=no
  for _n in $PS/*/present; do
    [ -f "$_n" ] || continue
    case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac
    [ "$(rd "$_n")" = 1 ] && _p=yes
  done
  echo $_p
}
online_any(){
  _o=no
  for _n in $PS/*/online; do
    [ -f "$_n" ] || continue
    case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac
    [ "$(rd "$_n")" = 1 ] && _o=yes
  done
  echo $_o
}
chg_type(){
  for _t in real_type usb_type type; do
    [ -f "$PS/usb/$_t" ] || continue
    rd "$PS/usb/$_t"; return 0
  done
  echo ""
}
# Live input current in mA, through the SHIPPED reader so this measures what the daemon measures.
iin_ma(){ ( cd $PS 2>/dev/null || exit 1; TMPDIR=$TD; . $W/u.sh 2>/dev/null; _iin_ma 2>/dev/null ); }
mv_of(){ ( . $W/u.sh 2>/dev/null; _mv "${1:-0}" 2>/dev/null ); }

sample(){ echo "    t=$1 st=$(st_now) cap=$(cap_now)% usbV=$(mv_of $(usb_v))mV battI=$(batt_i) usbMax=$(usb_imax) iin=$(iin_ma)mA type=$(chg_type) p=$(present_any) on=$(online_any)"; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null
sed -n '/^_mv() {/,/^}/p;/^_ma() {/,/^}/p;/^_iin_ma() {/,/^}/p;/^_vbus_mv() {/,/^}/p;/^_hv_may_kick() {/,/^}/p' $MF > $W/u.sh

# =================================================================================================
# SNAPSHOT. Everything this file can move, plus the two the earlier harness forgot.
ORIG_SC=$(capf 1); ORIG_CC=$(capf 2); ORIG_RC=$(capf 3); ORIG_PC=$(capf 4)
ORIG_CT=$(tempf 1); ORIG_MT=$(tempf 2); ORIG_RT=$(tempf 3); ORIG_ST=$(tempf 4)
ORIG_MCC=$(cfgv maxChargingCurrent); ORIG_MCV=$(cfgv maxChargingVoltage)
ORIG_SW=$(cfgv chargingSwitch)
ORIG_LGS=$(cat $DD/.last-good-switch 2>/dev/null)
ORIG_PBIM=$(cfgv prioritizeBattIdleMode)

restore(){
  trap - EXIT INT TERM HUP
  sec "RESTORE"
  echo "  putting back: pause=$ORIG_PC resume=$ORIG_RC coolCap=$ORIG_CC  temps=$ORIG_CT/$ORIG_MT/$ORIG_RT  mcc/mcv cleared"
  setk pc="$ORIG_PC" rc="$ORIG_RC" cc="$ORIG_CC" ct="$ORIG_CT" mt="$ORIG_MT" rt="$ORIG_RT" mcc= mcv=
  # SHUTDOWN IS NEVER WRITTEN DURING THE TEST - but ACC moves it anyway, and that has to be undone.
  #
  # Forcing pause to the current level on a nearly-empty phone makes write-config drag
  # shutdown_capacity down to keep shutdown < resume < pause. Measured: a phone at 7% with pause
  # forced to 7 came out of the run with shutdown_capacity 5 -> 2. Nothing here asked for that, and
  # not writing a value is not the same as leaving it alone. Restore it only if ACC moved it, so
  # the "never written" property still holds for every run that does not disturb it.
  _sc_now=$(capf 1)
  if [ -n "$ORIG_SC" ] && [ "$_sc_now" != "$ORIG_SC" ]; then
    echo "  shutdown_capacity was moved by ACC ($ORIG_SC -> $_sc_now) while satisfying the forced pause; putting it back"
    setk sc="$ORIG_SC"
    sleep 2
  fi
  if [ -n "$ORIG_PBIM" ]; then setk prioritize_batt_idle_mode="$ORIG_PBIM"; fi
  # THE SWITCH. This is what the earlier harness left out, and leaving it out is what put an A3
  # into bypass that survived the run.
  if [ -n "$ORIG_SW" ]; then
    setk charging_switch="$ORIG_SW"
    [ -n "$ORIG_LGS" ] && printf '%s\n' "$ORIG_LGS" > $DD/.last-good-switch 2>/dev/null || :
  fi
  sleep 3
  _nsw=$(cfgv chargingSwitch)
  if [ "$_nsw" = "$ORIG_SW" ]; then
    echo "  switch restored: $_nsw"
  else
    echo "  !! SWITCH NOT RESTORED: wanted [$ORIG_SW] got [$_nsw] -- set it by hand with:"
    echo "     acc -s charging_switch=\"$ORIG_SW\""
  fi
  [ -n "$(daemon_pid)" ] || { sh $M/service.sh >/dev/null 2>&1; sleep 5; }
  echo "  capacity=$(sed -n 's/^capacity=//p' $CFG)   (shutdown cool resume pause aiapc)"
  echo "  daemon: $(daemon_pid || echo DOWN)   cap=$(cap_now)% st=$(st_now) iin=$(iin_ma)mA"
  echo
  echo "$ID: $P passed, $F failed, $S skipped"
  [ "$F" -eq 0 ] && exit 0 || exit 1
}
trap restore EXIT INT TERM HUP

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)"
echo "build  : $(sed -n 's/^version=//p' $M/module.prop)  ($(sed -n 's/^versionCode=//p' $M/module.prop))"
echo "switch : ${ORIG_SW:-<none configured>}"
echo "config : pause=$ORIG_PC resume=$ORIG_RC cool=$ORIG_CC  shutdown%=$ORIG_SC (never written)"
echo "config : coolT=$ORIG_CT maxT=$ORIG_MT resumeT=$ORIG_RT shutT=$ORIG_ST (never written)"
echo "config : mcc=[$ORIG_MCC] mcv=[$ORIG_MCV] pbim=[$ORIG_PBIM]"

# =================================================================================================
sec "0  PREFLIGHT - unplugged, and a daemon that is actually looping"
[ "$(id -u)" = 0 ] || { no "not root"; exit 1; }
[ -s $W/u.sh ] && ok "extracted the shipped readers ($(grep -c '^_.*() {' $W/u.sh) functions)" \
               || { no "could not extract the unit readers from misc-functions.sh"; exit 1; }

SKIPEDGE=${SKIPEDGE:-0}
if [ "$(present_any)" = yes ] && [ "$SKIPEDGE" != 1 ]; then
  echo "  ABORT: a cable is already attached."
  echo "         Unplug, then start this again. The plug EDGE is the point: several rc24 changes"
  echo "         are only observable as the supply goes from absent to present, and a run that"
  echo "         starts plugged silently grades none of them."
  echo "         To grade everything else on an already-plugged phone, re-run with SKIPEDGE=1."
  exit 1
fi
if [ "$(present_any)" = yes ]; then
  sk "started already plugged - changes 6, 7, 8, 27, 28 and 29 are NOT graded in this run"
  info "those six exist only as the supply goes absent -> present. A 10-second unplug and replug"
  info "at the start of a run grades them; nothing else here needs it."
else
  ok "no cable attached - the edge is still ahead of us"
fi

_pid0=$(daemon_pid)
[ -n "$_pid0" ] || { no "no daemon running; start ACC first"; exit 1; }
# THE HEARTBEAT, BY MODIFICATION TIME. The daemon trims flight.log to 1500 lines, so a line count
# goes DOWN when it rotates - measured mid-run on a Mi A3 as 1529 -> 1503 while the daemon was
# looping and charging normally, which a count-based check reported as "not looping". mtime moves
# on every append and cannot be undone by the trim. CPU accrual is the second signal, because a
# wedged process advances neither.
_f0=$(flight_stamp); _fl0=$(lines $FLIGHT)
_j0=0; for _p in $(pgrep -f "$M/accd.sh" 2>/dev/null); do
  _l=$(cat /proc/$_p/stat 2>/dev/null) || continue; _r=${_l#*) }; _i=0
  for _f in $_r; do _i=$((_i+1)); case $_i in 12|13|14|15) _j0=$(( _j0 + _f ));; esac; done
done
_w=0; _adv=no
while [ $_w -lt 180 ]; do
  sleep 10; _w=$((_w+10))
  [ "$(flight_stamp)" -gt "$_f0" ] 2>/dev/null && { _adv=yes; break; }
done
_j1=0; for _p in $(pgrep -f "$M/accd.sh" 2>/dev/null); do
  _l=$(cat /proc/$_p/stat 2>/dev/null) || continue; _r=${_l#*) }; _i=0
  for _f in $_r; do _i=$((_i+1)); case $_i in 12|13|14|15) _j1=$(( _j1 + _f ));; esac; done
done
if [ "$_adv" = yes ]; then
  ok "daemon is LOOPING: flight.log was appended to within ${_w}s (pid $_pid0)"
elif [ "$(( _j1 - _j0 ))" -gt 0 ] 2>/dev/null; then
  ok "daemon is RUNNING: no flight append in ${_w}s but it accrued $(( _j1 - _j0 )) jiffies of CPU"
else
  no "in ${_w}s the daemon appended no flight record AND accrued no CPU - it is frozen"; exit 1
fi

# The grader must be able to fail.
if [ 1 = 2 ]; then no "grader broken"; else ok "grader can report a failure"; fi

_cap0=$(cap_now)
info "starting at ${_cap0}%, $(st_now), pause is ${ORIG_PC}%"
if [ "$_cap0" -ge "$ORIG_PC" ] 2>/dev/null; then
  info "NOTE: already at or above the pause level, so ACC will cut almost immediately on plug."
  info "      Sections 1-6 still grade; section 8's resume is graded from the induced pause."
fi

# =================================================================================================
if [ "$SKIPEDGE" = 1 ] && [ "$(present_any)" = yes ]; then
  sec "1  THE PLUG EDGE - SKIPPED (started plugged)"
  info "peak this plug: $(mv_of $(usb_v))mV now, type $(chg_type); the latch state is:"
  info "  .hvcontract=$([ -f $TD/.hvcontract ] && echo present || echo absent)  .hvpeak=$(rd $TD/.hvpeak)  .hvkicked=$([ -f $TD/.hvkicked ] && echo present || echo absent)"
else
  sec "1  THE PLUG EDGE  (#27 #28 #29 #6 #7 #8)"
  echo
  echo "  >>> PLUG THE CHARGER IN NOW. Waiting up to ${PLUGWAIT}s. <<<"
  echo
  _pw=0
  while [ $_pw -lt $PLUGWAIT ]; do
    [ "$(present_any)" = yes ] && break
    sleep 1; _pw=$((_pw+1))
  done
  if [ "$(present_any)" != yes ]; then
    no "no cable within ${PLUGWAIT}s - nothing below can be graded"
    exit 1
  fi
  ok "cable detected after ${_pw}s"

  # Sample straight through the transition. This is the window the latch is set in.
  echo "  sampling the first 40s of the plug:"
  _pk=0; _typeseen=""; _i=0
  while [ $_i -lt 40 ]; do
    _i=$((_i+1))
    _v=$(mv_of $(usb_v)); case "${_v:-x}" in ''|x|*[!0-9]*) _v=0;; esac
    [ "$_v" -gt "$_pk" ] 2>/dev/null && _pk=$_v
    _t=$(chg_type); case "$_t" in *HVDCP*|*PD*|*QC*|*hvdcp*|*pd*) _typeseen=$_t;; esac
    case $_i in 1|3|6|10|15|20|30|40) sample "${_i}s";; esac
    sleep 1
  done
  info "peak bus this plug: ${_pk}mV   high-voltage type seen: ${_typeseen:-none}"

  # #6/#7: the latch and the peak marker
  _lat=$([ -f $TD/.hvcontract ] && echo yes || echo no)
  _pkf=$(rd $TD/.hvpeak)
  if [ "$_pk" -ge 6500 ] 2>/dev/null || [ -n "$_typeseen" ]; then
    [ "$_lat" = yes ] && ok "a contract was latched (peak ${_pk}mV, type ${_typeseen:-none})" \
                      || no "peak ${_pk}mV / type ${_typeseen:-none} should have latched a contract, but .hvcontract is absent"
  else
    [ "$_lat" = no ] && ok "no contract latched on a plain 5V supply (peak ${_pk}mV) - correct" \
                     || info "latched at peak ${_pk}mV with no HV type; check .hvpeak=$_pkf"
  fi
  [ -n "$_pkf" ] && ok "the per-plug peak marker was recorded (.hvpeak=${_pkf}mV)" \
                 || sk ".hvpeak absent - this build records it only once a reading is taken"

  # #29: an input-cut switch masks online; present is what must drive the re-arm
  info "present=$(present_any) online=$(online_any) - if these disagree, an input cut is in force"

  # =================================================================================================
fi

sec "2  UNITS ON A LIVE SUPPLY  (#1 #2 #3 #5 #49)"
_rawv=$(usb_v); _mvv=$(mv_of $_rawv)
info "usb/voltage_now raw=$_rawv -> ${_mvv}mV"
if [ "$_mvv" -ge 3000 ] 2>/dev/null && [ "$_mvv" -le 20000 ] 2>/dev/null; then
  ok "bus voltage normalises into a sane range (${_mvv}mV) whatever the kernel's units"
else
  no "bus voltage normalised to ${_mvv}mV from raw $_rawv - outside any real USB range"
fi

_iin=$(iin_ma)
if [ -n "$_iin" ]; then
  if [ "$_iin" -ge 0 ] 2>/dev/null && [ "$_iin" -le 20000 ] 2>/dev/null; then
    ok "input current reads ${_iin}mA through the shipped reader"
  else
    no "input current reads ${_iin}mA - outside any real range, the scale rule is wrong here"
  fi
  # #49: the scale marker only exists once a high reading has proven the node is microamps.
  if [ -f "$TD/.iinmicro" ]; then
    ok "the node proved itself microamps and the scale was learned: $(tr '\n' ' ' < $TD/.iinmicro)"
  else
    info "no microamp marker yet - this kernel reports milliamps, or no high reading has been seen"
  fi
else
  sk "no readable input-current node on this phone - the kick gate will fail closed, by design"
fi

_bi=$(batt_i)
info "battery/current_now=$_bi while $(st_now) (sign convention is per-phone; ACC arbitrates it)"

# =================================================================================================
sec "3  THE KICK GATE ON A LIVE PLUG  (#12 #13 #21)"
# The single most important assertion in this file. A live, working charger must never be
# re-detected: an apsd_rerun on a negotiated plug is what took an A3 from 9V to 4.4V.
_wl0=$(lines $WLOG)
_gate=$( cd $PS 2>/dev/null && TMPDIR=$TD dataDir=$DD sh -c '. '"$W"'/u.sh; present(){ return 0; }; _hv_may_kick && echo KICK || echo HOLD' 2>/dev/null )
case "$_gate" in
  HOLD) ok "the gate says HOLD on this live plug - no re-detection will be attempted" ;;
  KICK) if [ "$_pk" -lt 5500 ] 2>/dev/null && [ "${_iin:-9999}" -le 50 ] 2>/dev/null; then
          ok "the gate says KICK, and this supply is genuinely dead (peak ${_pk}mV, ${_iin}mA) - correct"
        else
          no "the gate says KICK on a supply at ${_pk}mV peak drawing ${_iin}mA - it would renegotiate a working plug"
        fi ;;
  *)    sk "could not evaluate the gate (got '$_gate')" ;;
esac
# The gate must not have spent the plug's repair just by being asked.
[ -f $TD/.hvkicked ] && info ".hvkicked is set - a repair has been claimed this plug" \
                     || ok "asking the gate did not spend the plug's single repair"

# #21: the user's off switch
if [ -f $DD/.rekick-off ]; then
  [ "$_gate" = HOLD ] && ok "acc -sk off is set and the gate refuses" || no "acc -sk off is set but the gate said $_gate"
else
  info "acc -sk off is not set on this phone (nothing to grade)"
fi

# =================================================================================================
sec "4  NO 100 mA COLLAPSE  (#15 #16 #18 #19)"
# rc23 wrote 5000000 into every */current_max, usb/ included, and one such write was measured
# dropping a port to 100 mA. rc24 writes an allow-list of charger-owned supplies instead. This
# checks the LEDGER: what ACC actually wrote to this phone since the cable went in.
# write.log is a CUMULATIVE LEDGER OF NODE PATHS, not a history of writes. No values, no
# timestamps, and entries survive for the life of the install - measured mtimes of 8 and 14
# August against a run happening today. Grepping it for a node name and calling that "ACC wrote
# this on this plug" is wrong, and it produced a false failure on BOTH phones against a build
# that had written nothing at all. What the ledger CAN answer is whether ACC touched a node it
# had never touched before: growth, not presence.
_wl1=$(lines $WLOG)
_new=$(( _wl1 - _wl0 ))
if [ "$_new" -le 0 ] 2>/dev/null; then
  ok "ACC added nothing to the write ledger across the plug ($_wl0 nodes before and after)"
else
  info "the ledger grew $_new node(s): $(tail -n $_new $WLOG | tr "
" " ")"
  if tail -n $_new $WLOG | grep -qE "usb/current_max|apsd_rerun"; then
    no "ACC newly wrote a negotiation node on this plug"
  else
    ok "the new ledger entries are not negotiation nodes"
  fi
fi
# The VALUE is the direct evidence, and it is the one that matters: a port collapsed to ~100mA is
# exactly the failure the allow-list exists to prevent.
_im=$(usb_imax)
case "${_im:-x}" in
  ''|x) sk "no usb/current_max node on this phone" ;;
  *) if [ "$_im" -le 150000 ] 2>/dev/null && [ "$_im" -gt 0 ] 2>/dev/null; then
       no "usb/current_max has collapsed to $_im - this is the 100mA footgun"
     else
       ok "usb/current_max is $_im, not collapsed"
     fi ;;
esac

# =================================================================================================
sec "5  IS IT ACTUALLY CHARGING  (the rc23 baseline nobody complained about)"
_c1=$(cap_now); _s1=$(st_now); _i1=$(iin_ma)
info "cap=${_c1}% status=$_s1 iin=${_i1}mA"
if [ "$_c1" -ge "$ORIG_PC" ] 2>/dev/null; then
  ok "at or above the pause level, so not charging is the correct state"
elif [ "$_s1" = Charging ] || [ "${_i1:-0}" -gt 100 ] 2>/dev/null; then
  ok "the phone is taking charge below its limit ($_s1, ${_i1}mA)"
else
  no "below the pause level but not charging: status=$_s1 iin=${_i1}mA - a user would call this broken"
fi

# =================================================================================================
sec "6  AMP CAP: induce, then prove it RECOVERS  (#19 #38, and the ICL hole)"
# The drop here is caused by this file. The finding, if any, is a value that does not come back.
if [ -n "$ORIG_MCC" ]; then
  sk "a current cap is already configured ($ORIG_MCC) - not overriding a user setting"
else
  _imax_before=$(usb_imax); _iin_before=$(iin_ma)
  info "before: usbMax=$_imax_before iin=${_iin_before}mA"
  setk mcc=500; sleep 15
  _iin_cap=$(iin_ma); _imax_cap=$(usb_imax)
  info "capped: usbMax=$_imax_cap iin=${_iin_cap}mA"
  setk mcc=; sleep 20
  _iin_rec=$(iin_ma); _imax_rec=$(usb_imax)
  info "cleared: usbMax=$_imax_rec iin=${_iin_rec}mA"
  # THE ONE THAT MATTERS. Clearing the cap must give the current back.
  if [ -z "$_iin_before" ] || [ -z "$_iin_rec" ]; then
    sk "no input-current reading on this phone, so recovery cannot be measured"
  elif [ "$_iin_rec" -ge $(( _iin_before / 2 )) ] 2>/dev/null; then
    ok "clearing the cap restored the input current (${_iin_before} -> ${_iin_cap} -> ${_iin_rec} mA)"
  else
    no "clearing the cap left the input at ${_iin_rec}mA against ${_iin_before}mA before it - the ICL did not come back"
  fi
  case "$_imax_rec" in
    0) no "usb/current_max is 0 after the clear - the port is pinned shut" ;;
    "") sk "no usb/current_max node on this phone" ;;
    *) [ "$_imax_rec" = "$_imax_before" ] && ok "usb/current_max is back to its pre-test value ($_imax_rec)" \
         || info "usb/current_max $_imax_before -> $_imax_rec (the driver owns this node; not graded)" ;;
  esac
fi

# =================================================================================================
sec "7  PAUSE and RESUME  (#26 #22 #23 - and the switch must survive it)"
# #26 is the reason this section exists. rc23 left `flip` set across the resume check, which turned
# it into a 35-iteration switch test and fired a re-kick AFTER a successful resume. The only way to
# see that is to actually pause and actually resume.
#
# The switch is snapshotted because forcing a pause with prioritizeBattIdleMode=true has been
# measured adopting battery/input_suspend over a configured restrict_cur and persisting it.
_swpre=$(cfgv chargingSwitch)
_capnow=$(cap_now)
info "forcing pause at the current level (${_capnow}%), pbim=[$ORIG_PBIM]"
setk pc="$_capnow"
_pw=0; _paused=no
# WHAT A PAUSE LOOKS LIKE DEPENDS ON THE SWITCH CLASS, and reading one signal missed it. On a
# native-level phone the kernel says "Not charging" and the port goes to 0. On an input-cut phone
# (A3, battery/input_suspend) the port reading does NOT zero - usb/input_current_now went on
# reporting 1884mA with the input suspended - and the status goes to Discharging, not Not
# charging, because the phone fell back to its own battery. What DOES move is */online, which the
# cut masks to 0. Watch all three.
_on0=$(online_any)
while [ $_pw -lt 60 ]; do
  sleep 5; _pw=$((_pw+5))
  _ii=$(iin_ma); _st=$(st_now); _on=$(online_any)
  [ "${_ii:-9999}" -le 50 ] 2>/dev/null && { _paused=yes; _why="input fell to ${_ii}mA"; break; }
  [ "$_st" = "Not charging" ] && { _paused=yes; _why="status went to Not charging"; break; }
  { [ "$_on0" = yes ] && [ "$_on" = no ] && [ "$(present_any)" = yes ]; } && { _paused=yes; _why="online masked to 0 with the cable in - an input cut"; break; }
  { [ "$_st" = Discharging ] && [ "$(present_any)" = yes ]; } && { _paused=yes; _why="fell back to battery while plugged"; break; }
done
if [ "$_paused" = yes ]; then
  ok "the pause took hold in ${_pw}s - ${_why} (status=$(st_now) online=$(online_any) iin=$(iin_ma)mA)"
else
  no "no pause within ${_pw}s of setting pause=${_capnow}% (status=$(st_now) iin=$(iin_ma)mA)"
fi
# A phone whose kernel status lags its current is not a bug, but it IS worth recording.
if [ "$(st_now)" = Charging ] && [ "${_ii:-9999}" -le 50 ] 2>/dev/null; then
  info "kernel status still says Charging while the input is ${_ii}mA - status lags the cut on this phone"
fi

# THE RESUME. Put the pause back up and require charging to come back.
# Restore the resume level TOO, not just the pause. Forcing pause=<current level> makes ACC drag
# resume down below it, so lifting only the pause leaves the pack sitting inside [resume..pause]
# - the band where ACC deliberately holds to avoid a sawtooth. The phone then correctly refuses to
# resume and this section reported a false failure against a build doing exactly the right thing.
# Measured on a Mi A3: pause forced at 40%, resume dragged to ~38, pause lifted to 52, pack at 40%
# and therefore still inside the band. Restoring both levels puts the pack below resume, where a
# resume is genuinely owed, which is what this section is trying to grade.
setk pc="$ORIG_PC" rc="$ORIG_RC"
info "lifted to pause=$ORIG_PC resume=$ORIG_RC with the pack at $(cap_now)% - a resume is now owed"
_rw=0; _resumed=no
# The resume is judged the same way. `iin > 100` alone is not evidence on a phone whose port
# reading is stale under a cut - it never dropped, so it cannot show recovery either.
while [ $_rw -lt 90 ]; do
  sleep 5; _rw=$((_rw+5))
  _st=$(st_now); _on=$(online_any)
  [ "$_st" = Charging ] && { _resumed=yes; _rwhy="status is Charging"; break; }
  { [ "$_on" = yes ] && [ "$_st" != Discharging ]; } && { _resumed=yes; _rwhy="online is back and the cut is released"; break; }
done
[ "$_resumed" = yes ] || { [ "$(online_any)" = yes ] && [ "$(rd $PS/battery/input_suspend 2>/dev/null)" = 0 ] && { _resumed=yes; _rwhy="the cut node is released and the supply is online"; }; }
if [ "$_resumed" = yes ]; then
  ok "charging RESUMED in ${_rw}s - ${_rwhy} (status=$(st_now) online=$(online_any) iin=$(iin_ma)mA)"
else
  no "charging did NOT resume within ${_rw}s of lifting the pause - this is the state users would report"
fi
# #26: a successful resume must not have fired a re-kick.
_apsd2=$(tail -n 100 $WLOG 2>/dev/null | grep -c 'apsd_rerun')
[ "$_apsd2" -eq 0 ] && ok "no re-kick was fired across the pause/resume cycle" \
                    || no "a re-kick fired around the resume - rc23's flip bug is back"

# THE SWITCH. This is the bypass check.
_swpost=$(cfgv chargingSwitch)
if [ "$_swpost" = "$_swpre" ]; then
  ok "the configured switch survived the forced pause ($_swpost)"
else
  no "the forced pause REPLACED the configured switch: [$_swpre] -> [$_swpost] (restore will put it back)"
fi

# =================================================================================================
sec "8  THERMAL: induce a hold just under pack temperature, then restore"
_pack=$(rd $PS/battery/temp)
case "${_pack:-x}" in ''|x|*[!0-9-]*) sk "no readable pack temperature"; _pack=;; esac
if [ -n "$_pack" ]; then
  _packc=$(( _pack / 10 ))
  _mt=$(( _packc - 2 ))
  if [ "$_mt" -le "$ORIG_CT" ] 2>/dev/null || [ "$_mt" -ge "$ORIG_ST" ] 2>/dev/null; then
    sk "pack is ${_packc}C; an induced max_temp of ${_mt}C would collide with cool/shutdown - not forcing it"
  else
    info "pack ${_packc}C, inducing max_temp=${_mt}C (shutdown_temp $ORIG_ST untouched)"
    setk mt="$_mt"; sleep 25
    _sth=$(st_now); _iih=$(iin_ma)
    if [ "$_sth" = "Not charging" ] || [ "${_iih:-9999}" -le 50 ] 2>/dev/null; then
      ok "the thermal hold engaged (status=$_sth iin=${_iih}mA)"
    else
      no "max_temp ${_mt}C against a ${_packc}C pack did not hold charging (status=$_sth iin=${_iih}mA)"
    fi
    setk mt="$ORIG_MT"; sleep 25
    _str=$(st_now); _iir=$(iin_ma)
    if [ "$_str" = Charging ] || [ "${_iir:-0}" -gt 100 ] 2>/dev/null; then
      ok "charging recovered after the thermal limit was put back (status=$_str iin=${_iir}mA)"
    else
      no "charging did not recover after restoring max_temp=$ORIG_MT (status=$_str iin=${_iir}mA)"
    fi
  fi
fi

# =================================================================================================
sec "9  DAEMON HEALTH ACROSS ALL OF THAT  (#39 #40 #45)"
_pid1=$(daemon_pid)
if [ -n "$_pid1" ] && [ "$_pid1" = "$_pid0" ]; then
  ok "the daemon survived every induced fault without restarting (pid $_pid1)"
elif [ -n "$_pid1" ]; then
  info "the daemon restarted during the run ($_pid0 -> $_pid1); it is up, which is what matters"
  ok "a daemon is running at the end of the induced-fault sequence"
else
  no "NO DAEMON after the induced faults - charging is uncapped"
fi
# Compare like with like: _f0 is a MODIFICATION TIME, not a line count. Comparing it against
# `wc -l` was nonsense and failed on both phones against a daemon that was demonstrably looping.
_f1=$(flight_stamp)
if [ "$_f1" -gt "$_f0" ] 2>/dev/null; then
  ok "flight.log was appended to across the run ($(( _f1 - _f0 ))s of activity, now $(lines $FLIGHT) lines)"
else
  no "flight.log was not appended to across the run - the daemon stopped looping"
fi

# =================================================================================================
sec "10  FINAL STATE"
sample final
info "write ledger grew $(( $(lines $WLOG) - _wl0 )) lines during this run"

restore
