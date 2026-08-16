#!/system/bin/sh
# t56 - the fast-charge contract: don't tear it down, and don't make it worse trying to fix it.
#
# THE INCIDENT THIS ENCODES
#   A Mi A3 started a test run on a 7.7V QuickCharge 3 contract at 2000mA and finished it on a 5V
#   floor at 0mA, discharging on a live cable. Three separate defects lined up:
#
#   1. fast_session() - the guard that exists to stop ACC poking a fragile fast-charge handshake -
#      only looked for VENDOR session nodes (quick_charge_type, fast_chg_type, VOOC...). The A3 has
#      none of them, so the cached list was empty, the loop ran zero times, and the guard reported
#      "no fast session" while a live QC3 contract was running. Cap cycling then tore it down.
#
#   2. rekick_usb's ICL verification answered a zero limit by re-running AICL. AICL MEASURES what
#      the source can supply; it does not repair one. Re-running it on a degraded supply just
#      re-measures a degraded supply, and each pass ratchets the estimate down. Traced at 10s
#      intervals: 900000 -> 800000 -> 700000 -> 500000 under rerun_aicl, then 300000 -> 100000 -> 0
#      under apsd_rerun, where it stayed through a second AICL pass and an `acc -e`. Writing the
#      recorded default back ended it instantly: 0 -> 1700000, charging at 1.35A.
#
#   3. The megatest blamed ACC for it. The phone read 0mA with the ACC DAEMON STOPPED, which no
#      amount of ACC misbehaviour can cause, and the assertion still said "the phone was left cut".
#
# NO HARDWARE. Source-level, so it runs anywhere.

ID=t56
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }

# Comments stripped: they quote the very constructs being checked for.
# `^  *` means ONE space then zero-or-more, so it silently requires a leading space and misses
# every function defined at column 0 - which is why this extracted fast_session (indented in
# accd.sh) and returned nothing for rekick_usb (column 0 in misc-functions.sh). `[ ]*` is
# zero-or-more and matches both.
body(){ sed -n "/^[ ]*$1()/,/^[ ]*}/p" "$2" | sed 's/^[[:space:]]*#.*//'; }

# ---- 1: the guard must not depend on vendor nodes existing ----------------------------------------
_fs=$(body fast_session "$AD")
[ -n "$_fs" ] || { no "could not extract fast_session"; fin; }

printf '%s' "$_fs" | grep -q '6000000' \
  && ok "fast_session treats a negotiated voltage above the 5V floor as a live session" \
  || no "fast_session has no voltage test - it is blind on every phone with no vendor node (e.g. Mi A3)"

printf '%s' "$_fs" | grep -q 'voltage_now' \
  && ok "and it reads the supply voltage to decide that" \
  || no "fast_session never reads a supply voltage"

# Order matters: the voltage test has to run even when the vendor list is empty, which means it
# cannot sit inside or after a loop over that list.
_vline=$(printf '%s' "$_fs" | grep -n '6000000' | head -1 | cut -d: -f1)
_nline=$(printf '%s' "$_fs" | grep -n '_fcNodes' | head -1 | cut -d: -f1)
if [ -n "$_vline" ] && [ -n "$_nline" ]; then
  [ "$_vline" -lt "$_nline" ] 2>/dev/null \
    && ok "the voltage test runs BEFORE the vendor-node loop, so an empty list cannot skip it" \
    || no "the voltage test is after the vendor loop - an empty node list would bypass it"
else
  no "could not locate both the voltage test and the vendor loop"
fi

# The escape hatches must survive: a tester needs to A/B this without reflashing.
printf '%s' "$_fs" | grep -q 'fcguard-off' \
  && ok "the guard can still be disabled for A/B testing" \
  || no "the .fcguard-off escape hatch is gone"
printf '%s' "$_fs" | grep -q 'fcguard-force' \
  && ok "and forced on for bench testing" \
  || no "the .fcguard-force hook is gone"

