#!/system/bin/sh
# t124 - a cap must never be recorded as the node's own default.
#
# THE FAULT
#   Every control-file entry is  node::marker::DEFAULT , and the default is simply whatever the node
#   reads at the moment discovery runs. Run discovery while a cap is APPLIED and the cap is recorded
#   as the default. From then on "restore to default" writes the cap back, so no clear can ever
#   release it, and the phone is pinned at a limit its own config says it does not have.
#
#   Caught on a Mi A3 after a run that set 4150mV and restarted the daemon:
#
#       battery/voltage_max::v000::4150000     <- the cap, now the default
#       bms/voltage_max::v000::4400000         <- discovered before the cap, still true
#       main/voltage_max::v000::4150000        <- the cap again
#
#   Two of three poisoned. The pack then floated at 4.15V on a 4.4V cell with a config and a UI that
#   both read "no limit". The same mechanism had left that phone at 3.9V earlier in the day.
#
#   It is self-perpetuating, which is what makes it worse than an ordinary stale value: the number
#   being recorded is the very one the user asked to remove.
#
# THE SECOND FAULT, WHICH HID BEHIND THE FIRST
#   apply_on_boot restores the voltage nodes and iterated only the maxChargingVoltage array. By the
#   time the daemon reaches a release, the config has been re-read with that array empty, so the
#   loop had nothing to iterate and restored nothing. apply_on_plug already solved this on the
#   current side by falling back to the resolved ctrl-files; the voltage side never got it.
#
# GRADED BOTH ARMS.

ID=t124
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t124}
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

for a in "$ARM23" "$ARM24"; do
  [ -f "$a/read-ch-curr-ctrl-files-p2.sh" ] || { no "no read-ch-curr-ctrl-files-p2.sh in $a"; fin; }
  [ -f "$a/misc-functions.sh" ] || { no "no misc-functions.sh in $a"; fin; }
done
ok "both arms present"

CCF=ch-curr-ctrl-files

# Drive the shipped discovery with a cap configured and an existing snapshot, and report the
# default that survives for the first node.
run_curr(){
  _arm=$1
  rm -rf $W/t $W/ps 2>/dev/null; mkdir -p $W/t $W/ps/usb $W/ps/battery
  echo 500000 > $W/ps/usb/current_max
  echo 500000 > $W/ps/battery/constant_charge_current
  echo "usb/current_max::v000::2000000" > $W/t/$CCF
  # The guard reads a config FILE (a shell variable cannot stand in for it), so give it one.
  echo "maxChargingCurrent=(500 usb/current_max::500000::2000000)" > $W/t/fixture.conf
  {
    echo "TMPDIR=$W/t"
    echo "execDir=$_arm"
    echo "currentWorkaround=false"
    echo "maxChargingCurrent=(500 usb/current_max::500000::2000000)"
    echo "config=$W/t/fixture.conf"
    echo "cd $W/ps"
    echo ". $_arm/read-ch-curr-ctrl-files-p2.sh"
    echo "head -1 $W/t/$CCF 2>/dev/null || echo GONE"
  } > $W/r.sh
  /system/bin/sh $W/r.sh 2>/dev/null | tail -1
}

echo
echo "-- 1  current discovery must not re-record while a cap is applied"
_a=$(run_curr "$ARM23"); _b=$(run_curr "$ARM24")
echo "     rc23 kept: $_a"
echo "     now  kept: $_b"
case "$_a" in *2000000) _a23=safe ;; *) _a23=poisoned ;; esac
case "$_b" in *2000000) _b24=safe ;; *) _b24=poisoned ;; esac
if [ "$_a23" = poisoned ] && [ "$_b24" = safe ]; then
  ok "the true default 2000000 survives, where rc23 overwrote it with the 500000 cap"
elif [ "$_a23" = safe ]; then
  no "rc23 already kept the default - this case proves nothing"
else
  no "the default was overwritten by the cap: $_b"
fi

