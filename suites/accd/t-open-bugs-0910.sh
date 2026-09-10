#!/system/bin/sh
# The remaining open items from the 2026-09-10 review, each isolated and executed.
#
# 1. The daemon's coulomb anchor ($TMPDIR/.cc_then) re-stamped on every pass, so on a fuel gauge
#    that steps charge_counter coarsely the delta was always 0 and this arbiter could never rule.
#    Identical trap to the one _se_ccdir carried on the export side.
# 2. A phone with no usable current reading must still get the kernel's own status word when
#    current-based inference is switched off, the way rc24 did.
# 3. The PATH wrapper's fallback branch is `exec . <file>`, which is not a runnable command.
#
# Nothing here writes a sysfs node, touches the live config or signals the daemon.

ID=t-open-bugs-0910
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=${BI:-$execDir/batt-interface.sh}
CZ=${CZ:-$execDir/../customize.sh}
[ -f "$BI" ] || { no "missing $BI"; fin; }

W=${TMPDIR_T:-/data/local/tmp}/t-open-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null

echo "--- 1. the daemon's coulomb anchor must survive a counter that has not moved"
# idle_discharging is long and pulls in the whole reader set, so the anchor rule is exercised
# through the block itself: stamp an anchor, run the same decision the daemon runs, and look at
# what the anchor says afterwards.
anchor(){
  # $1 = counter now, $2 = anchor value, $3 = anchor age seconds. Echoes "kept" or "restamped".
  ( T=$W/a; rm -rf $T; mkdir -p $T
    now=$(date +%s)
    echo "$2 $((now - $3))" > $T/.cc_then
    _cc=$1; _ccnow=$now; _ccp=; _ccts=
    read -r _ccp _ccts < $T/.cc_then
    TMPDIR=$T
    # the shipped rule, cut out of the file rather than restated here
    eval "$(/system/bin/sed -n '/KEEP THE ANCHOR UNTIL THE COUNTER ACTUALLY MOVES/,/^    fi$/p' "$BI" | /system/bin/sed 's/^    //')" 2>/dev/null || :
    read -r a b < $T/.cc_then
    [ ".$b" = ".$((now - $3))" ] && echo kept || echo restamped )
}
# An arm with no such rule at all re-stamps unconditionally; say so rather than reading its
# untouched fixture as a pass.
if ! grep -q "KEEP THE ANCHOR UNTIL THE COUNTER ACTUALLY MOVES" "$BI"; then
  no "this tree re-stamps the coulomb anchor every pass - a coarse gauge can never rule"
  no "this tree has no anchor-retention rule"
  no "this tree has no anchor-retention rule"
else
r=$(anchor 1868032 1868032 12)
[ ".$r" = .kept ] && ok "a 12s anchor survives a poll where the counter did not move" \
  || no "the anchor was re-stamped by a no-change poll, so the window can never grow"
r=$(anchor 1873032 1868032 12)
[ ".$r" = .restamped ] && ok "a counter that moved re-stamps, so a fine gauge is unaffected" \
  || no "a moved counter did not re-stamp: $r"
r=$(anchor 1868032 1868032 200)
[ ".$r" = .restamped ] && ok "an anchor past the 90s ceiling is retaken" \
  || no "a stale anchor was held past its own ceiling: $r"
fi

echo "--- 2. no usable current must still yield the kernel's verdict when inference is off"
run_status(){
  ( eval "$(/system/bin/sed -n '/^status() {/,/^}/p' "$BI")"
    current_now(){ echo "$CUR"; }
    current_factor(){ echo ""; }
    read_status(){ echo "$KST"; }
    idle_discharging(){ _status=INFERRED; }
    eq(){ case "$1" in $2) return 0;; esac; return 1; }
    calc(){ echo 0; }
    battStatusWorkaround=$WA
    unset battStatusOverride exitCode_ ampFactor
    ampFactor_=; chargingSwitch=(); _status=; _kstatus=
    status >/dev/null 2>&1; _rc=$?
    echo "$_status/$_rc" )
}
CUR=; KST=Discharging; WA=false
r=$(run_status)
[ ".$r" = .Discharging/0 ] && ok "a sensorless phone still reports the kernel's Discharging" \
  || no "a sensorless phone lost the kernel verdict: $r"
CUR=; KST=Charging; WA=false
r=$(run_status)
[ ".$r" = .Charging/1 ] && ok "and its Charging, with the matching exit status" \
  || no "a sensorless phone lost the kernel Charging: $r"
CUR=; KST=Discharging; WA=true
r=$(run_status)
[ ".$r" = .Unknown/1 ] && ok "with inference ON the unusable reading is still refused" \
  || no "an unusable reading was inferred from: $r"

