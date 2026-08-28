#!/system/bin/sh
# rc24-weak-supply2.sh - the half of the contract policy that a good charger can never show you.
#
#   su -c 'sh /data/local/tmp/suites/rc24-weak-supply2.sh'      # START UNPLUGGED
#
# WHY THIS EXISTS
#   Every live plug tested so far was healthy and high-voltage, so every one of them ended with the
#   kick gate correctly answering HOLD. That proves ACC will not renegotiate a working charger. It
#   proves nothing whatever about the other direction: that ACC still DOES repair a supply that is
#   genuinely dead. That path has never fired on real hardware, and it is the one thing a release
#   verdict cannot honestly hand-wave.
#
#   It also never tested the negative latch case. A build that latched a contract on EVERY plug
#   would have passed every run so far, because every run had a contract to latch.
#
# WHAT TO PLUG IN
#   Either works, and the suite works out which it got:
#     DEAD      cable in the phone, other end in nothing (or a switched-off socket).
#               present=1, essentially no current, peak under 5.5V.
#     LIVE 5V   an ordinary slow charger. Current flows, but the bus never reaches 6.5V.
#   A high-voltage charger is also accepted and graded as the case already covered.
#
# WHAT IT ASSERTS, BY CLASS
#   DEAD     -> no latch, and the gate must say KICK. This is the repair path.
#   LIVE 5V  -> no latch (peak under the bar, no HV type), and the gate must say HOLD, because the
#               supply is delivering current and is therefore not dead.
#   HIGH-V   -> latched, and the gate must say HOLD.
#
# HOW IT AVOIDS STEALING THE REPAIR
#   Asking _hv_may_kick CLAIMS the plug's single repair by design - that is what makes the budget
#   structural rather than a convention. So this suite never drives the gate against the real
#   TMPDIR. It copies the live marker state into a scratch directory and drives it there, leaving
#   the daemon's own budget untouched, and separately WATCHES what the daemon actually did.

set +e
ID=rc24-weak-supply2
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
MF=$M/misc-functions.sh
WLOG=$DD/logs/write.log
FLIGHT=$DD/logs/flight.log
W=/data/local/tmp/rc24weak
PLUGWAIT=${PLUGWAIT:-900}

rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
lines(){ _n=$(wc -l < "$1" 2>/dev/null); case "${_n:-x}" in ''|*[!0-9]*) echo 0;; *) echo "$_n";; esac; }
daemon_pid(){ pgrep -f "$M/accd.sh" 2>/dev/null | head -1; }
flight_stamp(){ stat -c %Y "$FLIGHT" 2>/dev/null || echo 0; }
present_any(){ _p=no; for _n in $PS/*/present; do case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac; [ -f "$_n" ] || continue; [ "$(rd "$_n")" = 1 ] && _p=yes; done; echo $_p; }
online_any(){ _o=no; for _n in $PS/*/online; do case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac; [ -f "$_n" ] || continue; [ "$(rd "$_n")" = 1 ] && _o=yes; done; echo $_o; }
chg_type(){ for _t in real_type usb_type type; do [ -f "$PS/usb/$_t" ] || continue; rd "$PS/usb/$_t"; return 0; done; echo ""; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null
sed -n '/^_mv() {/,/^}/p;/^_ma() {/,/^}/p;/^_iin_ma() {/,/^}/p;/^_vbus_mv() {/,/^}/p;/^_hv_may_kick() {/,/^}/p' $MF > $W/u.sh
mv_of(){ ( . $W/u.sh 2>/dev/null; _mv "${1:-0}" 2>/dev/null ); }
iin_ma(){ ( cd $PS 2>/dev/null || exit 1; TMPDIR=$TD; . $W/u.sh 2>/dev/null; _iin_ma 2>/dev/null ); }

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)"
echo "build  : $(sed -n 's/^version=//p' $M/module.prop)  ($(sed -n 's/^versionCode=//p' $M/module.prop))"

sec "0  PREFLIGHT - must start unplugged"
[ "$(id -u)" = 0 ] || { no "not root"; exit 1; }
[ -s $W/u.sh ] && ok "extracted the shipped readers" || { no "could not extract the readers"; exit 1; }
if [ "$(present_any)" = yes ]; then
  echo "  ABORT: a cable is already attached. This suite grades the plug EDGE and the state of the"
  echo "         per-plug markers, both of which only exist from the moment the supply appears."
  exit 1
fi
ok "no cable attached"
_pid0=$(daemon_pid)
[ -n "$_pid0" ] || { no "no daemon running - start ACC first"; exit 1; }
ok "daemon running (pid $_pid0)"

# The markers must be clean before the plug, or nothing below means anything - but GIVE THE DAEMON
# TIME TO CLEAR THEM. The unplug cleanup runs inside the daemon loop, and an unplugged phone naps,
# so a check fired seconds after the cable came out sees markers the daemon has not reached yet.
# Measured on a Pixel 6a: .hvpeak still present immediately after unplug, gone once the loop ran.
# Failing there blames the build for the suite own impatience.
_mw=0; _dirty=
while [ $_mw -lt 180 ]; do
  _dirty=
  for _m in .hvcontract .hvpeak .hvkicked .hvzero .hvaim .hvfloor .hvlost; do
    [ -e "$TD/$_m" ] && _dirty="$_dirty $_m"
  done
  [ -z "$_dirty" ] && break
  sleep 10; _mw=$((_mw + 10))
