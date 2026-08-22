#!/system/bin/sh
# rc24-coverage.sh - the rc23 -> rc24 changes that do not need a charger, driven against the
#                    INSTALLED tree on this phone. Runs in seconds, plugged or not.
#
#   su -c 'sh /data/local/tmp/suites/rc24-coverage.sh'
#
# WHY IT EXISTS
#   rc24-plugged.sh covers the 25 changes that can only be seen with a real supply moving: the
#   contract latch, the plug edges, the kick gate on a live plug, an induced current cap, a real
#   pause and resume. The other 25 do not need a charger at all - they need the shipped code driven
#   with inputs a charger would never produce on demand, like a node that does not exist or a write
#   that cannot verify. Leaving those to a developer machine means the phone in your hand is never
#   the thing that proved them, so they are driven here against the installed build.
#
# NOTHING HERE SLEEPS AND NOTHING HERE WRITES TO A CHARGE NODE.
#   Every case runs against fabricated files under a scratch directory, or reads the installed
#   source. The daemon is not stopped, the config is not changed, and no sysfs node is written.
#   It is safe to run at any time, including while charging.

set +e
ID=rc24-coverage
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
sec(){ echo; echo "===== $* ====="; }

M=${M:-/data/adb/vr25/acc}
DD=${DD:-/data/adb/vr25/acc-data}
MF=$M/misc-functions.sh
AD=$M/accd.sh
AA=$M/acca.sh
W=/data/local/tmp/rc24cov
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null
DRV=$W/drv.sh
sed -n '/^_mv() {/,/^}/p;/^_ma() {/,/^}/p;/^_iin_ma() {/,/^}/p;/^_vbus_mv() {/,/^}/p;/^_hv_may_kick() {/,/^}/p;/^_hv_lift() {/,/^}/p;/^_rekick_due() {/,/^}/p;/^write() {/,/^}/p' $MF > $DRV

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)"
echo "build  : $(sed -n 's/^version=//p' $M/module.prop)  ($(sed -n 's/^versionCode=//p' $M/module.prop))"

sec "0  THE RIG"
[ "$(id -u)" = 0 ] || { no "not root"; exit 1; }
_nf=$(grep -c '^[_a-z]*() {' $DRV)
[ "${_nf:-0}" -ge 6 ] && ok "cut $_nf shipped functions out of the installed misc-functions.sh" \
                      || { no "only extracted $_nf functions - the rest of this file would grade nothing"; exit 1; }

sec "1  THE KICK GATE, WITH INPUTS A CHARGER CANNOT PRODUCE ON DEMAND  (#4 #9 #10)"

# #4 - a phone with no readable input-current node must never be re-detected. The gate can only
# justify a kick against a supply PROVEN dead, and an absent reading is not proof.
mkdir -p $W/nc/usb 2>/dev/null
_r=$( cd $W/nc && TMPDIR=$W/nc dataDir=$W/nc /system/bin/sh -c ". $DRV; present(){ return 0; }; _hv_may_kick && echo KICK || echo HOLD" 2>/dev/null )
[ "$_r" = HOLD ] && ok "#4 no readable input-current node -> the gate fails CLOSED" \
                 || no "#4 the gate answered '$_r' with no current node - it would kick on no evidence"

# #9 #10 - THE OUTAGE. A deep sag with a collapsed input is exactly what a dying charger looks like,
# and rc23 cleared the contract latch on it, which let the next call fire an APSD at a live plug.
# Only the cable coming out may clear the latch now.
mkdir -p $W/lat/usb 2>/dev/null
: > $W/lat/.hvcontract
printf '%s' 4400000 > $W/lat/usb/voltage_now
printf '%s' 0       > $W/lat/usb/input_current_now
( cd $W/lat && TMPDIR=$W/lat dataDir=$W/lat /system/bin/sh -c ". $DRV; present(){ return 0; }; _hv_may_kick" ) >/dev/null 2>&1
if [ -f $W/lat/.hvcontract ]; then
  ok "#9 #10 a 4.4V sag with a dead input does NOT clear the contract latch"
else
  no "#9 #10 the latch was CLEARED by a sag - this is the 9V to 4.4V path reopening"
fi

