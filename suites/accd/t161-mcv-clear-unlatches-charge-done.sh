#!/system/bin/sh
# t161 - clearing a voltage limit must not leave a Qualcomm charger latched in charge_done.
# Mi A3: mcv=3950 below the pack -> charge_done=1, 0 A. mcv= restored the float voltage but the
# charger stayed at 0 A with status Charging until a replug. One switch toggle restarts it.
ID=t161; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }; no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; exit $?; }
execDir=${execDir:-/data/adb/vr25/acc}
SV=$execDir/set-ch-volt.sh; [ -f "$SV" ] || { no "missing $SV"; fin; }
W=${TMPDIR:-/data/local/tmp}/t161-$$; rm -rf "$W"; mkdir -p "$W/b"
# the toggle leaves input_suspend at 0; detect it ran by trapping writes through a log
trial(){ ( . "$SV"; eval "$(sed -n '/^_mcv_unlatch() {/,/^}/p' "$SV" | sed "s#/sys/class/power_supply/battery#$W/b#g")"
    echo "$1" > $W/b/charge_done; echo "$2" > $W/b/status; : > $W/b/input_suspend
    eval "at_or_above_pause(){ return $3; }"; sleep(){ echo toggled >> $W/log; }; chargingSwitch=()
    rm -f $W/log; _mcv_unlatch; [ -f $W/log ] && echo kicked || echo idle ) 2>/dev/null; }
[ "$(trial 1 Charging 1)" = kicked ] && ok "latched below the limit -> charger re-armed" || no "latched charger left at 0 A"
[ "$(trial 0 Charging 1)" = idle ] && ok "not latched -> no toggle" || no "toggled a charger that was fine"
[ "$(trial 1 Full 1)" = idle ] && ok "genuinely full -> no toggle" || no "toggled a full battery"
[ "$(trial 1 Charging 0)" = idle ] && ok "at/above the pause limit -> no toggle" || no "re-armed charging above the limit"
grep -q '_mcv_unlatch$' "$SV" && ok "release path calls it" || no "release path does not call _mcv_unlatch"
rm -rf "$W"; fin
