#!/system/bin/sh
# Scheduled day/night profiles: the chain from a config `at` line to a setting that actually holds.
#
# FIELD REPORT (OnePlus 8 Pro, IN2023, rc25-test4, 2026-09-10). Three profiles in config.txt:
#
#   : day_profile;   at 03:45 acc -s pc=85 rc=80 ... mcc=1000 mcv= tl=0 ..., acc -n switched to day profile
#   : sleep_profile; at 19:00 acc -s pc=50 rc=47 ... mcc=500 mcv=3900 ..., acc -n switched to sleep profile
#
# At 03:45 the phone showed "switched to day profile" and kept every sleep setting: 50%, 500 mA,
# 3900 mV. His bundle's live config is the sleep profile with ONE day value in it, tempLevel=0.
#
# Each section below is one link in that chain, driven out of the shipped files with fixtures.
# Sections 1-5 fail on rc24 as well: they are long-standing, not rc25 regressions. Section 6 is a
# genuine rc24 -> rc25 regression and is marked as such.

ID=t-scheduled-profiles
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SCV=${SCV:-$execDir/set-ch-volt.sh}
WC=${WC:-$execDir/write-config.sh}
MF=${MF:-$execDir/misc-functions.sh}
SE=${SE:-$execDir/state-export.sh}
DC=${DC:-$execDir/diag-collect.sh}
for f in "$SCV" "$WC" "$MF" "$SE"; do
  [ -f "$f" ] || { no "missing $f"; fin; }
done

W=${TMPDIR_T:-/data/local/tmp}/t-sched-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null

echo "--- 1. a scheduled command must not be mistaken for the daemon's own write"
# accd exports isAccd=true. at() sources the profile line INSIDE the daemon, so `acc -s` inherits
# it, and set_ch_volt's first line is
#     $isAccd && [ -f $TMPDIR/.mcv-settling ] && return 0
# while set-prop.sh creates that marker immediately before calling it. The setter therefore sees
# its OWN caller's marker, reports success and changes nothing. Same shape guards set_ch_curr.
scv_reached(){
  # $1 = value for isAccd in the environment. Echoes reached|skipped.
  #
  # The guard is the first line of the function and runs no external command. Everything past it
  # does, starting with the sed that reads the stored voltage off disk. So a shadowed sed is an
  # exact probe for "execution got past the guard", with no dependence on what the setter then
  # does with a fixture phone.
  ( TMPDIR=$W/tmp; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    # set-prop.sh names the owner in the marker; the fixture writes what it writes.
    echo $$ > $TMPDIR/.mcv-settling
    dataDir=$W; config=$W/config.txt
    echo 'maxChargingVoltage=(3900 x::3900000::4400000)' > "$config"
    maxChargingVoltage=()
    isAccd=$1
    eval "$(/system/bin/sed -n '/^set_ch_volt() {/,/^}/p' "$SCV")"
    sed(){ : > "$TMPDIR/.past-guard"; /system/bin/sed "$@"; }
    set_ch_volt 4200 >/dev/null 2>&1 || :
    [ -f "$TMPDIR/.past-guard" ] && echo reached || echo skipped )
}
r=$(scv_reached false)
[ ".$r" = .reached ] && ok "a plain CLI set reaches the voltage setter" \
  || no "a plain CLI set was skipped: $r"
r=$(scv_reached true)
[ ".$r" = .reached ] && ok "a scheduled set (isAccd inherited) also reaches the voltage setter" \
  || no "a scheduled set was swallowed by its own settling marker: $r"
# ...and the race the marker exists for must still be blocked: a marker owned by ANOTHER process
# is a set in flight elsewhere, and the daemon must stand down for it.
scv_other(){
  ( TMPDIR=$W/tmpo; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
    echo 999999 > $TMPDIR/.mcv-settling
    dataDir=$W; config=$W/config.txt
    echo 'maxChargingVoltage=(3900 x::3900000::4400000)' > "$config"
    maxChargingVoltage=()
    isAccd=true
    eval "$(/system/bin/sed -n '/^set_ch_volt() {/,/^}/p' "$SCV")"
    sed(){ : > "$TMPDIR/.past-guard"; /system/bin/sed "$@"; }
    set_ch_volt 4200 >/dev/null 2>&1 || :
    [ -f "$TMPDIR/.past-guard" ] && echo reached || echo skipped )
}
r=$(scv_other)
[ ".$r" = .skipped ] && ok "the daemon still stands down for a set another process is applying" \
  || no "the daemon ignored another process's settling marker: $r"