echo
echo "-- 2  with NO cap configured, discovery must still run normally"
run_nocap(){
  _arm=$1
  rm -rf $W/t $W/ps 2>/dev/null; mkdir -p $W/t $W/ps/usb $W/ps/battery
  echo 2000000 > $W/ps/usb/current_max
  echo 3000000 > $W/ps/battery/constant_charge_current
  echo "maxChargingCurrent=()" > $W/t/fixture.conf
  {
    echo "TMPDIR=$W/t"; echo "execDir=$_arm"; echo "currentWorkaround=false"
    echo "maxChargingCurrent=()"
    echo "config=$W/t/fixture.conf"
    echo "cd $W/ps"
    echo ". $_arm/read-ch-curr-ctrl-files-p2.sh"
    echo "_c=\$(grep -c / $W/t/$CCF 2>/dev/null); case \"\${_c:-}\" in ''|*[!0-9]*) _c=0;; esac; echo \$_c"
  } > $W/r2.sh
  /system/bin/sh $W/r2.sh 2>/dev/null | tail -1
}
_n=$(run_nocap "$ARM24")
[ "${_n:-0}" -ge 1 ] && ok "discovery still resolves $_n node(s) when nothing is capped" \
                     || no "discovery stopped working with no cap configured"

echo
echo "-- 3  the voltage restore must find its entries when the array is already empty"
run_boot(){
  _arm=$1; _arg=$2; _out=$3
  rm -rf $W/b $W/bps 2>/dev/null; mkdir -p $W/b $W/bps/battery
  echo 4150000 > $W/bps/battery/voltage_max
  echo "battery/voltage_max::v000::4400000" > $W/b/ch-volt-ctrl-files
  {
    echo "TMPDIR=$W/b"
    echo "applyOnBoot=(); maxChargingVoltage=()"
    echo "write(){ echo WROTE >> $_out; return 0; }"
    echo "_wlog(){ :; }"
    sed -n '/^apply_on_boot() {/,/^}/p' "$_arm/misc-functions.sh"
    echo "cd $W/bps"
    echo "apply_on_boot $_arg force >/dev/null 2>&1"
  } > $W/b.sh
  : > $_out
  /system/bin/sh $W/b.sh 2>/dev/null
  _c=$(grep -c WROTE $_out 2>/dev/null); case "${_c:-}" in ''|*[!0-9]*) _c=0;; esac; echo "$_c"
}
_a=$(run_boot "$ARM23" default $W/w23); _b=$(run_boot "$ARM24" default $W/w24)
echo "     rc23 attempted $_a write(s)   current attempted $_b"
if [ "${_a:-0}" -eq 0 ] && [ "${_b:-0}" -ge 1 ]; then
  ok "the restore now falls back to the resolved ctrl-files, where rc23 iterated nothing"
elif [ "${_a:-0}" -ge 1 ]; then
  no "rc23 already restored - this case proves nothing"
else
  no "the restore still finds no entries and writes nothing"
fi

echo
echo "-- 4  an APPLY must NOT be conjured out of the ctrl-files list"
_v=$(run_boot "$ARM24" value $W/wv)
[ "${_v:-0}" -eq 0 ] && ok "a value-apply with an empty array writes nothing" \
                     || no "the fallback leaked into an APPLY ($_v write(s))"

echo
echo "-- 5  the voltage discovery block must carry the same guard"
_g=$(grep -c "mV cap is applied" "$ARM24/accd.sh" 2>/dev/null); case "${_g:-}" in ''|*[!0-9]*) _g=0;; esac
_g23=$(grep -c "mV cap is applied" "$ARM23/accd.sh" 2>/dev/null); case "${_g23:-}" in ''|*[!0-9]*) _g23=0;; esac
if [ "${_g23:-0}" -eq 0 ] && [ "${_g:-0}" -ge 1 ]; then
  ok "the voltage discovery refuses to re-record while a cap is applied"
else
  no "voltage discovery guard: rc23=$_g23 now=$_g"
fi

echo
echo "-- 6  can this suite still fail?"
mkdir -p $W/mut
# TWO independent defences now: the guard that refuses to re-record while a cap is set, and the
# merge that refuses to lower a default. Disabling either alone leaves the other holding, which is
# the point of having both -- so the mutation must defeat both to show case 1 can fail.
sed -e 's/^if \[ -n "${_capcfg:-}" \].*then$/if false; then/' \
    -e '/DEFAULT MUST NEVER GO DOWN/,/^    rm -f ${currCtrl}.prev/d' \
  "$ARM24/read-ch-curr-ctrl-files-p2.sh" > $W/mut/read-ch-curr-ctrl-files-p2.sh
if cmp -s "$ARM24/read-ch-curr-ctrl-files-p2.sh" $W/mut/read-ch-curr-ctrl-files-p2.sh; then
  sk "could not mutate the discovery guard"
else
  _m=$(run_curr "$W/mut")
  case "$_m" in
    *2000000) no "mutation NOT caught: case 1 cannot fail" ;;
    *)        ok "mutation caught: without the guard the cap is recorded as the default again" ;;
  esac
fi

fin