# ---- 2: recovery must restore, not re-measure ------------------------------------------------------
_rk=$(body rekick_usb "$MF")
[ -n "$_rk" ] || { no "could not extract rekick_usb"; fin; }

# The zero-ICL branch must NOT answer with another AICL run.
_zero=$(printf '%s' "$_rk" | sed -n '/still 0/,$p')
if [ -n "$_zero" ]; then
  printf '%s' "$_zero" | grep -q 'rerun_aicl' \
    && no "the zero-ICL remedy still re-runs AICL - measured to ratchet the limit DOWN, not restore it" \
    || ok "the zero-ICL remedy does not re-run AICL"
  printf '%s' "$_zero" | grep -q 'ch-curr-ctrl-files' \
    && ok "it restores the recorded default instead" \
    || no "the zero-ICL remedy does not restore a recorded default"
else
  no "could not find the zero-ICL branch in rekick_usb"
fi

# It must still only touch input-negotiation nodes, and only at zero. A phone charging fine must
# never have a snapshot replayed onto it.
printf '%s' "$_rk" | grep -q 'current_max::' \
  && ok "the restore is scoped to input-negotiation nodes" \
  || no "the restore is not scoped - it could replay a snapshot onto any control file"

# ---- 2b: and it must not fire at all on a healthy contract ------------------------------------------
# The repair itself is the hazard. apsd_rerun renegotiates, and on QC/PD that means the 5V floor
# until a physical replug. Repairing a charger that is not broken can only lose.
# Match on what the guard DOES, not on one phrasing of its log line. The message changed from
# "contract is healthy" to "negotiated contract" when the input-limit condition was dropped, and
# this assertion went on asserting the old wording - failing against a build that was correct.
printf '%s' "$_rk" | grep -qE 'negotiated contract|contract is healthy'   && ok "rekick_usb refuses to run when a high-voltage contract is already working"   || no "rekick_usb still fires on a healthy contract - it can drop any QC/PD phone to 5V"

# Anchor on the WRITE, not on any mention of the word. Stripping comments is not enough: the
# guard's own log message contains "apsd_rerun would drop it to 5V until replug", so a range
# ending at the first occurrence stopped inside a string literal, before the check it was looking
# for. Fifth time a test in this set has matched prose about a defect instead of the defect - the
# loop header `for _rn in */apsd_rerun` is the write itself and cannot appear in a message.
_pre=$(printf '%s' "$_rk" | sed -n '1,/for _rn in \*\/apsd_rerun/p')
printf '%s' "$_pre" | grep -q '6000000'   && ok "and that check runs BEFORE apsd_rerun is written"   || no "the health check does not precede the apsd_rerun write - it would fire first and check after"

# The guard must key on VOLTAGE ONLY. Requiring a healthy input limit as well is the hole the
# first version leaked through: ACC's own cap drives the limit to 500mA, the guard then read the
# contract as unhealthy, and it permitted the very re-kick that killed it. Ledger-proven on a Mi
# A3 - refused twice at 7851mV and 6005mV, let two through while a 700mA cap was applied, supply
# ended at 4675mV.
_g=$(printf '%s' "$_rk" | sed -n '/negotiated contract/,+0p;/contract is healthy/,+0p')
printf '%s' "$_rk" | sed -n '/6000000/,/fi/p' | grep -q 'current_max'   && no "the guard still tests the input limit - ACC's own cap will make it permit a re-kick"   || ok "the guard keys on voltage alone, so an applied cap cannot make it permit a re-kick"

# The pre-existing guards are load-bearing and must not have been traded away for the fix.
printf '%s' "$_rk" | grep -q 'rekick-off' \
  && ok "acc -sk off is still honoured" \
  || no "the re-kick no longer honours acc -sk off"
printf '%s' "$_rk" | grep -q '_rekick_due' \
  && ok "the rate limit is still in place" \
  || no "the re-kick rate limit is gone"

