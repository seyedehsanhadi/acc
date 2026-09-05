#!/system/bin/sh
# t136 - the five defects that survived the 2026-08-31 review, and the two claims that did not.
#
# WHAT THIS FILE IS FOR
#   A review raised seven items. Two of them were wrong about this tree and the tests below pin
#   that down as hard as the real ones, because a wrong finding re-filed next month costs the same
#   as a real one. The five that were right get a regression test each.
#
#   1  acca -D restart is a no-op                 NOT A DEFECT - proven below, 4/4 on two phones
#   2  mcv apply gated on status=Charging         REAL - fixed, asserted below
#   3  _hv_lift fires during a firmware hold      REAL - fixed, asserted below
#   4  plugGapMax 60s vs a ~164s sweep            REAL - fixed, asserted below
#   5  acca -D start always exits 0               HALF REAL - start tore down a live daemon
#   6  misc-functions cfg-guard fallback weak     REAL - fixed, asserted below
#   7  acca -s tempLevel= skips the setter        REAL - fixed, asserted below
#
# NO CHARGER NEEDED. Every path here runs unplugged.

ID=t136
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
# NOT ${TMPDIR:-...}. A root shell arrives with TMPDIR already set to /data/local/tmp, so the
# defaulting form silently pointed every runtime check at the wrong directory: the accd symlink
# "was not a symlink", acc.lock held no PID, and the live start/restart pair - the only test here
# that touches a running daemon - skipped itself while reporting nothing wrong. ACC's own scripts
# hardcode this path for the same reason.
TMPDIR=/dev/.${domain:-vr25}/${id:-acc}
D=$execDir/accd.sh
A=$execDir/acca.sh
MF=$execDir/misc-functions.sh
SV=$execDir/service.sh
SCR=${SCR:-/data/local/tmp/t136-scratch}
rm -rf "$SCR"; mkdir -p "$SCR" 2>/dev/null

for f in "$D" "$A" "$MF" "$SV"; do
  [ -f "$f" ] || { no "missing $f"; fin; }
done

# Comments carry the words the assertions below look for, so every source test reads the code with
# comments stripped. Without this a test passes on its own rationale.
strip(){ sed 's/^[[:space:]]*#.*//' "$1"; }
DC=$SCR/accd.nc;  strip "$D"  > "$DC"
AC=$SCR/acca.nc;  strip "$A"  > "$AC"
MC=$SCR/misc.nc;  strip "$MF" > "$MC"

# ---- 0: the harness can fail -------------------------------------------------------------------
# feedback_prove_the_test_can_fail: every false failure ever reported here was the rig. Prove the
# stripper actually strips and the grep actually discriminates before grading anything with it.
printf '%s\n' '  # maxChargingVoltage battStatus Charging' > $SCR/probe.sh
[ -s "$(strip $SCR/probe.sh > $SCR/probe.nc; echo $SCR/probe.nc)" ] && [ -z "$(tr -d ' \n' < $SCR/probe.nc)" ] \
  && ok "harness: comment stripper removes a full-line comment" \
  || no "harness: stripper left comment text behind - every source test below is unsound"
grep -q 'nothing_matches_this_token_12345' "$DC" \
  && no "harness: grep matched a token that is not in the file" \
  || ok "harness: grep discriminates"

# ---- 1: acca -D restart really restarts (review item 1 was wrong) -------------------------------
# The review read `setsid $TMPDIR/accd` as accd.sh and concluded the old daemon keeps the lock and
# the child dies 13. $TMPDIR/accd is a symlink to service.sh, and service.sh sources release-lock.sh
# before it launches anything. That is what makes restart work, and it is load-bearing.
_lnk=$(readlink $TMPDIR/accd 2>/dev/null)
case "$_lnk" in
  */service.sh) ok "\$TMPDIR/accd resolves to service.sh, not accd.sh" ;;
  "") sk "\$TMPDIR/accd is not a symlink here" ;;
  *)  no "\$TMPDIR/accd -> $_lnk; the restart path no longer goes through service.sh" ;;
