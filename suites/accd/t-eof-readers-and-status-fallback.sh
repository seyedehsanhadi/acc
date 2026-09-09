#!/system/bin/sh
# Three defects in the rc24 -> rc25 delta, EXECUTED.
#
# 1. status() (batt-interface.sh)
#    rc24 coerced an unreadable current to 0 and always went on to read the kernel's own status
#    word. rc25 added two early "_status=Unknown; return 1" exits -- one for a garbage current, one
#    for a current whose unit cannot be resolved -- and both sit ABOVE the read_status call, the
#    battStatusOverride branch and the battStatusWorkaround gate. A phone that has deliberately
#    turned current-based inference OFF then loses the kernel verdict it asked for, over a reading
#    it does not use. not_charging() never answers "not charging" and accd's resume branch, which
#    only fires on that answer, never runs. Both exits are right for the inference path and wrong
#    for everything above it.
#
# 2. _se_input() (state-export.sh)
#    "{ read -r v < $f; } 2>/dev/null || v=" throws the value away when the file has no trailing
#    newline: read returns non-zero AT EOF with the data already in the variable. state-export owns
#    a reader for exactly this (_se_rd) and these calls do not use it, so a valid 9V / 1500mA
#    supply exports as null.
#
# 3. _ge_pause_cap_raw() (accd.sh)
#    Same EOF trap, worse consequence: both level reads are discarded, _best stays -1, the helper
#    answers "reached", and the restore hook ends a one-time charge that has not finished.
#
# Nothing here writes a sysfs node, touches the real config or signals the daemon.

ID=t-eof-readers-and-status-fallback
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=${BI:-$execDir/batt-interface.sh}
SE=${SE:-$execDir/state-export.sh}
AD=${AD:-$execDir/accd.sh}
AWKF=${AWKF:-$execDir/suites/xf.awk}
for f in "$BI" "$SE" "$AD" "$AWKF"; do
  [ -f "$f" ] || { no "missing $f"; fin; }
done

W=${TMPDIR:-/data/local/tmp}/t-eof-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null

xf(){ awk -v fn="$1" -f "$AWKF" "$2"; }
nonl(){ printf %s "$2" > "$1"; }
withnl(){ printf "%s\n" "$2" > "$1"; }

# $CUR, $FAC, $KST and $WA are read by the stubs below.
run_status(){
  ( eval "$(xf status "$BI")"
    current_now(){ echo "$CUR"; }
    current_factor(){ echo "$FAC"; }
    read_status(){ echo "$KST"; }
    idle_discharging(){ _status=INFERRED; }
    eq(){ case "$1" in $2) return 0;; esac; return 1; }
    calc(){ echo 0; }
    battStatusWorkaround=$WA
    unset battStatusOverride exitCode_ ampFactor
    ampFactor_=
    chargingSwitch=()
    _status=; _kstatus=
    status >/dev/null 2>&1; _rc=$?
    echo "$_status/$_rc" )
}

echo "--- 1. status() keeps the kernel verdict when current-based inference is off"

CUR=; FAC=; KST=Discharging; WA=false
r=$(run_status)
case "$r" in
  Discharging/0) ok "a garbage current still yields the kernel Discharging (rc=0)";;
  *) no "a garbage current lost the kernel verdict: got $r, want Discharging/0";;
esac

CUR=12345; FAC=; KST=Discharging; WA=false
r=$(run_status)
case "$r" in
  Discharging/0) ok "an unresolvable current unit still yields the kernel Discharging (rc=0)";;
  *) no "an unresolvable unit lost the kernel verdict: got $r, want Discharging/0";;
esac

CUR=; FAC=; KST=Charging; WA=false
r=$(run_status)
case "$r" in
  Charging/1) ok "a garbage current under a Charging kernel still returns rc=1";;
  *) no "unexpected result for a Charging kernel: got $r, want Charging/1";;
esac

