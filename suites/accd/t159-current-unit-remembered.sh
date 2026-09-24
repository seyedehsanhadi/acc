#!/system/bin/sh
# t159 - a proven microamp unit survives a reboot; a small idle reading never contradicts it.
#
# Field bundles (Pixel 4a bramble, rc25-test24) carried the warning "config has ampFactor=1000000
# but this phone's sensors read 1000" on a microamp phone: current_factor() answers 1000 whenever
# every node is under 16000, which an idling microamp phone also does. The warning told the user to
# clear a correct setting. And a microamp phone rebooted while holding in bypass (battery -2000,
# input 450000) had no unit at all. A reading >= 16000 on the battery node is conclusive - no
# milliamp gauge reports 16 A - so it is recorded per node in dataDir and reused.
ID=t159
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; exit $?; }

execDir=${execDir:-/data/adb/vr25/acc}
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AD=${AD:-$execDir/accd.sh}; BI=${BI:-$execDir/batt-interface.sh}; SE=${SE:-$execDir/state-export.sh}
AWKF=${AWKF:-$SELF/../xf.awk}; [ -f "$AWKF" ] || AWKF=$execDir/suites/xf.awk
for f in "$AD" "$BI" "$SE" "$AWKF"; do [ -f "$f" ] || { no "missing $f"; fin; }; done
W=${TMPDIR:-/data/local/tmp}/t159-$$; rm -rf "$W"; mkdir -p "$W/psy/battery" "$W/psy/usb" "$W/data"

cf(){ # $1 battery raw, $2 usb input raw, $3 bi source (optional)
  ( xf(){ awk -v fn="$1" -f "$AWKF" "$2"; }
    eval "$(xf _se_rd "$SE")"; eval "$(xf _se_int "$SE")"
    eval "$(xf current_now "$BI")"; eval "${3:-$(xf current_factor "$BI")}"
    ACC_PSY=$W/psy; currFile=$W/psy/battery/current_now; ampFactor=; dataDir=$W/data
    echo "$1" > $currFile; echo "$2" > $W/psy/usb/input_current_now
    echo "[$(current_factor)]" )
}
rm -f $W/data/.current-unit
[ "$(cf -2000 450000)" = "[]" ] && ok "no history: bypass reading is unknown" || no "no history: expected unknown"
[ "$(cf -350000 0)" = "[1000000]" ] && ok "a 350 mA microamp reading proves uA" || no "uA not detected"
[ -s $W/data/.current-unit ] && ok "proof recorded in dataDir" || no "proof not recorded"
[ "$(cf -2000 450000)" = "[1000000]" ] && ok "after reboot, bypass reading reuses the proven unit" || no "proven unit not reused"
[ "$(cf -300 0)" = "[1000000]" ] && ok "an idle small reading no longer flips a proven uA phone to mA" || no "idle reading overrode proof"
echo "/other/node 1000000" > $W/data/.current-unit
[ "$(cf -2000 450000)" = "[]" ] && ok "proof for a different node is not borrowed" || no "proof leaked across nodes"

MUT=$(awk -v fn=current_factor -f "$AWKF" "$BI" | grep -v -e current-unit -e '"$u" = ')
rm -f $W/data/.current-unit; cf -350000 0 "$MUT" >/dev/null 2>&1
[ "$(cf -2000 450000 "$MUT")" = "[]" ] && ok "mutant without memory stays unknown - assertion can fail" || no "mutant not caught"

_ad=$(sed 's/^[[:space:]]*#.*//' < "$AD" | tr '\n' ' ')
case "$_ad" in
  *'[ "$f" = 1000000 ] && [ "$ampFactor" = 1000 ] || return 0'*) ok "ampFactor warning fires only on a proven contradiction";;
  *) no "ampFactor warning can fire on an unproven idle reading";;
esac
rm -rf "$W"
fin