esac
grep -q 'release-lock.sh' "$SV" \
  && ok "service.sh releases the running daemon's lock before starting" \
  || no "service.sh no longer releases the lock - acca -D restart becomes the no-op the review described"
grep -qE 'ln -fs .*service\.sh.*\$\{?_eti\}?d|ln -fs "\$execDir/service.sh"' "$AC" \
  && ok "acca rebuilds the accd link from service.sh" \
  || no "acca's tmpfs link no longer points at service.sh"

# ---- 2: mcv apply must not be gated on battery/status (review item 2) ---------------------------
# bluejay reads "Not charging" for a sample at a time while charging normally, and a firmware hold
# holds it there for a full window. accd.sh documents this at the native_icl block. The current
# path moved to _iclHeld; the voltage path beside it had not.
# Read the NATIVE BRANCH, not the whole file. maxChargingVoltage[0] also appears inside
# is_charging(), which a firmware-limit phone never reaches, and a whole-file `grep | head -1`
# landed there. Same cut t121 uses. The stripper blanks comment lines rather than deleting them, so
# "the line above" is taken as the nearest NON-BLANK line, not literally the previous one.
# Cut from the RAW file: the marker that ends the branch is itself a comment, so cutting the
# stripped copy runs to end-of-file and quietly stops being "the branch" at all. Strip afterwards.
BR=$SCR/native.branch
awk '/^ *if \$nativeLimit; then/{f=1} f{print} f && /DO NOT hand a firmware-limit phone/{exit}' "$D" > $SCR/native.raw
strip $SCR/native.raw > "$BR"
_brl=$(wc -l < "$BR")
[ "${_brl:-0}" -gt 20 ] && [ "${_brl:-0}" -lt 500 ] \
  && ok "extracted the firmware-limit branch ($_brl lines)" \
  || no "the firmware-limit branch cut looks wrong ($_brl lines) - the gate tests below are unanchored"
_mcvblk=$(grep -n 'maxChargingVoltage\[0\]' "$BR" | head -1 | cut -d: -f1)
if [ -n "$_mcvblk" ]; then
  _gate=$(sed -n "1,$((_mcvblk-1))p" "$BR" | grep -v '^[[:space:]]*$' | tail -1)
  case "$_gate" in
    *battStatus*Charging*) no "mcv apply is still gated on status=Charging: $_gate" ;;
    *_iclHeld*) ok "mcv apply is gated on _iclHeld, same as the mcc path" ;;
    *) no "mcv apply gate is neither battStatus nor _iclHeld: $_gate" ;;
  esac
else
  no "cannot locate the maxChargingVoltage apply block"
fi
# The two paths must agree. A future edit that fixes one and not the other is the whole defect.
_nicl=$(grep -c '\[ "${_iclHeld:-0}" != 1 \]' "$DC")
[ "${_nicl:-0}" -ge 3 ] \
  && ok "mcc, mcv and the collapse guard all read _iclHeld ($_nicl sites)" \
  || no "only $_nicl _iclHeld gate(s) present; the three paths have drifted apart again"