# The gate must also refuse a plug that was ever high, however far it later sags.
mkdir -p $W/pk/usb 2>/dev/null
printf '%s' 9000 > $W/pk/.hvpeak
printf '%s' 0    > $W/pk/usb/input_current_now
_r=$( cd $W/pk && TMPDIR=$W/pk dataDir=$W/pk /system/bin/sh -c ". $DRV; present(){ return 0; }; _hv_may_kick && echo KICK || echo HOLD" 2>/dev/null )
[ "$_r" = HOLD ] && ok "#13 a plug whose peak reached 9000mV stays negotiated even when dead now" \
                 || no "#13 the gate would re-detect a plug that has already been high"

sec "2  THE LIFT  (#14 #15 #17)"
# The lift is the answer to a stall. It must raise the charger-owned supplies and never touch the
# negotiation side: one write to usb/current_max was measured dropping a port to 100mA.
mkdir -p $W/lift/usb $W/lift/main $W/lift/dc $W/lift/pc_port 2>/dev/null
for s in usb main dc pc_port; do printf '%s' 500000 > $W/lift/$s/current_max; done
( cd $W/lift && TMPDIR=$W/lift dataDir=$W/lift /system/bin/sh -c ". $DRV; write(){ printf '%s' \"\$1\" > \"\$2\" 2>/dev/null; }; _hv_lift" ) >/dev/null 2>&1
_m=$(rd $W/lift/main/current_max); _u=$(rd $W/lift/usb/current_max)
_d=$(rd $W/lift/dc/current_max); _pp=$(rd $W/lift/pc_port/current_max)
if [ "$_m" = 5000000 ]; then ok "#14 the lift raised main/current_max to 5000000"
else no "#14 the lift left main/current_max at $_m - the stall repair does nothing"; fi
if [ "$_u" = 500000 ] && [ "$_d" = 500000 ] && [ "$_pp" = 500000 ]; then
  ok "#15 #17 usb/ dc/ and pc_port/ were left untouched - no 100mA collapse"
else
  no "#15 #17 the lift wrote a negotiation supply: usb=$_u dc=$_d pc_port=$_pp"
fi

sec "3  THE RE-KICK BUDGET  (#20)"
mkdir -p $W/bud 2>/dev/null
_r=$( TMPDIR=$W/bud /system/bin/sh -c ". $DRV; _rekick_due" >/dev/null 2>&1; [ -f $W/bud/.rekick ] && echo STAMPED || echo CLEAN )
[ "$_r" = CLEAN ] && ok "#20 asking whether a re-kick is due does not spend the budget" \
                  || no "#20 _rekick_due stamped the budget without anything having happened"

sec "4  NO RAW MICROVOLT LITERALS LEFT  (#24 #25)"
_raw=$( { sed 's/#.*//' $AD; sed 's/#.*//' $MF; } | grep -cE '6000000|5500000' )
case "${_raw:-x}" in ''|x) _raw=0;; esac
[ "$_raw" -eq 0 ] && ok "#24 #25 no raw microvolt literal survives in accd.sh or misc-functions.sh" \
                  || no "#24 #25 $_raw raw microvolt literal(s) remain in the decision paths"

sec "5  THE SWEEPS  (#30 #31 #32 #33 #34)"
_cs=$(sed -n '/^cycle_switches() {/,/^}/p' $MF | sed 's/#.*//')
printf '%s\n' "$_cs" | grep -q '\[ "\$1" = off \]' \
  && no "#30 the sweep budget still only covers the OFF direction" \
  || ok "#30 the sweep budget covers both directions"
grep -q '_rearm_sweep' $MF && ok "#31 enable_charging's fallback goes through the bounded helper" \
                           || no "#31 the fallback sweep has no ceiling"
_h=$(sed -n '/^_rearm_sweep() {/,/^}/p' $MF)
case "$_h" in
  *"local _swEnd"*) ok "#32 the ceiling is a local, so the exit-trap restore sweep stays unbounded" ;;
  *) no "#32 the ON budget is not a local - it can leak onto the unbounded restore sweep" ;;
esac
case "$_cs" in
  *_swAdopted*) ok "#33 cycle_switches tracks adoption, so a leftover candidate is cleared" ;;
  *) no "#33 no adoption marker - an untried candidate can survive in the global" ;;
