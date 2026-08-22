#!/system/bin/sh
# t117 - the diagnostic verdict must not call a working firmware limit a broken switch.
#
# THE FIELD REPORT (bramble, Pixel 4a 5G, ACC rc23 + AccA 2.0.1-rc22)
#   A bundle that contradicted itself. Its verdict header said:
#
#       (!) pause=40% below level 41% but .../charge_stop_level=40 (off=pcap)
#           -> switch is NOT holding charge (switch may be broken)
#       (!) status=Charging at 41% ABOVE pause 40% -> overcharging now (daemon not holding)
#
#   while its own detail section, 130 lines further down, said:
#
#       == what is holding the limit ==
#         NATIVE firmware limit is ACTIVE   charge_stop_level = 40
#
#   Both cannot be true. The firmware limit was set correctly and holding.
#
# THE TWO FAULTS
#   1. The verdict judged the hold from the CONFIGURED chargingSwitch. On a phone with a native
#      firmware limit the daemon drives charge_stop_level and never writes that switch at all, so
#      the switch is the wrong thing to look at.
#   2. The OFF value in a level switch is the KEYWORD "pcap" - meaning "the pause level" - not a
#      number. The comparison was the node's "40" against the literal string "pcap", which can
#      never be true, so a level switch that was holding perfectly always read as broken.
#
#   The same owner had already lost a report to this once; accd.sh carries a note about a Pixel 4a
#   5G owner hunting a switch that had never been in use.
#
# HOW THIS IS GRADED
#   Both arms. rc23's collector must say BROKEN on bramble's numbers and the current one must say
#   HELD, or the case proves nothing. The verdict logic is cut out of each collector and driven
#   with a fabricated tree, so no phone needs to have a firmware limit for this to run.

ID=t117
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t117}
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

for a in "$ARM23" "$ARM24"; do
  [ -f "$a/diag-collect.sh" ] || { no "no diag-collect.sh in $a"; fin; }
done
ok "both collector arms present"

# Cut the resolution block out of a collector: from the switch-path resolution down to the line
# that decides _susp. That is the whole decision.
cut_block(){ sed -n '/^      case "\$_V_swn" in \/\*)/,/_susp=1; else _susp=0; fi/p' "$1/diag-collect.sh"; }

# Drive it. Prints HELD or BROKEN.
#   run <arm> <native?> <pause> <resume> <switch line> <stop_level value>
run(){
  _arm=$1; _nat=$2; _pause=$3; _resume=$4; _swl=$5; _stop=$6
  _b=$W/blk.sh; cut_block "$_arm" > $_b
  [ -s $_b ] || { echo NOBLOCK; return; }
  rm -rf $W/w 2>/dev/null; mkdir -p $W/w/native $W/w/ps/battery $W/w/data 2>/dev/null
  [ "$_nat" = yes ] && { printf '%s\n' "$_stop" > $W/w/native/charge_stop_level; printf '%s\n' "$_resume" > $W/w/native/charge_start_level; }
  # The configured switch node itself, so the non-native arm has something to read.
  printf '%s\n' "$_stop" > $W/w/ps/battery/level_node
  {
    echo "DD=$W/w/data"
    echo "_V_pause=$_pause; _V_resume=$_resume; _V_batt=41"
    echo "_V_swl='$_swl'"
    echo '_V_swn=$(echo "$_V_swl" | awk "{print \$1}"); _V_swoff=$(echo "$_V_swl" | awk "{print \$3}")'
    echo "NATIVE_DIRS=$W/w/native"
    cat $_b
    echo 'if [ "${_susp:-0}" = 1 ]; then echo HELD; else echo BROKEN; fi'
  } > $W/run.sh
  /system/bin/sh $W/run.sh 2>/dev/null | tail -1
}

echo
echo "-- 1  bramble's exact situation: native limit, stop=40, pause=40, level 41%"
SW="$W/w/ps/battery/level_node 100 pcap"
_r23=$(run "$ARM23" yes 40 37 "$SW" 40)
_r24=$(run "$ARM24" yes 40 37 "$SW" 40)
echo "     rc23 says: $_r23     current says: $_r24"
case "$_r23/$_r24" in
  BROKEN/HELD) ok "the firmware limit is now read as HOLDING, where rc23 called the switch broken" ;;
  HELD/HELD)   no "rc23 already said HELD - this case cannot see the defect, so it proves nothing" ;;
  */BROKEN)    no "the current collector still reports a working firmware limit as broken" ;;
  *)           no "no verdict: rc23='$_r23' current='$_r24'" ;;
esac

echo
echo "-- 2  the keyword, on a phone with NO firmware limit"
# A level switch whose OFF value is the word pcap, sitting at the pause level, is holding.
_k23=$(run "$ARM23" no 40 37 "$SW" 40)
_k24=$(run "$ARM24" no 40 37 "$SW" 40)
echo "     rc23 says: $_k23     current says: $_k24"
case "$_k23/$_k24" in
  BROKEN/HELD) ok "an OFF value of 'pcap' resolves to the pause level instead of being compared as text" ;;
  HELD/HELD)   no "rc23 already resolved the keyword - this case proves nothing" ;;
  */BROKEN)    no "the keyword is still compared literally against the node value" ;;
  *)           no "no verdict: rc23='$_k23' current='$_k24'" ;;
esac

echo
echo "-- 3  the directions that must NOT change"
# A firmware limit set somewhere other than the pause is genuinely not holding the configured limit.
_m=$(run "$ARM24" yes 40 37 "$SW" 95)
[ "$_m" = BROKEN ] && ok "a firmware stop level of 95 against a pause of 40 is still reported as not holding" \
                   || no "a stop level of 95 with pause 40 was reported as $_m"
# A plain numeric OFF value must still work exactly as before.
_n=$(run "$ARM24" no 40 37 "$W/w/ps/battery/level_node 0 40" 40)
[ "$_n" = HELD ] && ok "a plain numeric OFF value still reads as holding" \
                 || no "a numeric OFF value now reads as $_n"
_n2=$(run "$ARM24" no 40 37 "$W/w/ps/battery/level_node 0 99" 40)
[ "$_n2" = BROKEN ] && ok "a numeric OFF value that does not match is still reported as not holding" \
                    || no "a mismatched numeric OFF value read as $_n2"

echo
echo "-- 4  can this case still fail?"
# Put the keyword comparison back on a copy and confirm case 2 catches it.
mkdir -p $W/mut 2>/dev/null
sed 's/          pcap) _susp_want="\$_V_pause" ;;/          pcap) : ;;/' "$ARM24/diag-collect.sh" > $W/mut/diag-collect.sh
if cmp -s "$ARM24/diag-collect.sh" $W/mut/diag-collect.sh; then
  sk "could not mutate the keyword resolution"
else
  _mm=$(run "$W/mut" no 40 37 "$SW" 40)
  [ "$_mm" = BROKEN ] && ok "mutation caught: without keyword resolution the switch reads broken again" \
                      || no "mutation NOT caught: case 2 cannot fail"
fi

fin
