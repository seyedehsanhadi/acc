#!/system/bin/sh
# t122 - clearing a charging limit must clear it WHOLE, not just its first element.
#
# THE SHELL FACT THIS RESTS ON
#   In mksh, assigning a scalar to an array NAME writes element 0 and leaves the rest alive:
#
#       maxChargingCurrent=(500 usb/current_max::500000::2200000 main/current_max::500000::2000000)
#       export maxChargingCurrent=
#       -> count is STILL 3, [0] is empty, [1..2] untouched
#
#   set-prop.sh clears a config key with `export "$@"`, so `acc -s maxChargingCurrent=` dropped the
#   user's value and kept every derived node entry. write-config then published
#
#       maxChargingCurrent=( usb/current_max::500000::2200000 main/current_max::500000::2000000)
#
#   and apply_on_plug iterates ${maxChargingCurrent[@]}, not [0] -- so the survivors were re-applied
#   on every loop. The cap could not be cleared.
#
# WHAT IT COST, MEASURED
#   Both test phones, after `acc -s maxChargingCurrent=`: usb/current_max and main-charger/current_max
#   stayed pinned at 500000 while the config and the UI both reported no limit. Recoverable only by
#   hand-editing the config and restarting the daemon. The same mechanism stranded a Mi A3 at a 3.9V
#   float on a pack that charges to 4.4V, after a 4000mV maxChargingVoltage was cleared the same way.
#
#   It is device-independent: it is a property of the shell, and it reproduces identically on a
#   Tensor Pixel 6a and a Snapdragon Mi A3.
#
# GRADED BOTH ARMS. A case only counts if rc23 fails it and the current tree passes.

ID=t122
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t122}
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

for a in "$ARM23" "$ARM24"; do
  [ -f "$a/set-prop.sh" ] || { no "no set-prop.sh in $a"; fin; }
done
ok "both arms present"

echo
echo "-- 0  the shell fact this whole case rests on"
_r=$(/system/bin/sh -c 'a=(500 x::1::2 y::3::4); a=; echo "${#a[@]}|${a[@]}"')
echo "     scalar-assign to an array name -> $_r"
case "$_r" in
  3\|*) ok "confirmed: a scalar assignment leaves elements 1..n alive on this shell" ;;
  0\|*) sk "this shell clears the whole array on scalar assign - the defect cannot exist here" ; fin ;;
  *)    no "unexpected: $_r" ;;
esac

# Replay set-prop's clearing sequence out of each arm.
#   run <arm> <key=>   -> the serialised config line the arm would publish
run(){
  _arm=$1; _kv=$2
  # Only take the range when the arm actually HAS the whole-array clear. rc23 has no `unset _spa`,
  # so an open-ended range would run to end-of-file and execute the rest of set-prop.sh.
  if grep -q '^      unset _spa$' "$_arm/set-prop.sh"; then
    _seq=$(sed -n '/^      export "\$@"$/,/^      unset _spa$/p' "$_arm/set-prop.sh")
  else
    _seq='      export "$@"'
  fi
  {
    echo 'maxChargingCurrent=(500 usb/current_max::500000::2200000 main/current_max::500000::2000000)'
    echo 'maxChargingVoltage=(4000 battery/voltage_max::4000000::4400000)'
    echo "set -- $_kv"
    printf '%s\n' "$_seq"
    echo 'echo "mcc=(${maxChargingCurrent[@]})|n=${#maxChargingCurrent[@]}|mcv=(${maxChargingVoltage[@]})"'
  } > $W/r.sh
  /system/bin/sh $W/r.sh 2>/dev/null | tail -1
}

echo
echo "-- 1  clearing the current cap must leave nothing behind"
_a=$(run "$ARM23" 'maxChargingCurrent='); _b=$(run "$ARM24" 'maxChargingCurrent=')
echo "     rc23 -> $_a"
echo "     now  -> $_b"
case "$_a" in *usb/current_max*) _a23=stale ;; *) _a23=clean ;; esac
case "$_b" in *usb/current_max*) _b24=stale ;; *) _b24=clean ;; esac
if [ "$_a23" = stale ] && [ "$_b24" = clean ]; then
  ok "the derived node entries are gone, where rc23 kept them and re-applied them every loop"
