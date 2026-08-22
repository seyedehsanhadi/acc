#!/system/bin/sh
# t121 - the firmware-limit branch must not silently swallow the charging limits.
#
# THE HOLE
#   accd.sh: `if $nativeLimit; then ... continue` exits the loop BEFORE is_charging() is called.
#   maxChargingCurrent and maxChargingVoltage live inside is_charging(), so on every phone with a
#   firmware charge limit they were accepted, stored, displayed, and enforced by nothing.
#
#   This is the fifth and sixth feature lost to that one `continue`. The file already records four:
#     rc21  allowIdleAbovePcap   Pixel 3a, "accepted, written to config, echoed back, ignored"
#     rc22c idleApps             "did nothing whatsoever on a phone with a native limit"
#     rc23c auto_shutdown        the branch "has never reached" it
#           mask_capacity        Pixel 9a, "did nothing at all, silently"
#
# EVIDENCE
#   Pixel 6a (bluejay, Tensor)   nativeLimit=TRUE   mcc 500 -> pack stays 1.9A, no node written
#   Pixel 4a 5G (bramble, 7250)  nativeLimit=TRUE   mcc=(925) never expanded; ledger: 22 voltage
#                                                   writes, 0 current writes
#   Mi A3 (laurus, SM6125)       nativeLimit=false  mcc 500 -> 1994mA to 433mA, back to 2891mA
#   200s of live daemon trace on the Pixel while charging at +3.06A: `is_charging` appears 0 times,
#   and there is no `set +x` in that region, so it genuinely never ran.
#
# HOW THIS IS GRADED
#   The branch is read out of each arm and checked for the calls. Source-level, because the branch
#   is only taken on a phone that HAS a firmware limit -- the Mi A3 can never execute it, and the
#   Pixel can only execute it while plugged. The live proof belongs to the plugged run; this pins
#   the structure and, critically, that the Mi A3's path is untouched.

ID=t121
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t121}
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

for a in "$ARM23" "$ARM24"; do
  [ -f "$a/accd.sh" ] || { no "no accd.sh in $a"; fin; }
done
ok "both arms present"

# Cut the native branch out of an arm: from `if $nativeLimit; then` to the line that hands a
# firmware-limit phone away from the generic switch logic.
cut_native(){
  awk '/^ *if \$nativeLimit; then/{f=1} f{print} f && /DO NOT hand a firmware-limit phone/{exit}' "$1/accd.sh"
}

for a in "$ARM23" "$ARM24"; do
  cut_native "$a" > $W/$(basename $a).branch
done
_l23=$(wc -l < $W/rc23tree.branch); _l24=$(wc -l < $W/rc24tree.branch)
[ "$_l23" -gt 20 ] && [ "$_l24" -gt 20 ] && ok "extracted the branch from both arms ($_l23 / $_l24 lines)" \
  || { no "could not extract the branch ($_l23 / $_l24)"; fin; }

echo
echo "-- 1  the current limit must be applied on the firmware-limit path"
_a=$(grep -c 'set_ch_curr ${maxChargingCurrent' $W/rc23tree.branch); _b=$(grep -c 'set_ch_curr ${maxChargingCurrent' $W/rc24tree.branch)
echo "     rc23 has $_a   current has $_b"
if [ "$_a" -eq 0 ] && [ "$_b" -ge 1 ]; then
  ok "set_ch_curr now runs on the firmware-limit path, where rc23 never called it"
elif [ "$_a" -ge 1 ]; then
  no "rc23 already calls it - this case cannot see the defect"
else
  no "set_ch_curr is still absent from the branch"
fi

echo
echo "-- 2  the control files must be DISCOVERED there too, or there is nothing to apply"
_a=$(grep -c 'read-ch-curr-ctrl-files-p2' $W/rc23tree.branch); _b=$(grep -c 'read-ch-curr-ctrl-files-p2' $W/rc24tree.branch)
echo "     rc23 has $_a   current has $_b"
[ "$_a" -eq 0 ] && [ "$_b" -ge 1 ] && ok "the discovery script is reachable from the branch" \
  || no "discovery still unreachable (rc23=$_a now=$_b)"