# ---- 2d: the latch, not an instantaneous reading ---------------------------------------------------
# A high-voltage supply sags under load. Measured on a Mi A3, a QC3 contract delivering ~2A read
# 6433-6712mV, and when it dipped under 6V the guard concluded no contract existed and permitted a
# re-kick that made the drop permanent. A contract belongs to the PLUG, so it must be latched for
# the life of that plug rather than re-derived from whatever the line reads this millisecond.
printf '%s' "$_rk" | grep -q 'hvcontract'   && ok "the guard consults a per-plug latch, so a load sag cannot open the door"   || no "the guard still decides from an instantaneous voltage - a sag will permit a re-kick"

_ad=$(sed 's/^[[:space:]]*#.*//' "$AD")
printf '%s' "$_ad" | grep -q 'rm -f $TMPDIR/.hvcontract'   && ok "and the latch is cleared when the cable comes out"   || no "the latch is never cleared - it would survive a charger swap"
printf '%s' "$_ad" | grep -q 'hvcontract'   && ok "the daemon sets the latch while a high voltage is present"   || no "nothing sets the latch"

# ---- 2c: aim high at plug time -------------------------------------------------------------------
# The other half of the rule. A re-detection is free before a contract exists and destructive after,
# so the one moment worth spending it is the plug itself: that is when 9V instead of 5V is still
# winnable. A kernel that negotiates lazily, or that settled low because a stale input cap was still
# throttling the line when detection ran, is recoverable here and nowhere else.
# Comments STRIPPED, like every other extraction here. The block's own commentary explains what
# apsd_rerun does, so an ordering check that greps the raw text finds the word in the prose above
# the code and concludes the order is wrong. That is the fourth time in this suite set that a test
# read a defect's description and reported it as the defect.
_pl=$(sed -n '/AIM FOR THE BEST CONTRACT/,/^      fi$/p' "$AD" | sed 's/^[[:space:]]*#.*//')
if [ -n "$_pl" ]; then
  printf '%s' "$_pl" | grep -q 'freshPlug'     && ok "the plug-time attempt is gated on a real plug transition"     || no "the plug-time attempt is not gated on freshPlug - it could fire every loop"
  printf '%s' "$_pl" | grep -q 'rekick-off'     && ok "and it honours acc -sk off"     || no "the plug-time attempt ignores acc -sk off"
  printf '%s' "$_pl" | grep -q '6000000'     && ok "it only acts when the supply is on the 5V floor, leaving a good contract alone"     || no "no floor test - it would re-detect a contract that is already good"

  # Order is the whole trick: releasing the input ceiling BEFORE detection is what stops the
  # charger learning that our own cap is all this phone wants.
  _rel=$(printf '%s' "$_pl" | grep -n 'current_max' | head -1 | cut -d: -f1)
  _det=$(printf '%s' "$_pl" | grep -n 'apsd_rerun' | head -1 | cut -d: -f1)
  if [ -n "$_rel" ] && [ -n "$_det" ]; then
    [ "$_rel" -lt "$_det" ] 2>/dev/null       && ok "the input ceiling is released BEFORE re-detection, so AICL measures the charger not our cap"       || no "re-detection runs before the ceiling is released - the charger would settle at our cap"
  else
    no "could not confirm the release-then-detect order"
  fi
else
  no "the plug-time contract attempt is missing entirely"
fi

# ---- 3: the test must name the right component -----------------------------------------------------
MT=${MEGATEST:-$execDir/suites/megatest.sh}
if [ -f "$MT" ]; then
  _d=$(sed -n '/T-DISC-recovers/,/^    fi$/p' "$MT")
  printf '%s' "$_d" | grep -q 'a dead charger, not a cut' \
    && ok "T-DISCOVERY distinguishes a collapsed supply from a cut switch" \
    || no "T-DISCOVERY still blames ACC when the charger is the thing that died"
  printf '%s' "$_d" | grep -q 'input_suspend=1 with a live supply' \
    && ok "and it reports a genuine cut as a cut" \
    || no "T-DISCOVERY cannot report a genuine cut distinctly"
else
  echo "  note  megatest.sh not present; skipping the harness assertions"
fi

fin
