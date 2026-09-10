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

echo "--- 3. the PATH wrapper must run something"
if [ -f "$CZ" ]; then
  if grep -q 'exec \. /data/adb' "$CZ"; then
    no "the wrapper's fallback branch is 'exec . <file>', which is not a runnable command"
  else
    ok "the wrapper's fallback branch execs the script directly"
  fi
  # and the generated wrapper must still prefer the tmpfs launcher when it exists
  grep -q 'exec /dev/' "$CZ" && ok "the wrapper still prefers /dev/<name> once the module is live" \
    || no "the wrapper no longer prefers the tmpfs launcher"
else
  ok "no customize.sh in this tree, section skipped"
  ok "no customize.sh in this tree, section skipped"
fi

rm -rf "$W"
fin
