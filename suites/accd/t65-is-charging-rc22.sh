#!/system/bin/sh
# t65 - is_charging: the three rc22 changes, EXECUTED.
#
# WHY THIS FILE EXISTS
#   The mega2 coverage gate reported is_charging as covered. It was not. The gate counted a function
#   as covered when any suite NAMED it, and once comments were stripped from that search is_charging
#   turned out to have nothing pointed at it at all. A separate audit of the rc21->rc22 diff put it
#   on the high-risk uncovered list.
#
#   Every assertion here RUNS the function out of the installed build and observes what it does.
#   Grepping the source would pass on an inverted comparison; this does not.
#
# SAFETY
#   disable_charging, enable_charging and shutdown are STUBBED in every driver. The real shutdown at
#   accd.sh powers the phone off. Nothing in this file writes to a sysfs node, touches the real
#   config, or signals the running daemon.

ID=t65
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
AWKF=$execDir/suites/xf.awk
[ -f "$AD" ] || { no "accd.sh not found"; fin; }
[ -f "$AWKF" ] || { no "xf.awk (the function extractor) not found at $AWKF"; fin; }

W=${TMPDIR:-/data/local/tmp}/t65-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null

xf(){ awk -v fn="$1" -f "$AWKF" "$AD"; }
[ -n "$(xf is_charging)" ] || { no "could not extract is_charging from accd.sh"; rm -rf "$W"; fin; }

# ---- 1: the discovery sweep only cuts near the limit ---------------------------------------------------
# rc21 cut a live charge to hunt for a charging switch on ANY plug at ANY level. rc22 gates that on
# probe_due, so it happens only within 5 points of the pause level. The real probe_due is used, so
# this also exercises its arithmetic and its fail-open behaviour rather than a stub's idea of them.
_r=
for _c in 40 74 75 90; do
  D=$W/d1; rm -rf $D; mkdir -p $D; echo $_c > $D/level; : > $D/.mcc-read
  ( TMPDIR=$D; dataDir=$D; execDir=$D
    eval "$(xf is_charging)"
    _pd=$(xf probe_due); if [ -n "$_pd" ]; then eval "$_pd"; else probe_due(){ return 0; }; fi
    set_dp(){ :; }; not_charging(){ return 1; }; batt_cap(){ cat $D/level; }
    disable_charging(){ : > $D/cut; exit 0; }; enable_charging(){ :; }
    shutdown(){ : > $D/SHUTDOWN; exit 9; }; temp_now(){ echo 300; }
    apply_on_plug(){ exit 0; }; set_ch_curr(){ :; }; set_ch_volt(){ :; }; set_temp_level(){ :; }
    chDisabledByAcc=false; chargingSwitch=(); currentWorkaround0=false; currentWorkaround=false
    cooldown=true; restrictCurr=false; rebootResume=false
    unset cooldownCurrent maxChargingCurrent maxChargingVoltage
    capacity=(5 101 70 80)
    is_charging ) >/dev/null 2>&1 || :
  if [ -f $D/cut ]; then _r="${_r}${_c}=cut "; else _r="${_r}${_c}=no-cut "; fi
  [ -f $D/SHUTDOWN ] && no "level ${_c}: the driver reached a real shutdown call - STUB BROKEN, stop"
done
case "$_r" in
  "40=no-cut 74=no-cut 75=cut 90=cut ")
    ok "discovery cuts only within 5 points of the limit (40,74 spared; 75,90 probed)" ;;
  "40=cut 74=cut 75=cut 90=cut ")
    no "discovery cuts a healthy charge at EVERY level - the probe_due gate is gone (rc21 behaviour)" ;;
  "40=no-cut 74=no-cut 75=no-cut 90=no-cut ")
    no "discovery never runs at all - the gate fails CLOSED and a switch would never be found" ;;
  *) no "unexpected discovery pattern: $_r" ;;
esac

# ---- 2: the daemon's release identifies itself ----------------------------------------------------------
# _accdRelease=true is the ONLY thing that arms set_ch_curr's two back-off guards. Without it the
# daemon's release looks exactly like the user clearing the cap, and it removes the marker mid-apply.
D=$W/d2b; rm -rf $D; mkdir -p $D; : > $D/.mcc-read
( TMPDIR=$D; dataDir=$D; execDir=$D
  eval "$(xf is_charging)"
  set_dp(){ :; }; not_charging(){ return 1; }; probe_due(){ return 1; }
  disable_charging(){ :; }; enable_charging(){ :; }
  shutdown(){ : > $D/SHUTDOWN; exit 9; }; temp_now(){ echo 300; }
  set_ch_curr(){ echo "call:$1:accdRelease=${_accdRelease:-unset}" >> $D/calls; }
  apply_on_plug(){ exit 0; }; set_ch_volt(){ :; }; set_temp_level(){ :; }; batt_cap(){ echo 50; }
  chDisabledByAcc=false; chargingSwitch=(/sys/x 0 1)
  currentWorkaround0=false; currentWorkaround=false
  cooldown=true; restrictCurr=false; rebootResume=false
  unset cooldownCurrent maxChargingCurrent maxChargingVoltage
  capacity=(5 101 70 80)
  is_charging ) >/dev/null 2>&1 || :
if [ -f $D/calls ]; then
  if grep -q 'accdRelease=true' $D/calls; then
    ok "the daemon's own release is tagged _accdRelease=true, so set_ch_curr can tell it from a user clear"
  else
    no "the daemon released the current cap WITHOUT _accdRelease - both back-off guards are disarmed (rc21 behaviour): $(cat $D/calls)"
  fi
else
  no "set_ch_curr was never called - the release path was not reached, so this assertion proves nothing"
fi

# ---- 3: the daemon stands down while a CLI set is settling ----------------------------------------------
# Same path, but with the settling marker up. rc22 does not call set_ch_curr at all; rc21 called it
# and raced the user's own `acc -s`.
D=$W/d2a; rm -rf $D; mkdir -p $D; : > $D/.mcc-read; : > $D/.mcc-settling
( TMPDIR=$D; dataDir=$D; execDir=$D
  eval "$(xf is_charging)"
  set_dp(){ :; }; not_charging(){ return 1; }; probe_due(){ return 1; }
  disable_charging(){ :; }; enable_charging(){ :; }
  shutdown(){ : > $D/SHUTDOWN; exit 9; }; temp_now(){ echo 300; }
  set_ch_curr(){ echo "call:$1:accdRelease=${_accdRelease:-unset}" >> $D/calls; }
  apply_on_plug(){ exit 0; }; set_ch_volt(){ :; }; set_temp_level(){ :; }; batt_cap(){ echo 50; }
  chDisabledByAcc=false; chargingSwitch=(/sys/x 0 1)
  currentWorkaround0=false; currentWorkaround=false
  cooldown=true; restrictCurr=false; rebootResume=false
  unset cooldownCurrent maxChargingCurrent maxChargingVoltage
  capacity=(5 101 70 80)
  is_charging ) >/dev/null 2>&1 || :
[ -f $D/calls ] \
  && no "the daemon released the cap while a CLI set was settling - it is racing the user's own acc -s (rc21 behaviour): $(cat $D/calls)" \
  || ok "the daemon skips its release entirely while .mcc-settling is present"

rm -rf "$W" 2>/dev/null
fin
