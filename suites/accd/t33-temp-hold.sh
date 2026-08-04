#!/system/bin/sh
# t33 - a thermal pause must survive the three paths that re-enable charging on capacity alone.
#
# Three places turn charging back on after deciding only that the level sits below pause_capacity:
#
#   exit trap      accd.sh  `if _ge_pause_cap; then :; else enable_charging; fi`
#   init release   accd.sh  `level < pause` -> sweep every cut node permissive
#   generic_rearm  accd.sh  `freshPlug && _lt_pause_cap && online` -> enable_charging
#
# The shared reasoning is spelled out in the init block: "it can never fight a legitimate pause and
# can never overcharge: at or above the limit this does nothing at all." True for a CAPACITY pause,
# blind to every other one. On a pack over max_temp with the level anywhere under pause_capacity --
# the ordinary case on a hot phone -- all three re-enable a charge the thermal pause is holding off.
#
# Field report, sweet: repeated re-enables at 40.4-41.4C against max_temp 40, one logged as
#   init release /sys/.../input_suspend <- 0 (left cut, level 64 < pause 75)
# a decision with no temperature term in it at all.
#
# The fix is one predicate, _temp_hold, gating all three. Its direction matters as much as its
# existence: it must block ONLY on a positive over-temperature reading. Blocking on a sensor that
# cannot be read would resurrect the stranded-cut bug the init block exists to fix (switch left cut,
# charger offline, phone discharging on a live cable across reboots), so every doubt has to fall
# through to "release".
#
# Pure unit test: the decisions are reproduced against fake values. No node is written.

ID=t33
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/accd.sh
[ -f "$SRC" ] || { no "accd.sh not found"; fin; }

# ---- source level --------------------------------------------------------------------------------
grep -q '_temp_hold() {' "$SRC" \
  && ok "_temp_hold is defined" \
  || no "_temp_hold is gone - nothing guards the three re-enable paths"

grep -q '_ge_pause_cap 2>/dev/null || _temp_hold' "$SRC" \
  && ok "exit trap consults it" \
  || no "the exit trap still resumes on capacity alone"

grep -q '\[ "\$_icl" -lt "\$_icp" \] 2>/dev/null && ! _temp_hold' "$SRC" \
  && ok "init release consults it" \
  || no "the init release still sweeps cut nodes on capacity alone"

grep -q '! _temp_hold || return 0' "$SRC" \
  && ok "generic_rearm consults it" \
  || no "generic_rearm still re-arms on a fresh plug regardless of temperature"

# native_unlatch MUST consult it. Its pulse writes charge_stop_level=100 -- no limit at all --
# and then sleeps a full loopDelay before sync_native_limit pulls it back, so on a pack over
# max_temp that is a ~10s window of unrestricted charging, repeated every loop while the level sits
# below resume. Measured on a Pixel 6a at 38C against a 37C limit: charge_stop_level read 100 and
# the pack took 913mA for a whole 20s window.
#
# A first attempt at this guard was reverted after an A/B seemed to show it latching the limit. That
# A/B was confounded by the daemon being frozen in the generic switch prober; nothing was updating
# the node in either build. sync_native_limit runs unconditionally BEFORE native_unlatch every loop,
# so the guard cannot prevent a raised limit from being applied.
sed -n '/native_unlatch() {/,/^  }/p' "$SRC" | sed 's/#.*//' | grep -q '_temp_hold'   && ok "native_unlatch consults it, so a hot pack is never pulsed to stop_level=100"   || no "native_unlatch pulses charge_stop_level=100 on a hot pack - the limit is off for a loopDelay"

# It must read the node itself. temp_now() coerces an unreadable sensor to 250 (25.0C), which would
# fabricate a hold on any phone whose max_temp is set below 25 and block a release forever.
sed -n '/_temp_hold() {/,/^  }/p' "$SRC" | sed 's/#.*//' | grep -q 'temp_now' \
  && no "_temp_hold goes through temp_now - its 250 fallback invents a hold from a dead sensor" \
  || ok "_temp_hold reads the node directly, so an unreadable sensor cannot fabricate a hold"

# ---- behavioural ---------------------------------------------------------------------------------
# $1 = raw deci-C on the node ('' = unreadable), $2 = configured max_temp. 0 means "hold".
hold() {
  _th=$1; _mt=$2
  case "${_mt:-x}" in ''|*[!0-9]*) return 1;; esac
  case "${_th:-x}" in ''|*[!0-9-]*) return 1;; esac
  [ "$_th" -ge $(( _mt * 10 )) ] 2>/dev/null
}
# the guarded release decisions, as the product now makes them
init_release() { _lvl=$1; _pause=$2; [ "$_lvl" -lt "$_pause" ] && ! hold "$3" "$4"; }
exit_resume()  { _lvl=$1; _pause=$2; [ "$_lvl" -lt "$_pause" ] && ! hold "$3" "$4"; }
rearm()        { _lvl=$1; _pause=$2; [ "$_lvl" -lt "$_pause" ] && ! hold "$3" "$4"; }

