#!/system/bin/sh
# t120 - when a current cap is configured, apply_on_plug must actually attempt the writes.
#
# THE FIELD SHAPE
#   ACC's own source names this symptom, in accd.sh beside the .mcc-custom rebuild:
#
#       "the cap was configured, displayed as active, and enforced nowhere"
#
#   Two Pixels show exactly that. A Pixel 4a 5G (bramble, SM7250) reported by a user carries
#   maxChargingCurrent=(925) that never expanded to node entries, and its write-ledger holds 22
#   voltage writes and ZERO current writes. A Pixel 6a (bluejay, Tensor) here behaves identically:
#   mcc=500 leaves the pack at ~1.9A and writes nothing, on two different chipsets.
#
#   The Mi A3 in the same room applies a cap correctly: 1994mA -> 433mA -> 2891mA on release.
#
# WHAT THIS ISOLATES
#   apply_on_plug is the one place a cap reaches a node. It is driven here against a FABRICATED
#   power_supply tree with `write` stubbed to a recorder, so the question "does the apply path even
#   attempt the write" is answered without a charger, without the daemon, and without depending on
#   whichever charging state the phone happens to be in. Both arms are driven, so a difference
#   between rc23 and rc24 would show up as one.
#
# WHAT IT DELIBERATELY DOES NOT CLAIM
#   This does not yet explain the Pixels. It pins the apply path's contract so the next round can
#   tell a broken apply from a branch that is never reached.

ID=t120
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t120}
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

for a in "$ARM23" "$ARM24"; do
  [ -f "$a/misc-functions.sh" ] || { no "no misc-functions.sh in $a"; fin; }
done
ok "both arms present"

# Drive apply_on_plug with a recorder in place of write().
#   run <arm> <arg> <mcc-custom yes|no> <reject-count>   -> prints the nodes it tried to write
run(){
  _arm=$1; _arg=$2; _mk=$3; _rej=$4
  rm -rf $W/t $W/ps 2>/dev/null; mkdir -p $W/t $W/ps/usb $W/ps/battery
  echo 2000000 > $W/ps/usb/current_max
  echo 3000000 > $W/ps/battery/constant_charge_current
  [ "$_mk" = yes ] && : > $W/t/.mcc-custom
  printf '%s\n' 'usb/current_max::v000::2000000' \
                'battery/constant_charge_current::v000::3000000' > $W/t/ch-curr-ctrl-files
  if [ "${_rej:-0}" -gt 0 ] 2>/dev/null; then
    echo "500000 $_rej" > "$W/t/.mccrej-usb_current_max"
    echo "500000 $_rej" > "$W/t/.mccrej-battery_constant_charge_current"
  fi
  {
    echo "TMPDIR=$W/t"
    echo 'applyOnPlug=(); maxChargingVoltage=()'
    echo 'maxChargingCurrent=(500 usb/current_max::500000::2000000 battery/constant_charge_current::500000::3000000)'
    echo "write(){ echo \"WROTE \$1 <- \$2\" >> $W/wrote; return 0; }"
    echo '_wlog(){ :; }'
    sed -n '/^apply_on_plug() {/,/^}/p' "$_arm/misc-functions.sh"
    echo "cd $W/ps || exit 1"
    echo "apply_on_plug $_arg >/dev/null 2>&1"
  } > $W/run.sh
  : > $W/wrote
  /system/bin/sh $W/run.sh 2>/dev/null
  sort $W/wrote 2>/dev/null | sed 's/^/       /'
  grep -c WROTE $W/wrote 2>/dev/null || :
}

cnt(){ run "$@" | tail -1; }

echo
echo "-- 1  a configured cap, marker present: both nodes must be attempted"
_a=$(cnt "$ARM23" value yes 0); _b=$(cnt "$ARM24" value yes 0)
echo "     rc23 wrote $_a   current wrote $_b"
[ "${_b:-0}" -ge 2 ] && ok "the apply path attempts every configured node" \
                     || no "only ${_b:-0} node(s) attempted with a cap configured and the marker up"

echo
echo "-- 2  marker ABSENT must SKIP - this is the documented guard, not a bug"
_b=$(cnt "$ARM24" value no 0)
echo "     wrote $_b with .mcc-custom absent"
[ "${_b:-0}" -eq 0 ] && ok "without the marker every throttling node is skipped, as designed" \
                     || no "the guard did not hold: $_b node(s) written with no marker"

echo
echo "-- 3  a node that has rejected 5x is backed off"
_b=$(cnt "$ARM24" value yes 5)
echo "     wrote $_b with a reject count of 5"
[ "${_b:-0}" -eq 0 ] && ok "a node that rejected the same value 5 times is skipped" \
                     || no "backoff did not engage: $_b written"

echo
echo "-- 4  every 8th tick retries, so a charger that frees up is picked up again"
_b=$(cnt "$ARM24" value yes 8)
[ "${_b:-0}" -ge 2 ] && ok "the 8th tick retries the backed-off nodes" \
                     || no "the retry tick did not fire: $_b written"

echo
echo "-- 5  rc23 and rc24 must agree - a difference here would be an rc24 regression"
_a=$(cnt "$ARM23" value yes 0); _b=$(cnt "$ARM24" value yes 0)
[ "${_a:-0}" = "${_b:-0}" ] && ok "both arms attempt the same $_b node(s) - the apply path is unchanged in rc24" \
                           || no "rc23 wrote $_a but current wrote $_b - rc24 changed the apply path"

fin