echo
echo "-- 3  the voltage limit likewise"
_a=$(grep -c 'set_ch_volt ${maxChargingVoltage' $W/rc23tree.branch); _b=$(grep -c 'set_ch_volt ${maxChargingVoltage' $W/rc24tree.branch)
[ "$_a" -eq 0 ] && [ "$_b" -ge 1 ] && ok "set_ch_volt now runs on the firmware-limit path" \
  || no "set_ch_volt absent (rc23=$_a now=$_b)"

echo
echo "-- 4  discovery must be gated on a live charging supply"
# Off-charge most control nodes read 0; recording that as a node's DEFAULT would cap the phone there.
if grep -q 'battStatus' $W/rc24tree.branch && grep -q 'present' $W/rc24tree.branch; then
  ok "the new block is gated on present() and a Charging status"
else
  no "the new block is not gated on a live charging supply"
fi

echo
echo "-- 5  cool-down must be declared, not silently dropped"
grep -q 'nativecooldown' $W/rc24tree.branch \
  && ok "cool-down cycling is reported as unavailable instead of pretending" \
  || no "cool-down is still silently dropped on this path"

echo
echo "-- 4b  a cap must be RELEASABLE, not just applicable"
# An apply without a release leaves the phone capped with a UI that says no limit. Measured on a
# Pixel 6a before this: clearing the cap left usb/current_max pinned at 500000 and the config
# holding a malformed maxChargingCurrent=( node::... ) with the scalar gone.
_rc=$(grep -c 'set_ch_curr -' $W/rc24tree.branch)
_rv=$(grep -c 'set_ch_volt -' $W/rc24tree.branch)
echo "     release calls in the branch: current=$_rc voltage=$_rv"
[ "$_rc" -ge 1 ] && [ "$_rv" -ge 1 ] && ok "the branch releases both limits when the config no longer holds one"                                      || no "release missing (current=$_rc voltage=$_rv) - a cap could never be cleared here"
# and it must NOT be trapped behind the charging gate
if awk '/if present 2>\/dev\/null && \[ "\$\(cat \$battStatus/{g=1} g&&/^        fi$/{g=0} {if(!g && /set_ch_curr -/) print "outside"}' $W/rc24tree.branch | grep -q outside; then
  ok "the release runs regardless of charging state"
else
  no "the release is trapped inside the charging gate - an unplugged phone could never clear a cap"
fi

echo
echo "-- 5b  force-off must be declared too"
grep -q 'nativeforceoff' $W/rc24tree.branch   && ok "force-off is reported as unavailable instead of pretending"   || no "force-off is still silently dropped on this path"

echo
echo "-- 6  the features already restored must still be there (no regression)"
for _f in idle_apps_check sync_native_limit native_unlatch native_icl_restore native_verify_backstop mask_capacity auto_shutdown; do
  grep -q "$_f" $W/rc24tree.branch || no "$_f vanished from the branch"
done
[ "$F" -eq 0 ] && ok "all seven previously-restored calls are still present"

echo
echo "-- 7  the NON-native path must be untouched (the Mi A3's arm)"
# is_charging() still owns these for every phone without a firmware limit.
for a in "$ARM23" "$ARM24"; do
  _n=$(awk '/^  is_charging\(\) \{/{f=1} f{print} f && /^  \}/{exit}' "$a/accd.sh" | grep -c 'set_ch_curr')
  echo "     $(basename $a): is_charging still calls set_ch_curr $_n time(s)"
  [ "$_n" -ge 1 ] || no "$(basename $a): set_ch_curr was REMOVED from is_charging - non-native phones would lose the cap"
done
[ "$F" -eq 0 ] && ok "is_charging still owns the limits for phones without a firmware limit"

echo
echo "-- 8  can this suite still fail?"
mkdir -p $W/mut
sed '/set_ch_curr ${maxChargingCurrent\[0\]} || :/d' "$ARM24/accd.sh" > $W/mut/accd.sh
if cmp -s "$ARM24/accd.sh" $W/mut/accd.sh; then
  sk "could not mutate the new call"
else
  _m=$(cut_native "$W/mut" | grep -c 'set_ch_curr ${maxChargingCurrent')
  [ "$_m" -eq 0 ] && ok "mutation caught: removing the call empties the branch again" \
                  || no "mutation NOT caught: case 1 cannot fail"
fi

fin