elif [ "$_a23" = clean ]; then
  no "rc23 already cleared them - this case proves nothing"
else
  no "node entries still survive the clear"
fi

echo
echo "-- 2  the voltage cap has the same hole - a Mi A3 was left floating at 3.9V by it"
_a=$(run "$ARM23" 'maxChargingVoltage='); _b=$(run "$ARM24" 'maxChargingVoltage=')
case "$_a" in *battery/voltage_max*) _a23=stale ;; *) _a23=clean ;; esac
case "$_b" in *battery/voltage_max*) _b24=stale ;; *) _b24=clean ;; esac
[ "$_a23" = stale ] && [ "$_b24" = clean ] && ok "clearing the voltage cap leaves nothing behind either" \
  || no "voltage clear: rc23=$_a23 now=$_b24"

echo
echo "-- 3  the short aliases must behave the same"
for _k in mcc= max_charging_current=; do
  _b=$(run "$ARM24" "$_k")
  case "$_b" in *usb/current_max*) no "'$_k' left node entries behind" ;; *) : ;; esac
done
[ "$F" -eq 0 ] && ok "mcc= and max_charging_current= clear as fully as the long name"

echo
echo "-- 4  a REAL value must still be stored (the clear must not eat ordinary sets)"
_b=$(run "$ARM24" 'maxChargingCurrent=800')
echo "     $_b"
case "$_b" in *'mcc=(800'*) ok "setting 800 still stores 800" ;; *) no "a real value was lost: $_b" ;; esac

echo
echo "-- 5  clearing one limit must not disturb the other"
_b=$(run "$ARM24" 'maxChargingCurrent=')
case "$_b" in
  *'mcv=(4000 battery/voltage_max::4000000::4400000)'*) ok "the voltage cap is untouched when the current cap is cleared" ;;
  *) no "clearing the current cap disturbed the voltage cap: $_b" ;;
esac

echo
echo "-- 5b  a config ALREADY corrupted by an older build must heal on the next write"
# Fixing set-prop stops new corruption; it cannot repair what is already on disk. An upgrading user
# carries maxChargingCurrent=( node::... ) with no leading value, and apply_on_plug would keep
# re-applying it. write-config must drop it.
heal(){
  _arm=$1
  {
    echo 'maxChargingCurrent=( usb/current_max::500000::2200000 main/current_max::500000::2000000)'
    echo 'maxChargingVoltage=( battery/voltage_max::4000000::4400000)'
    sed -n '/^mcc="\${max_charging_current/,/^case "\$mcv" in/p' "$_arm/write-config.sh" 2>/dev/null       || echo 'mcc="${maxChargingCurrent[@]}"; mcv="${maxChargingVoltage[@]}"'
    echo 'echo "mcc=($mcc)|mcv=($mcv)"'
  } > $W/h.sh
  /system/bin/sh $W/h.sh 2>/dev/null | tail -1
}
_hb=$(heal "$ARM24")
echo "     now  -> $_hb"
case "$_hb" in
  *usb/current_max*|*battery/voltage_max*) no "a config corrupted by an older build is republished as-is" ;;
  *) ok "an already-corrupted config is healed on the next write" ;;
esac

echo
echo "-- 6  can this suite still fail?"
mkdir -p $W/mut
sed '/maxChargingCurrent=|max_charging_current=|mcc=) maxChargingCurrent=() ;;/d' "$ARM24/set-prop.sh" > $W/mut/set-prop.sh
if cmp -s "$ARM24/set-prop.sh" $W/mut/set-prop.sh; then
  sk "could not mutate the clear"
else
  _m=$(run "$W/mut" 'maxChargingCurrent=')
  case "$_m" in *usb/current_max*) ok "mutation caught: without the whole-array clear the entries survive again" ;;
                *) no "mutation NOT caught: case 1 cannot fail" ;; esac
fi

fin