done
if [ -z "$_dirty" ]; then
  ok "every per-plug marker is clear before the plug (waited ${_mw}s for the daemon loop)"
else
  no "markers still present after ${_mw}s unplugged:$_dirty - the unplug cleanup is not running"
fi
_wl0=$(lines $WLOG); _fs0=$(flight_stamp)

sec "1  WAITING FOR THE CABLE"
echo
echo "  >>> PLUG IN NOW.  Dead cable (other end in nothing) or a 5V slow charger. <<<"
echo
_pw=0
while [ $_pw -lt $PLUGWAIT ]; do [ "$(present_any)" = yes ] && break; sleep 1; _pw=$((_pw+1)); done
[ "$(present_any)" = yes ] || { no "no cable within ${PLUGWAIT}s"; exit 1; }
ok "cable detected after ${_pw}s"

# Sample through the transition. The daemon gets this whole window to act on its own.
PK=0; TYPESEEN=""; IINMAX=0
_i=0
while [ $_i -lt 45 ]; do
  _i=$((_i+1))
  _v=$(mv_of "$(rd $PS/usb/voltage_now)"); case "${_v:-x}" in ''|x|*[!0-9]*) _v=0;; esac
  [ "$_v" -gt "$PK" ] 2>/dev/null && PK=$_v
  _ii=$(iin_ma); case "${_ii:-x}" in ''|x|*[!0-9]*) _ii=0;; esac
  [ "$_ii" -gt "$IINMAX" ] 2>/dev/null && IINMAX=$_ii
  _t=$(chg_type); case "$_t" in *HVDCP*|*PD*|*QC*|*hvdcp*|*pd*) TYPESEEN=$_t;; esac
  case $_i in 1|5|10|20|30|45) echo "    ${_i}s  st=$(rd $PS/battery/status) usbV=${_v}mV iin=${_ii}mA type=$(chg_type) p=$(present_any) on=$(online_any)";; esac
  sleep 1
done

sec "2  WHAT KIND OF SUPPLY IS THIS"
info "peak bus this plug : ${PK}mV"
info "peak input current : ${IINMAX}mA"
info "high-voltage type  : ${TYPESEEN:-none}"
info "present=$(present_any) online=$(online_any) status=$(rd $PS/battery/status)"

CLASS=unknown
if [ "$PK" -ge 6500 ] 2>/dev/null || [ -n "$TYPESEEN" ]; then CLASS=highv
elif [ "$IINMAX" -le 50 ] 2>/dev/null; then CLASS=dead
else CLASS=live5v
fi
case $CLASS in
  dead)   ok "classified DEAD: present, peak ${PK}mV, never drew more than ${IINMAX}mA" ;;
  live5v) ok "classified LIVE 5V: peak ${PK}mV with ${IINMAX}mA drawn - a working low-voltage supply" ;;
  highv)  ok "classified HIGH VOLTAGE: peak ${PK}mV, type ${TYPESEEN:-none}" ;;
esac

sec "3  THE LATCH, GRADED FOR THIS CLASS"
_lat=$([ -f $TD/.hvcontract ] && echo present || echo absent)
_pkf=$(rd $TD/.hvpeak)
info ".hvcontract=$_lat  .hvpeak=${_pkf:-unset}  .hvkicked=$([ -f $TD/.hvkicked ] && echo present || echo absent)"
case $CLASS in
  highv)
    [ "$_lat" = present ] && ok "a high-voltage plug latched a contract" \
                          || no "a ${PK}mV / ${TYPESEEN} plug did NOT latch a contract" ;;
  dead|live5v)
    # THE NEGATIVE CASE. A build that latched on every plug would have passed every earlier run.
    [ "$_lat" = absent ] && ok "no contract latched on a ${PK}mV supply with no high-voltage type" \
                         || no "a ${PK}mV supply latched a contract - the 6.5V bar is not being applied" ;;
esac
if [ -n "$_pkf" ]; then
  if [ "$_pkf" -le "$(( PK + 200 ))" ] 2>/dev/null; then
    ok ".hvpeak recorded ${_pkf}mV, consistent with the ${PK}mV observed"
  else
    no ".hvpeak says ${_pkf}mV but the highest reading seen was ${PK}mV"
  fi
else
  sk ".hvpeak not written yet on this plug"
fi