echo "--- 2. a config that failed to publish must not report success"
# write-config.sh ends with
#     mv -f $_ct $config 2>/dev/null || rm -f $_ct 2>/dev/null
# so a rename that fails is swallowed and the file keeps its old contents, while set-prop.sh has
# already printed the success tick. The user is told the profile switched and it did not.
wc_reports(){
  ( TMPDIR=$W/tmp2; mkdir -p "$TMPDIR"
    dataDir=$W/d2; mkdir -p "$dataDir"
    config=$dataDir/config.txt
    printf 'capacity=(5 101 47 50 false)\n' > "$config"
    # make the rename fail the way a lost permission or a full filesystem does
    mv(){ return 1; }
    execDir=${execDir}
    _out=$( set +e; . "$WC" 2>&1; echo "rc=$?" )
    echo "${_out##*rc=}|$(sed -n 's/^capacity=//p' "$config")" )
}
r=$(wc_reports)
case "$r" in
  0\|*) no "a failed publish returned 0 (config still $(echo "$r" | cut -d'|' -f2))";;
  *)    ok "a failed publish returns non-zero";;
esac

echo "--- 3. the profile notification must not fire when the settings command failed"
# at() turns the user's comma into a semicolon:
#     echo "$@" | sed 's/,/\;/g; ...'
# so the line becomes `settings; notification` and the notification runs whatever happened. The
# whole thing is sourced as `. $file || :`, which switches errexit OFF for everything inside, so
# even an aborting settings command cannot stop the message.
at_fires(){
  ( TMPDIR=$W/tmp3; mkdir -p "$TMPDIR/schedules"
    isAccd=true
    eval "$(sed -n '/^at() {/,/^}/p' "$MF")"
    H=$((10#$(date +%H))); M=$((10#$(date +%M)))
    [ $M -ge 1 ] || { echo skip; return 0; }
    T=$(printf '%02d:%02d' "$H" "$((M - 1))")
    rm -f "$W/notified"
    at "$T" false, touch "$W/notified"
    [ -f "$W/notified" ] && echo notified || echo quiet )
}
r=$(at_fires)
case "$r" in
  skip) ok "skipped: run at least a minute into the hour"; ok "skipped";;
  quiet) ok "a failed settings command leaves the notification unsent"
         ok "the message reflects what happened";;
  *) no "the notification was sent after the settings command failed"
     no "the message the owner sees does not reflect what happened";;
esac

echo "--- 4. a schedule that failed must not be recorded as done for the day"
# at() writes its marker BEFORE running the commands, and its own guard is `[ ! -f $file ]`, so a
# profile that failed at 03:45 is never attempted again until the marker is cleared at midnight.
at_retries(){
  ( TMPDIR=$W/tmp4; mkdir -p "$TMPDIR/schedules"
    isAccd=true
    eval "$(sed -n '/^at() {/,/^}/p' "$MF")"
    H=$((10#$(date +%H))); M=$((10#$(date +%M)))
    [ $M -ge 1 ] || { echo skip; return 0; }
    T=$(printf '%02d:%02d' "$H" "$((M - 1))")
    rm -f "$W/ran"
    at "$T" false
    at "$T" touch "$W/ran"
    [ -f "$W/ran" ] && echo retried || echo "stuck" )
}
r=$(at_retries)
case "$r" in
  skip)    ok "skipped: run at least a minute into the hour";;
  retried) ok "a failed schedule is retried rather than marked done";;
  *)       no "a failed schedule was marked done and never retried";;
esac

echo "--- 5. a temperature band that had to be repaired must say so"
# His night profile is mt=45 rt=43 ct=46. Cooldown above max is genuinely invalid, and once it is
# pulled under max there is no room for the 3 C cooldown gap, so the band is rebuilt and rt=43 -
# valid on its own - goes with it. Published: temperature=(40 45 35 55). The arithmetic is right;
# doing it in silence is not. The owner read those numbers back and could not tell why they were
# not the ones he set. This grades the message, not the values, because changing the values would
# change thermal behaviour for every phone that already relies on it.
temps(){
  ( TMPDIR=$W/tmp5; mkdir -p "$TMPDIR"
    dataDir=$W/d5; mkdir -p "$dataDir"
    config=$dataDir/config.txt; : > "$config"
    mt=$1; rt=$2; ct=$3
    isAccd=${4:-false}
    . "$WC" 2>"$W/warn5" >/dev/null || :
    sed -n 's/^temperature=//p' "$config" )
}
r=$(temps 45 43 46)
w=$(cat "$W/warn5" 2>/dev/null)
case "$r" in
  *"45 35"*)
    case "$w" in
      *adjusted*) ok "the rebuilt band is reported to the user: $r";;
      *) no "the band became $r with nothing said about it";;
    esac
  ;;
  *"45 43"*) ok "the requested resume_temp survived: $r";;
  *) no "unexpected temperature result for mt=45 rt=43 ct=46: $r";;