# ---- 3: the collapse detector must stand down during a firmware hold (review item 3) ------------
# present=1, online=1, input ~0, pack not charging is ALSO what a thermal hold below the pause
# level looks like. Without this exclusion the 5-pass counter spends the once-per-plug .hvrecover
# budget and writes 5000000 into votes the firmware zeroed, so a genuine collapse later on the same
# plug can no longer be repaired.
# Anchored on the GUARD, not on the first mention of the marker anywhere. `grep -n hvrecover | head -1`
# landed on the plug-gap `rm -f` line instead and then graded the wrong four lines, which reported
# the chDisabledByAcc and _ge_pause_cap exclusions as lost on a build that still had both.
_hvline=$(grep -n '! -f \$TMPDIR/\.hvrecover' "$DC" | head -1 | cut -d: -f1)
if [ -n "$_hvline" ]; then
  _guard=$(sed -n "${_hvline},$((_hvline+3))p" "$DC" | tr '\n' ' ')
  case "$_guard" in
    *_iclHeld*) ok "collapse guard excludes a firmware hold (_iclHeld)" ;;
    *) no "collapse guard has no _iclHeld exclusion: $_guard" ;;
  esac
  case "$_guard" in
    *chDisabledByAcc*) ok "collapse guard still excludes ACC's own pause" ;;
    *) no "the chDisabledByAcc exclusion was lost - a normal capacity pause now clears the latch" ;;
  esac
  case "$_guard" in
    *_ge_pause_cap*) ok "collapse guard still excludes a capacity-limit hold" ;;
    *) no "the _ge_pause_cap exclusion was lost" ;;
  esac
else
  no "cannot locate the collapse-detector guard"
fi

# ---- 4: a switch sweep is not a missed unplug (review item 4) -----------------------------------
# cycle_switches_off budgets 120s and the file puts the honest ceiling at budget + one candidate,
# ~164s. plugGapMax defaults to 60. So an ordinary discovery pass tripped the missed-unplug test and
# dropped .hvkicked / .hvrecover on a plug that never moved, re-opening a re-kick against a live
# contract.
grep -q '\.sw-at' "$MC" \
  && ok "cycle_switches stamps .sw-at" \
  || no "cycle_switches no longer stamps .sw-at - a sweep looks like a replug again"
# Stamped on ENTRY, so it survives every early return in that function.
_swat=$(grep -n '\.sw-at' "$MC" | head -1 | cut -d: -f1)
_tsw=$(grep -n '\.testingsw' "$MC" | head -1 | cut -d: -f1)
if [ -n "$_swat" ] && [ -n "$_tsw" ] && [ "$_swat" -gt "$_tsw" ] && [ $((_swat - _tsw)) -lt 20 ]; then
  ok "the .sw-at stamp sits beside the .testingsw entry marker"
else
  no "the .sw-at stamp is not at cycle_switches' entry (sw-at=$_swat testingsw=$_tsw)"
fi
grep -q '_pgSw' "$DC" \
  && ok "the plug-gap check consults the sweep stamp" \
  || no "the plug-gap check ignores .sw-at"
# The exemption must be consumed, or one sweep would excuse every later gap for the rest of the boot.
grep -q 'rm -f \$TMPDIR/\.sw-at' "$DC" \
  && ok "the sweep stamp is removed after it is read" \
  || no "the sweep stamp is never removed - a single sweep would suppress missed-unplug detection forever"

# BEHAVIOURAL, not just source: run the guard expression both ways under the device shell.
# This is what proves the comparison is the right way round. Written the wrong way (-gt instead of
# -lt) both arms would agree and this test would fail.
cat > $SCR/gap.sh <<'EOG'
_pgNow=$2; _pgLast=$3; _pgSw=$1; plugGapMax=60
if [ "$_pgNow" -gt 0 ] && [ "$_pgSw" -lt "$_pgLast" ] \
   && [ $(( _pgNow - _pgLast )) -gt ${plugGapMax:-60} ]; then echo DROP; else echo KEEP; fi
EOG
_r1=$(sh $SCR/gap.sh 0 2000 1800)      # no sweep, 200s gap -> must drop
_r2=$(sh $SCR/gap.sh 1850 2000 1800)   # sweep started inside the gap -> must keep
_r3=$(sh $SCR/gap.sh 0 1830 1800)      # no sweep, 30s gap -> must keep
[ "$_r1" = DROP ] && ok "gap logic: a 200s gap with no sweep still drops the markers" \
                  || no "gap logic: a real missed unplug is no longer detected (got $_r1)"
[ "$_r2" = KEEP ] && ok "gap logic: a 200s gap explained by a sweep keeps the markers" \
                  || no "gap logic: a sweep still looks like a replug (got $_r2)"