# The field case: 40.4C against max_temp 40, level 64 under pause 75.
init_release 64 75 404 40 && no "init release still fires at 40.4C vs max_temp 40 (the sweet bug)" \
                          || ok "init release blocked at 40.4C vs max_temp 40"
exit_resume  64 75 404 40 && no "exit trap still resumes at 40.4C vs max_temp 40" \
                          || ok "exit trap blocked at 40.4C vs max_temp 40"
rearm        64 75 404 40 && no "generic_rearm still re-arms at 40.4C vs max_temp 40" \
                          || ok "generic_rearm blocked at 40.4C vs max_temp 40"
init_release 64 75 414 40 && no "init release fires at 41.4C, the top of the reported range" \
                          || ok "init release blocked at 41.4C"

# The boundary. mt_reached uses >=, so this must too, or the two disagree by a tenth of a degree.
hold 400 40 && ok "exactly max_temp holds (>=, matching mt_reached)" || no "40.0C vs max_temp 40 did not hold"
hold 399 40 && no "39.9C held - stricter than mt_reached" || ok "just under max_temp does not hold"

# What the block exists for must still work: a cool pack releases a switch a previous run left cut.
init_release 64 75 300 40 || no "a COOL pack no longer releases a left-cut switch - stranding is back"
init_release 64 75 300 40 && ok "cool pack (30C vs max_temp 40) still releases a left-cut switch"
init_release 20 75 250 45 && ok "cool pack at low level still releases" || no "low-level cool release broken"

# Every doubt must fall through to "release", never to "hold".
hold ''    40 && no "an UNREADABLE sensor fabricated a hold - this strands a phone not charging" \
              || ok "unreadable sensor -> no hold (release still allowed)"
hold abc   40 && no "a garbage sensor value fabricated a hold" || ok "garbage sensor value -> no hold"
hold 404   '' && no "an unset max_temp fabricated a hold" || ok "unset max_temp -> no hold"
hold 404  abc && no "a garbage max_temp fabricated a hold" || ok "garbage max_temp -> no hold"
init_release 64 75 '' 40 && ok "init release still works with an unreadable sensor (anti-stranding)" \
                         || no "an unreadable sensor blocked the release - the stranded-cut bug returns"

# A cold pack must never read as hot.
hold -50 40 && no "a pack at -5C was treated as over max_temp" || ok "sub-zero pack -> no hold"

# The capacity gate still owns its own half: at or above pause, nothing releases whatever the temp.
init_release 80 75 300 40 && no "released at level 80 with pause 75 - the capacity gate broke" \
                          || ok "at/above pause_capacity nothing releases, cool pack included"
init_release 80 75 404 40 && no "released at level 80 while also over temp" \
                          || ok "at/above pause_capacity nothing releases, hot pack included"

# ---- rc22: the cooldown cycle's re-enable ------------------------------------------------------
# The cooldown loop tests the temperature BEFORE its off-phase, then sleeps a whole cooldownRatio
# and re-enables charging on the other side without asking again. A pack that crossed max_temp
# during that wait would get charging back for another full cycle. Same shape as the three paths
# that did let charging resume over the limit.
sed -n '/# cooldown cycle/,/^        done/p' "$SRC" | grep -q '_temp_hold || enable_charging'   && ok "the cooldown re-enable re-checks temperature after its sleep"   || no "the cooldown re-enable hands charging back without re-checking temperature"

# It must remain a re-enable, not a pause: guarding it must not stop the cycle from resuming a cool
# pack, which is the whole point of a duty cycle.
_cd=$(sed -n '/# cooldown cycle/,/^        done/p' "$SRC")
printf '%s' "$_cd" | grep -q 'enable_charging'   && ok "the cooldown cycle still re-enables a cool pack"   || no "the cooldown cycle no longer re-enables at all - the duty cycle is broken"

# ---- rc22: the MAIN resume path -----------------------------------------------------------------
# Its own condition reads the temperature, but a sleep runs between that read and enable_charging
# whenever a force-off marker had to be cleared. Every re-enable in the daemon must act on a fresh
# reading; a guard on three paths out of four is what made the original report hard to find.
grep -q '_temp_hold || enable_charging' "$SRC"   && ok "the main resume re-checks temperature after its sleep"   || no "the main resume enables charging on a pre-sleep temperature reading"

# Count the GUARDED sites rather than trying to parse the unguarded ones. Six call sites exist:
#   330  exit trap                       guarded
#   383  switch probe at init            disable_charging then enable_charging -- not a resume
#   923  cooldown cycle                  guarded
#   1058 idle-avoidance                  enable then immediately disable, net off -- not a resume
#   1072 main resume                     guarded
#   1633 generic_rearm                   guarded at function entry
# Every path that RESUMES charging consults the temperature; the two that do not are a probe and a
# cycle that ends disabled.
_g=$(grep -c '_temp_hold' "$SRC")
[ "${_g:-0}" -ge 6 ]   && ok "the temperature guard is referenced at $_g places (>=6: definition plus every resume path)"   || no "only $_g references to the temperature guard - a resume path has lost it"

sed -n '/generic_rearm() {/,/^  }/p' "$SRC" | grep -q '_temp_hold'   && ok "generic_rearm is guarded at entry" || no "generic_rearm lost its guard"

fin