echo "--- 3. the PATH wrapper must run something, in EVERY installer copy"
# customize.sh, install.sh and META-INF/com/google/android/update-binary are the same installer
# under three names - byte-identical in this project - and each writes the wrapper. Correcting one
# leaves the other two shipping the broken branch, and which of them runs depends on how the module
# was flashed (app vs recovery).
ROOT=${ROOT:-$(dirname "$CZ")}
_inst=0; _bad=0
for _c in "$ROOT/customize.sh" "$ROOT/install.sh" "$ROOT/META-INF/com/google/android/update-binary"; do
  [ -f "$_c" ] || continue
  _inst=$((_inst + 1))
  grep -q 'exec \. /data/adb' "$_c" && { _bad=$((_bad + 1)); echo "      stale: ${_c#$ROOT/}"; }
done
if [ "$_inst" -eq 0 ]; then
  ok "no installer in this tree, section skipped"
  ok "no installer in this tree, section skipped"
else
  [ "$_bad" -eq 0 ] && ok "all $_inst installer copies exec the script directly" \
    || no "$_bad of $_inst installer copies still carry 'exec . <file>'"
  grep -q 'exec /dev/' "$ROOT/customize.sh" 2>/dev/null \
    && ok "the wrapper still prefers /dev/<name> once the module is live" \
    || no "the wrapper no longer prefers the tmpfs launcher"
fi

echo "--- 4. a uevent without a trailing newline keeps its last line"
# The kernel normally terminates these, but a copy taken by a collector, an overlay, or a vendor
# node that does not, drops whichever key sits last - and on a Fairphone 5 that is the charge
# counter, so the reader falls back to a frozen attribute of 2667961 instead of the live 749841.
UE=$W/ue; rm -rf $UE; mkdir -p $UE
printf 'POWER_SUPPLY_NAME=battery\nPOWER_SUPPLY_CAPACITY=21\nPOWER_SUPPLY_CHARGE_COUNTER=749841' > $UE/uevent
r=$( eval "$(/system/bin/sed -n '/^_cc_uevent() {/,/^}/p' "$BI")"
     _cc_uevent "$UE/"; echo "${_ccue:-empty}" )
[ ".$r" = .749841 ] && ok "the last key survives a file with no trailing newline" \
  || no "the last key was dropped: got $r, want 749841"
# and the ordinary terminated file must be unchanged
printf 'POWER_SUPPLY_NAME=battery\nPOWER_SUPPLY_CHARGE_COUNTER=749841\nPOWER_SUPPLY_CAPACITY=21\n' > $UE/uevent
r=$( eval "$(/system/bin/sed -n '/^_cc_uevent() {/,/^}/p' "$BI")"
     _cc_uevent "$UE/"; echo "${_ccue:-empty}" )
[ ".$r" = .749841 ] && ok "a normally terminated uevent is unaffected" \
  || no "a terminated uevent broke: got $r"

echo "--- 5. acc -i keeps an input current that arrives without a trailing newline"
BIF=${BIF:-$(dirname "$BI")/batt-info.sh}
SEF=${SEF:-$(dirname "$BI")/state-export.sh}
if [ -f "$BIF" ] && [ -f "$SEF" ]; then
  # The supply loop is not cleanly extractable, so this grades the reader it uses. A bare
  # `read ... && break` walks past a value that arrived at EOF; _se_rd keeps it.
  grep -q 'read -r psaRaw <' "$BIF" \
    && no "batt-info still reads the input node with a bare read, which drops a value at EOF" \
    || ok "batt-info reads the input node through the EOF-safe reader"
  # ...and that reader must actually keep such a value.
  N=$W/psy; rm -rf $N; mkdir -p $N
  printf '%s' 1500000 > $N/input_current_now
  r=$( eval "$(/system/bin/sed -n '/^_se_rd() {/,/^}/p' "$SEF")"
       _se_rd "$N/input_current_now"; echo "${_seraw:-empty}" )
  [ ".$r" = .1500000 ] && ok "the reader keeps a newline-free 1.5 A reading" \
    || no "the reader dropped it: got $r"
else
  ok "no batt-info.sh/state-export.sh in this tree, section skipped"
  ok "section skipped"
fi

echo "--- 6. the failure message must not name a cause it cannot know"
SPF=${SPF:-$(dirname "$BI")/set-prop.sh}
if [ -f "$SPF" ]; then
  # setRc carries a refused voltage as well as a failed publish, so a message that says only "the
  # configuration could not be written" is wrong whenever the config WAS written and one setting
  # was refused - which is what an unsupported voltage node produces.
  # -E: toybox grep has no \| alternation in a basic expression.
  _msg=$(grep -nE 'could not be (written|applied)|NOT saved|could not be' "$SPF" | head -1)
  case "$_msg" in
    *"could not be written"*) no "the message blames the config write for any non-zero verdict: $_msg";;
    "") no "no failure message found in set-prop.sh";;
    *) ok "the failure message covers applying as well as saving";;
  esac
else
  ok "no set-prop.sh in this tree, section skipped"
fi

rm -rf "$W"
fin