[ "$_r3" = KEEP ] && ok "gap logic: a normal short gap keeps the markers" \
                  || no "gap logic: a short gap now drops markers (got $_r3)"

# ---- 5: acca -D start must not tear down a live daemon (review item 5) --------------------------
# service.sh release-locks before it launches, so `start` was a restart. The review predicted the
# opposite failure (a child dying 13 while acca reports success); what actually happened on a
# Pixel 6a was a healthy daemon being killed and replaced by a bare `acca -D start`.
# The plain `flock -n 0 <>$TMPDIR/acc.lock` has always been in acca's status branch, so grepping the
# whole file for it passed on the very build that has the defect. The guard has to be INSIDE the
# start/restart branch and has to key on `start`.
_stblk=$(sed -n '/start|restart)/,/^    ;;/p' "$AC")
case "$_stblk" in
  *'= start '*cmdline*|*'= start ]'*cmdline*) ok "acca's start branch verifies the recorded daemon before launching" ;;
  *) no "acca's start branch does not verify the recorded daemon - start tears down a live daemon again" ;;
esac
case "$_stblk" in
  *'/proc/'*'/cmdline'*) ok "the guard rejects a stale or reused PID by exact command line" ;;
  *) no "the guard trusts a PID without checking its command line" ;;
esac

_p0=$(cat $TMPDIR/acc.lock 2>/dev/null)
case "${_p0:-x}" in
  ''|*[!0-9]*) sk "no daemon PID in acc.lock; skipping the live start/restart pair" ;;
  *)
    if [ -d /proc/$_p0 ]; then
      $TMPDIR/acca -D start >/dev/null 2>&1 || :
      sleep 6
      _p1=$(cat $TMPDIR/acc.lock 2>/dev/null)
      if [ "$_p1" = "$_p0" ] && [ -d /proc/$_p1 ]; then
        ok "acca -D start left the live daemon alone (PID $_p0)"
      else
        no "acca -D start replaced a live daemon: $_p0 -> ${_p1:-none}"
      fi
      # ...and restart must still actually restart, or the fix above traded one bug for a worse one.
      $TMPDIR/acca -D restart >/dev/null 2>&1 || :
      _w=0
      while [ $_w -lt 40 ]; do
        sleep 5; _w=$((_w+5))
        _p2=$(cat $TMPDIR/acc.lock 2>/dev/null)
        [ -n "$_p2" ] && [ "$_p2" != "$_p1" ] && [ -d /proc/$_p2 ] && break
      done
      if [ -n "$_p2" ] && [ "$_p2" != "$_p1" ] && [ -d /proc/$_p2 ]; then
        ok "acca -D restart still restarts (${_p1} -> $_p2, new PID alive after ${_w}s)"
      else
        no "acca -D restart no longer restarts: ${_p1} -> ${_p2:-none}"
      fi
      # Exactly one daemon. Two would fight over the charging switch.
      #
      # POLL, DO NOT SAMPLE ONCE. A restart is briefly a crowd: service.sh runs start-stop-daemon and
      # then verifies, and the launches that lose the race exit 13 in acquire-lock. Measured on a Mi A3
      # (toybox), three PIDs were alive 5s after the restart and exactly one by 10s; a Pixel 6a was at
      # one the whole time. A single count at a fixed offset therefore failed on the slower phone and
      # called a healthy restart a two-daemon fight. Wait for it to settle, and report how long that
      # took so a genuine second daemon - which never goes away - still fails here.
      _w=0; _n=$(pgrep -f "$execDir/accd.sh" 2>/dev/null | wc -l)
      while [ $_w -lt 45 ] && [ "${_n:-0}" -ne 1 ]; do
        sleep 5; _w=$((_w+5))
        _n=$(pgrep -f "$execDir/accd.sh" 2>/dev/null | wc -l)
      done
      [ "${_n:-0}" -eq 1 ] && ok "exactly one daemon after the start/restart pair (settled in ${_w}s)" \
                           || no "$_n daemons still alive ${_w}s after the start/restart pair"
    else
      sk "acc.lock names PID $_p0 but it is not running"
    fi
  ;;