CUR=0; FAC=; KST=Discharging; WA=false
r=$(run_status)
case "$r" in
  Discharging/0) ok "a zero current needs no unit and keeps the kernel verdict";;
  *) no "a zero current lost the kernel verdict: got $r";;
esac

# The inference path is the one that genuinely cannot run without a usable current. It must still
# refuse rather than infer from garbage.
CUR=; FAC=; KST=Discharging; WA=true
r=$(run_status)
case "$r" in
  Unknown/1) ok "with inference ON, a garbage current is still refused (Unknown/1)";;
  INFERRED/*) no "with inference ON, a garbage current reached idle_discharging: $r";;
  *) no "unexpected inference-on result: got $r, want Unknown/1";;
esac

CUR=-250000; FAC=1000000; KST=Discharging; WA=true
r=$(run_status)
case "$r" in
  INFERRED/1) ok "with inference ON and a usable current, idle_discharging still decides";;
  *) no "the inference path stopped running: got $r, want INFERRED/1";;
esac

echo "--- 2. _se_input() keeps a value that arrives without a trailing newline"

se_input(){
  ( ACC_PSY=$1; export ACC_PSY
    eval "$(xf _se_int "$SE")"; eval "$(xf _se_rd "$SE")"
    eval "$(xf _se_voltage_mv "$SE")"; eval "$(xf _se_input_ma "$SE")"
    eval "$(xf _se_icl_guard "$SE")"; eval "$(xf _se_input "$SE")"
    _se_input )
}

D=$W/psy; rm -rf $D; mkdir -p $D/usb
withnl $D/usb/online 1
nonl   $D/usb/voltage_now 9000000
nonl   $D/usb/current_now 1500000
r=$(se_input $D)
case "$r" in
  *voltageMv*9000*currentMa*1500*) ok "a newline-free 9V / 1500mA supply exports both fields";;
  *) no "newline-free input was discarded: $r";;
esac

withnl $D/usb/voltage_now 9000000
withnl $D/usb/current_now 1500000
r2=$(se_input $D)
[ ".$r" = ".$r2" ] && ok "newline and newline-free give the same export" \
  || no "the newline changes the answer: [$r] vs [$r2]"

nonl $D/usb/online 1
r3=$(se_input $D)
case "$r3" in
  *voltageMv*9000*) ok "a newline-free online flag still admits the supply";;
  *) no "a newline-free online flag dropped the supply: $r3";;
esac

echo "--- 3. _ge_pause_cap_raw() does not call an unfinished charge finished"

# ACC_PSY points at an empty tree so the phone's own battery/capacity cannot leak into the
# fixture and answer for the node under test.
pcr(){
  ( ACC_PSY=$W/empty-psy; export ACC_PSY
    eval "$(xf _ge_pause_cap_raw "$AD")"
    battCapacity=$1
    capacity=(5 101 70 80)
    if _ge_pause_cap_raw; then echo reached; else echo not-yet; fi )
}

C=$W/cap; rm -rf $C; mkdir -p $C; mkdir -p $W/empty-psy
nonl $C/capacity 60
r=$(pcr $C/capacity)
[ ".$r" = .not-yet ] && ok "a newline-free 60% against an 80% target is not reached" \
  || no "a newline-free 60% against an 80% target reported '$r'"

withnl $C/capacity 60
r=$(pcr $C/capacity)
[ ".$r" = .not-yet ] && ok "the same value with a newline agrees" \
  || no "with a newline it reported '$r'"

nonl $C/capacity 80
r=$(pcr $C/capacity)
[ ".$r" = .reached ] && ok "a newline-free 80% against an 80% target IS reached" \
  || no "a newline-free 80% reported '$r'"

rm -f $C/capacity
r=$(pcr $C/capacity)
[ ".$r" = .reached ] && ok "a genuinely unreadable gauge still reads as reached" \
  || no "an unreadable gauge reported '$r' - the fail-safe direction changed"

rm -rf "$W"
fin