esac
# The daemon persists this file constantly and must stay silent.
r=$(temps 45 43 46 true)
w=$(cat "$W/warn5" 2>/dev/null)
[ -z "$w" ] && ok "the daemon's own config persist says nothing" \
  || no "the daemon narrated a config persist: $w"
# Observed, not graded: raising a cooldown_temp that sits below resume_temp is a documented rule
# ("never let cooldown_temp fall below resume_temp"), so mt=50 rt=45 ct=35 becoming (45 50 45 55)
# is the rule working, not a defect.
echo "  ..    for reference, mt=50 rt=45 ct=35 publishes $(temps 50 45 35)"

echo "--- 6. REGRESSION rc24 -> rc25: input telemetry on a phone whose Mains supply carries online"
# OnePlus 8 Pro, charging from the wall:
#     ac/online=1   usb/present=1   usb/online=0   usb/voltage_now=4843728
# rc24 read usb/voltage_now unconditionally and gated only the CURRENT on online, so it published
# 4843 mV. rc25 requires online=1 on the supply itself before considering it at all, so both
# fields come back null on a phone that is plainly charging.
D=$W/psy; rm -rf $D; mkdir -p $D/ac $D/usb $D/wireless $D/battery
echo 1 > $D/ac/online
echo 1 > $D/usb/present
echo 0 > $D/usb/online
echo 4843728 > $D/usb/voltage_now
echo 0 > $D/wireless/online
echo 0 > $D/wireless/present
se_input(){
  ( ACC_PSY=$1; export ACC_PSY
    for fn in _se_int _se_rd _se_num _se_ma _se_gate_ma _se_voltage_mv _se_input_ma _se_icl_guard _se_any_online _se_input; do
      eval "$(sed -n "/^$fn() {/,/^}/p" "$SE")"
    done
    _se_input )
}
# Does this tree's exporter honour the fixture at all? rc24 hardcodes /sys/class/power_supply and
# reads the phone it runs on, so its answer here grades the device, not the code.
EMPTY=$W/psy-empty; rm -rf $EMPTY; mkdir -p $EMPTY
if [ ".$(se_input $EMPTY)" != '."input":{"voltageMv":null,"currentMa":null}' ]; then
  ok "SKIP section 6: this tree's _se_input ignores ACC_PSY and reads the live phone"
  ok "SKIP section 6"
else
r=$(se_input $D)
case "$r" in
  *'"voltageMv":4843'*) ok "the mains-online arrangement still publishes the 4.84 V bus reading";;
  *) no "a charging phone exports no input telemetry: $r";;
esac
# ...and the FP5 mirrored-register case must stay refused: nothing online anywhere, so nothing to report.
D2=$W/psy2; rm -rf $D2; mkdir -p $D2/usb
echo 0 > $D2/usb/online
echo 0 > $D2/usb/present
echo 9375000 > $D2/usb/current_now
echo 8980000 > $D2/usb/voltage_now
r=$(se_input $D2)
case "$r" in
  *'"voltageMv":null'*) ok "a supply that is neither online nor present is still ignored";;
  *) no "an offline, absent supply was reported as input: $r";;
esac
fi

echo "--- 7. the diagnostic must carry what identifies a failed profile switch"
if [ -f "$DC" ]; then
  grep -q 'schedules.txt' "$DC" && ok "the collector captures the scheduler markers" \
    || no "the collector captures no scheduler state - a failed switch leaves no trace"
  grep -q 'acc-cli-trace' "$DC" && ok "the collector captures the CLI trace" \
    || no "the collector takes accd-*.log but not the acc CLI trace, which is where a failed acc -s is recorded"
else
  ok "no diag-collect.sh in this tree, section skipped"
  ok "no diag-collect.sh in this tree, section skipped"
fi

rm -rf "$W"
fin