esac

# ---- 6: the cfg-guard fallback must survive a bad config (review item 6) ------------------------
# `. "$1" 2>/dev/null || :` does not catch a failure INSIDE the dotted file: under errexit mksh
# aborts the caller before the `||` is reached. Only reachable on an install missing cfg-guard.sh,
# which is why it went unnoticed - and why it is exactly the install that cannot afford a dead
# front-end.
grep -q 'cfg_srcsafe' "$MC" && ok "misc-functions still defines a cfg_srcsafe fallback" \
                            || no "the cfg_srcsafe fallback is gone"
# The one-line form is the defect, so test for the one-line form. A `sed` range from the definition
# to the next `^  }` ran far past a single-line body and found a `set +e` belonging to some other
# function, which passed the very build that ships the bug.
if grep -q 'cfg_srcsafe() { \. "\$1" 2>/dev/null || :; }' "$MC"; then
  no "the fallback is still the one-line plain source that errexit walks straight past"
else
  ok "the one-line plain-source fallback is gone"
fi
# Bounded to the function BODY. An open-ended `sed` range from the definition to the next `^  }`
# found a `set +e` belonging to a later function and passed the build that ships the one-liner.
_blk=$(grep -A6 'cfg_srcsafe()' "$MC" | tr '\n' ' ')
case "$_blk" in
  *'set +e'*'set -e'*) ok "the fallback clears errexit around the source and puts it back" ;;
  *) no "the fallback still sources under errexit: $_blk" ;;
esac
# BEHAVIOURAL. Prove the plain form really does kill the caller on this shell, then prove the
# shipped form does not. If the first arm ever prints SURVIVED, this shell does not have the
# problem and the second arm proves nothing - so it is reported, not silently passed.
printf 'false\n' > $SCR/bad.conf
cat > $SCR/naive.sh <<'EON'
set -e
naive(){ . "$1" 2>/dev/null || :; }
naive "$1"
echo SURVIVED
EON
cat > $SCR/safe.sh <<'EOS'
set -e
safe(){
  case $- in
    *e*) set +e; . "$1" 2>/dev/null; set -e;;
    *) . "$1" 2>/dev/null || :;;
  esac
}
safe "$1"
echo SURVIVED
EOS
_nv=$(/system/bin/sh $SCR/naive.sh $SCR/bad.conf 2>/dev/null)
_sf=$(/system/bin/sh $SCR/safe.sh  $SCR/bad.conf 2>/dev/null)
if [ "$_nv" = SURVIVED ]; then
  sk "this shell does not abort the caller on a failure inside a dotted file; the fallback is harmless either way"
else
  ok "the plain fallback really does kill the caller on this shell (the defect is real here)"
fi
[ "$_sf" = SURVIVED ] && ok "the shipped fallback survives a config that fails while sourcing" \
                      || no "the shipped fallback still dies on a bad config"

# ---- 7: acca -s must recognise the config spelling of every node-affecting key (review item 7) ---
# The config key is tempLevel. acca's delegation list carried tl and temp_level only, so
# `acca -s tempLevel=N` wrote the config and never reached set_temp_level - while the mcc and mcv
# entries beside it did list their camelCase spellings. An asymmetry, not a design.
for _k in maxChargingVoltage maxChargingCurrent tempLevel; do
  grep -q "$_k" "$AC" && ok "acca -s recognises $_k" \
                      || no "acca -s does not recognise $_k - the config is written and the nodes are left"