sec "4  THE GATE'S DECISION  (driven on a COPY, so the real budget is untouched)"
# _hv_may_kick claims the repair when it says yes. Driving it against the live TMPDIR would spend
# the daemon's own budget and change the thing being measured, so the marker state is copied first.
rm -rf $W/box 2>/dev/null; mkdir -p $W/box 2>/dev/null
for _m in .hvcontract .hvpeak .hvkicked; do [ -e "$TD/$_m" ] && cp -a "$TD/$_m" "$W/box/" 2>/dev/null; done
mkdir -p $W/box/data 2>/dev/null
[ -f "$DD/.rekick-off" ] && cp -a "$DD/.rekick-off" "$W/box/data/" 2>/dev/null
_g=$( cd $PS 2>/dev/null && TMPDIR=$W/box dataDir=$W/box/data /system/bin/sh -c ". $W/u.sh; present(){ return 0; }; _hv_may_kick && echo KICK || echo HOLD" 2>/dev/null )
info "gate says: ${_g:-<no answer>}"
case $CLASS in
  dead)
    if [ "$_g" = KICK ]; then
      ok "THE REPAIR PATH: the gate PERMITS a re-detection on a supply that is present and delivering nothing"
    else
      no "the gate said $_g on a dead supply - a phone that will not charge would never be repaired"
    fi ;;
  live5v)
    if [ "$_g" = HOLD ]; then
      ok "a live 5V supply drawing ${IINMAX}mA is not 'dead', so the gate refuses to re-detect it"
    else
      no "the gate said $_g on a supply drawing ${IINMAX}mA - it would renegotiate a working charger"
    fi ;;
  highv)
    [ "$_g" = HOLD ] && ok "a latched high-voltage plug is refused, as everywhere else" \
                     || no "the gate said $_g on a latched high-voltage plug" ;;
esac
# Whatever it answered, asking on the copy must not have touched the real markers.
[ -f $TD/.hvkicked ] && info "the DAEMON has claimed a repair this plug (.hvkicked present)" \
                     || info "the real .hvkicked is still absent - this suite did not spend the budget"

sec "5  WHAT THE DAEMON ACTUALLY DID"
_wl1=$(lines $WLOG)
_new=$(( _wl1 - _wl0 ))
_apsd=0; [ "$_new" -gt 0 ] && _apsd=$(tail -n $_new $WLOG | grep -c 'apsd_rerun')
info "write ledger grew $_new node(s); apsd_rerun among them: $_apsd"
[ "$(flight_stamp)" -gt "$_fs0" ] 2>/dev/null && ok "the daemon kept looping across the plug" \
                                              || no "flight.log was not appended to - the daemon stopped looping"
case $CLASS in
  dead)
    # One repair per plug, and never more. Either the daemon took it or it has not needed to yet;
    # what must never happen is more than one.
    if [ "$_apsd" -le 1 ]; then
      ok "at most one apsd_rerun on this plug ($_apsd) - the once-per-plug budget holds"
    else
      no "$_apsd apsd_rerun entries on one plug - the repair budget is not being enforced"
    fi ;;
  live5v|highv)
    [ "$_apsd" -eq 0 ] && ok "no apsd_rerun fired against a working supply" \
                       || no "$_apsd apsd_rerun fired against a working supply" ;;
esac
_usbw=0; [ "$_new" -gt 0 ] && _usbw=$(tail -n $_new $WLOG | grep -c 'usb/current_max')
[ "$_usbw" -eq 0 ] && ok "nothing was written to usb/current_max on this plug" \
                   || no "usb/current_max was newly written $_usbw time(s) - the 100mA footgun"
_im=$(rd $PS/usb/current_max)
case "${_im:-x}" in
  ''|x) : ;;
  *) if [ "$_im" -le 150000 ] 2>/dev/null && [ "$_im" -gt 0 ] 2>/dev/null; then
       no "usb/current_max has collapsed to $_im"
     else ok "usb/current_max is $_im, not collapsed"; fi ;;
esac

sec "6  ONCE PER PLUG"
# Ask the copy a second time. Having said yes once it must now say no, whatever the class.
_g2=$( cd $PS 2>/dev/null && TMPDIR=$W/box dataDir=$W/box/data /system/bin/sh -c ". $W/u.sh; present(){ return 0; }; _hv_may_kick && echo KICK || echo HOLD" 2>/dev/null )
if [ "$_g" = KICK ]; then
  [ "$_g2" = HOLD ] && ok "having permitted one repair, the gate refuses the next ask - the budget is structural" \
                    || no "the gate permitted a second repair on the same plug ($_g2)"
else
  [ "$_g2" = HOLD ] && ok "still HOLD on a second ask" || no "the gate changed its mind to $_g2"
fi

sec "7  FINAL STATE"
info "st=$(rd $PS/battery/status) cap=$(rd $PS/battery/capacity)% usbV=$(mv_of "$(rd $PS/usb/voltage_now)")mV iin=$(iin_ma)mA"
info "markers: .hvcontract=$([ -f $TD/.hvcontract ] && echo y || echo n) .hvpeak=$(rd $TD/.hvpeak) .hvkicked=$([ -f $TD/.hvkicked ] && echo y || echo n)"
info "daemon: $(daemon_pid || echo DOWN)"
echo
echo "$ID: $P passed, $F failed, $S skipped"
[ "$F" -eq 0 ] && exit 0 || exit 1