esac
printf '%s\n' "$_cs" | grep -q 'rm -f .*testingsw' \
  && ok "#34 the marker removal is -f and cannot abort the caller under set -e" \
  || no "#34 the .testingsw removal can abort the caller"

sec "6  THE WRITE PATH  (#35 #36 #37)"
# rc23 attached the retry to the branch where the write had ALREADY verified, spending five extra
# echoes on a node that had taken the value, and returned immediately on the case that needed
# retrying. Both directions are counted here by instrumenting usleep, the retry loop's only caller.
mkdir -p $W/wr/logs 2>/dev/null
wrun(){ # $1 = value-or-path  -> number of retry ticks
  printf '%s' 1000 > $W/wr/node; : > $W/wr/ticks
  TMPDIR=$W/wr dataDir=$W/wr /system/bin/sh -c "lastNode=; _wlog(){ :; }; usleep(){ echo t >> $W/wr/ticks; }; seq(){ _s=1; while [ \$_s -le \$1 ]; do echo \$_s; _s=\$((_s+1)); done; }; . $DRV; write $1 $W/wr/node" >/dev/null 2>&1
  wc -l < $W/wr/ticks | tr -d ' '
}
_v=$(wrun 5000)
case "${_v:-x}" in
  0) ok "#35 a write that verifies costs one echo, not six (0 retry ticks)" ;;
  ''|x) sk "#35 could not measure the verifying write" ;;
  *) no "#35 a verifying write spent $_v retry tick(s) - the retry is on the wrong branch" ;;
esac
printf '%s' 7777 > $W/wr/want
_u=$(wrun "$W/wr/want")
[ "${_u:-0}" -gt 0 ] 2>/dev/null && ok "#36 #37 an unverified write spends the budget ($_u ticks) and re-reads each time" \
                                 || no "#36 #37 an unverified write did not retry at all ($_u ticks)"

sec "7  THE CLI AND THE CONFIG  (#41 #42 #43 #44 #46)"
grep -q '_acc_nopromo' $M/acc.sh \
  && ok "#41 acc -t suppresses the tie-break with the dedicated flag" \
  || no "#41 acc -t does not use _acc_nopromo"
sed 's/#.*//' $M/acc.sh | grep -q 'flip=off' \
  && no "#41 a flip=off remains in acc.sh - it would forge working-switches entries" \
  || ok "#41 no flip=off survives in acc.sh, so an interrupted wait forges nothing"

# #42 - a config VALUE must never be executed. rc23 used `export "$@"`, which re-expands.
rm -f $W/pwned 2>/dev/null
"$AA" -s 'cool_down_capacity=$(touch '"$W"'/pwned)' >/dev/null 2>&1
if [ -f $W/pwned ]; then
  no "#42 acca EXECUTED a command substitution taken from a config value"
else
  ok "#42 an acca value containing a command substitution is stored, not executed"
fi

"$AA" -s dcapacity >/dev/null 2>&1
_g=$?
[ "$_g" = 0 ] && ok "#43 acca accepts a glued -sd filter (exit 0)" \
              || no "#43 a glued -sd filter exited $_g - it aborts under set -eu"

"$AA" -s p 2>/dev/null | grep -q 'ui_refresh' \
  && ok "#44 ui_refresh is readable back through the config printer" \
  || no "#44 ui_refresh is missing from the config printer"

grep -q '/system/bin/sh' $M/service.sh \
  && ok "#46 the fallback launcher pins /system/bin/sh, not whatever PATH resolves" \
  || no "#46 the fallback launcher does not pin an interpreter"

sec "8  UNINSTALL  (#47 - matched, never executed)"
# An uninstall is not run on a phone that is being used. This is the one change graded by shape.
if sed 's/#.*//' $M/uninstall.sh | grep -q 'usb/\*'; then
  ok "#47 uninstall excludes the negotiation supplies (source match; an uninstall is never run here)"
else
  no "#47 uninstall does not exclude usb/ - it would drop the port to ~100mA on removal"
fi

echo
echo "$ID: $P passed, $F failed, $S skipped"
[ "$F" -eq 0 ] && exit 0 || exit 1