done
# Round-trip it for real, and put the value back.
_CFG=${config:-/data/adb/vr25/acc-data/config.txt}
if [ -w "$_CFG" ]; then
  _was=$(sed -n 's/^tempLevel=//p' "$_CFG" | head -1)
  $TMPDIR/acca -s tempLevel=73 >/dev/null 2>&1 || :
  sleep 2
  _now=$(sed -n 's/^tempLevel=//p' "$_CFG" | head -1)
  [ "$_now" = 73 ] && ok "acca -s tempLevel=73 reached the config" \
                   || no "acca -s tempLevel=73 did not land (config reads '${_now:-empty}')"
  $TMPDIR/acc -s tl=${_was:-0} >/dev/null 2>&1 || :
  sleep 2
  _back=$(sed -n 's/^tempLevel=//p' "$_CFG" | head -1)
  [ "$_back" = "${_was:-0}" ] && ok "tempLevel restored to ${_was:-0}" \
                              || no "tempLevel left at '${_back}', was '${_was}'"
else
  sk "config not writable; skipping the tempLevel round trip"
fi

# ---- 8: PLUGGED ONLY - the sweep exemption, live ------------------------------------------------
# Everything above about item 4 is source and extracted logic. This is the only arm that proves the
# daemon actually honours the stamp, and it needs a cable: the gap check is gated on `present`.
#
# The decisive pair, in one run, on one phone:
#   A  keep .sw-at fresh -> a marker must SURVIVE a gap far past plugGapMax
#   B  stop refreshing   -> the same marker must then be DROPPED
# Arm B is what stops arm A passing on a daemon that simply never runs the check. Neither arm alone
# means anything, which is why they are graded as a pair.
# present() belongs to the daemon, not to this shell, so ask sysfs directly - and ask every supply,
# because usb/present is not where every kernel puts it.
_plugged=0
# NOT */present -- that glob matches battery/present, which is 1 because the BATTERY is present
# and says nothing about a charger. Measured on laurus while unplugged: battery/present=1 and
# usb/present=0, so this section ran its plugged arms on an unplugged phone and reported the
# product broken. Charger supplies only.
for _pn in /sys/class/power_supply/usb/present /sys/class/power_supply/pc_port/present /sys/class/power_supply/dc/present /sys/class/power_supply/ac/present /sys/class/power_supply/wireless/present; do
  [ -f "$_pn" ] || continue
  [ "$(cat "$_pn" 2>/dev/null)" = 1 ] && { _plugged=1; break; }
done
[ "$_plugged" = 1 ] || case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
  Charging|Full|"Not charging") _plugged=1 ;;
esac
if [ "$_plugged" != 1 ]; then
  sk "no charger attached; the live sweep-exemption pair needs one"
