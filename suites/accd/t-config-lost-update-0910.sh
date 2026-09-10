#!/system/bin/sh
# A writer that owns one key must not republish its snapshot of all the others.
#
# The daemon loads the config once a pass and can persist a single key minutes later: its own
# switch, or the expansion of a current or voltage cap. Every other key is serialised out of its
# memory as it stood at load time, so a setting the user saved in between is reverted with no
# error and nothing logged.
#
# Nothing here touches the live config, a sysfs node or the daemon.

ID=t-config-lost-update-0910
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
WC=$execDir/write-config.sh
DC=$execDir/default-config.txt
[ -f "$WC" ] || { no "missing $WC"; fin; }
[ -f "$DC" ] || { no "missing $DC"; fin; }

W=${TMPDIR_T:-/data/local/tmp}/t-lost-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null

# One writer, in its own process, exactly the way the daemon sources it.
#   write <owner-arg-or-empty> <assignments...>
write(){
  _own=$1; shift
  ( set +e
    execDir=$execDir
    TMPDIR=$W/tmp; dataDir=$W/data; config=$dataDir/config.txt
    mkdir -p "$TMPDIR" "$dataDir" 2>/dev/null
    . "$DC" 2>/dev/null || :
    if [ -f "$config" ]; then
      grep -Ev '^[[:space:]]*:' "$config" > $W/live.$$ 2>/dev/null || :
      . $W/live.$$ 2>/dev/null || :
      rm -f $W/live.$$ 2>/dev/null || :
    fi
    isAccd=true
    eval "$*"
    if [ -n "$_own" ]; then . "$WC" "$_own"; else . "$WC"; fi ) >/dev/null 2>&1
}
CFG=$W/data/config.txt
tempOf(){ sed -n 's/^temperature=//p' "$CFG"; }
swOf(){ sed -n 's/^chargingSwitch=//p' "$CFG"; }
mccOf(){ sed -n 's/^maxChargingCurrent=//p' "$CFG"; }

echo "--- 1. a daemon persisting its own switch keeps the band the user saved after it loaded"
rm -rf $W; mkdir -p $W/data
write '' 'temperature=(29 34 24 55)'
write '' 'ct=40; mt=45; rt=20'
_b=$(tempOf)
[ ".$_b" = ".(40 45 20 55)" ] && ok "the user's write landed: $_b" || no "the user's write did not land: $_b"
# The daemon still holds the band it read before that write, and now saves its switch.
write 'own:s' 'temperature=(29 34 24 55); chargingSwitch=(battery/input_suspend 0 1)'
_a=$(tempOf)
[ ".$_a" = ".(40 45 20 55)" ] && ok "the band survived the daemon's switch save: $_a" \
  || no "the daemon reverted the band to its own snapshot: $_a"

echo "    ...and the key that writer does own is still published"
_sw=$(swOf)
case "$_sw" in
  *battery/input_suspend*) ok "the switch the daemon selected was saved: $_sw" ;;
  *) no "the owned key was lost: $_sw" ;;
esac

echo "--- 2. the same holds for a current cap the daemon expands"
rm -rf $W; mkdir -p $W/data
write '' 'temperature=(29 34 24 55)'
write '' 'ct=41; mt=46; rt=21; mcc=900'
_b=$(tempOf)
[ ".$_b" = ".(41 46 21 55)" ] && ok "the user's second write landed: $_b" || no "the user's second write did not land: $_b"
write 'own:mcc' 'temperature=(29 34 24 55); maxChargingCurrent=(900)'
_a=$(tempOf); _m=$(mccOf)
[ ".$_a" = ".(41 46 21 55)" ] && ok "the band survived the daemon's current save: $_a" \
  || no "the daemon reverted the band: $_a"
case "$_m" in
  *900*) ok "the current cap the daemon owns was saved: $_m" ;;
  *) no "the owned current cap was lost: $_m" ;;
esac

echo "--- 3. a write that names no owner still carries the whole config, unchanged"
rm -rf $W; mkdir -p $W/data
write '' 'temperature=(29 34 24 55)'
write '' 'pc=66; rc=61'
_c=$(sed -n 's/^capacity=//p' "$CFG"); _t=$(tempOf)
case "$_c" in
  *' 61 66 '*) ok "an ordinary user write publishes its own values: $_c" ;;
  *) no "an ordinary user write did not land: $_c" ;;
esac
[ ".$_t" = ".(29 34 24 55)" ] && ok "and leaves the keys it did not name alone: $_t" \
  || no "an ordinary write disturbed an unrelated key: $_t"

echo "--- 4. a user script line is never executed by the merge"
rm -rf $W; mkdir -p $W/data
write '' 'temperature=(29 34 24 55)'
printf ': ran; touch %s/RAN\n' "$W" >> "$CFG"
write 'own:s' 'temperature=(29 34 24 55); chargingSwitch=(battery/input_suspend 0 1)'
[ -f "$W/RAN" ] && no "the merge sourced a ':' user script and ran it" \
  || ok "the merge skips ':' lines, so a user script is not run by a config save"

rm -rf "$W" 2>/dev/null
fin