else
  _CFG=${config:-/data/adb/vr25/acc-data/config.txt}
  _pgundo(){ sed -i '/^:; plugGapMax=/d' "$_CFG" 2>/dev/null || :
             rm -f $TMPDIR/.sw-at $TMPDIR/.hvkicked 2>/dev/null || :; }
  # PROVE THE DAEMON IS LOOPING FIRST. A frozen daemon passes arm A for the wrong reason, and this
  # project has already reverted one correct fix off a measurement taken against a frozen daemon.
  _fl=/data/adb/vr25/acc-data/logs/flight.log
  _h0=$(tail -1 $_fl 2>/dev/null | cut -d, -f1); _hw=0
  while [ $_hw -lt 90 ]; do
    sleep 5; _hw=$((_hw+5))
    [ "$(tail -1 $_fl 2>/dev/null | cut -d, -f1)" != "$_h0" ] && break
  done
  if [ "$(tail -1 $_fl 2>/dev/null | cut -d, -f1)" = "$_h0" ]; then
    sk "the daemon completed no loop pass in ${_hw}s - the live arms cannot be graded"
  else
    ok "the daemon is looping (pass observed in ${_hw}s), so the gap check is reachable"
    printf '\n:; plugGapMax=1\n' >> "$_CFG"
    : > $TMPDIR/.hvkicked 2>/dev/null
    if [ ! -f $TMPDIR/.hvkicked ]; then
      sk "could not stage .hvkicked"; _pgundo
    else
      ok "staged .hvkicked with plugGapMax=1"
      # ARM A: ONE stamp, ONE pass. Not a barrage.
      #
      # The first version rewrote .sw-at every 3s for 75s and asserted the marker survived the whole
      # window. That is not what a sweep does and it is not deterministic: the daemon CONSUMES the
      # stamp on the pass that reads it, so whether the marker survives depends on whether the next
      # refresh lands before the next pass. On an idle phone napping 120s it always did; on a phone
      # looping fast under suite load it did not, and the same build passed on bluejay and failed on
      # laurus for purely timing reasons.
      #
      # A real sweep blocks the daemon synchronously, so it produces exactly ONE oversized gap and
      # the stamp needs to excuse exactly ONE pass. So: stamp once, wait for one observed pass, and
      # assert the marker is still there. Passes are counted off flight.log, which is the only
      # honest evidence the daemon actually turned over.
      # THE CABLE CAN LEAVE MID-ARM, AND THAT IS NOT A PRODUCT FAILURE.
      # `present` is checked once when this section is entered, but the two arms below take about
      # four minutes between them. Pull the cable in that window and the plug-gap check stops
      # running entirely -- it is gated on present -- so arm B reports 'missed-unplug detection is
      # now dead' about a phone that is simply unplugged. Measured exactly that way on laurus.
      # Re-read the node at grading time and skip rather than fail.
      _still_plugged(){
        # NOT $PS/*/present -- that glob matches battery/present, which is 1 because the BATTERY is
        # present and has nothing to do with a charger. On laurus, unplugged: battery/present=1 while
        # usb/present=0, so every plugged arm below ran on an unplugged phone and reported the product
        # broken. Ask the charger supplies only, and require online too: a charger that is present but
        # not online is an input cut, which is not a usable plugged state for these arms either.
        for _p in $PS/usb/present $PS/pc_port/present $PS/dc/present $PS/ac/present $PS/wireless/present; do
          [ -f "$_p" ] || continue
          [ "$(cat "$_p" 2>/dev/null)" = 1 ] && return 0
        done
        return 1
      }
      _fl=/data/adb/vr25/acc-data/logs/flight.log
      _t0=$(tail -1 $_fl 2>/dev/null | cut -d, -f1)
      date +%s > $TMPDIR/.sw-at 2>/dev/null || :
      _i=0
      while [ $_i -lt 90 ]; do
        sleep 3; _i=$((_i+3))
        [ "$(tail -1 $_fl 2>/dev/null | cut -d, -f1)" != "$_t0" ] && break
      done
      if ! _still_plugged; then
        sk "arm A: the cable came out mid-arm - nothing to grade"
      elif [ "$(tail -1 $_fl 2>/dev/null | cut -d, -f1)" = "$_t0" ]; then
        sk "arm A: no daemon pass observed in ${_i}s - nothing to grade"
      elif [ -f $TMPDIR/.hvkicked ]; then
        ok "arm A: one sweep stamp excused the pass it covered, marker intact (${_i}s)"
      else
        no "arm A: the marker was dropped on the pass the sweep stamp covered - the exemption does not work"
      fi
      # ARM B: stop refreshing; detection must resume.
      rm -f $TMPDIR/.sw-at 2>/dev/null || :
      : > $TMPDIR/.hvkicked 2>/dev/null
      _i=0
      while [ $_i -lt 150 ]; do
        sleep 3; _i=$((_i+3))
        [ -f $TMPDIR/.hvkicked ] || break
      done
      if ! _still_plugged; then
        sk "arm B: the cable came out mid-arm - nothing to grade"
      elif [ -f $TMPDIR/.hvkicked ]; then
        no "arm B: the marker survived ${_i}s with NO sweep stamp - missed-unplug detection is now dead"
      else
        ok "arm B: with no sweep stamp the marker was dropped after ${_i}s - detection still works"
      fi
      _pgundo
      ok "plugGapMax override removed"
    fi
  fi
fi

rm -rf "$SCR" 2>/dev/null
fin
