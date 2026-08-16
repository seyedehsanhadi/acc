#!/system/bin/sh
# t60 - the seven rc22 changes that had no test pointed at them.
#
# WHY THIS EXISTS
#   The mega2 coverage audit compares the rc21->rc22 changed-function list against every suite and
#   fails for any change nobody wrote a test for. On its first clean run it reported 34 of 41 covered
#   and named these seven. Each is a real behaviour change that shipped untested:
#
#     accd.sh:_cd_refresh        keeps Android's frozen battery level moving during a cooldown
#     accd.sh:_drop_blocked_sw   releases a blocked switch BEFORE abandoning it
#     accd.sh:ctrl_charging      stopped rebuilding the UI export every loop (69% of idle forks)
#     accd.sh:exxit              only resets Android overrides when something actually set them
#     acc.sh:exxit               the switch-test marker now records a pid, not just existence
#     misc-functions.sh:sdp      counts polarity flips where they actually happen
#     set-prop.sh:set_prop       parse-safe against a malformed config
#
#   _drop_blocked_sw deserves special note: it is the same failure class as the enable_charging
#   present-gate bug (t59). A switch blocked while it happened to be holding a cut would be dropped
#   and never written again, leaving the node latched with nothing left that would ever release it.
#
# NO HARDWARE. Source-level.

ID=t60
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
AS=$execDir/acc.sh
SP=$execDir/set-prop.sh
for _f in "$AD" "$MF" "$AS"; do [ -f "$_f" ] || { no "missing $(basename $_f)"; fin; }; done

# `^[ ]*` matches column-0 AND indented definitions; `^  *` silently requires a leading space.
body(){ sed -n "/^[ ]*$1()/,/^[ ]*}/p" "$2" | sed 's/^[[:space:]]*#.*//'; }

# ---- 1: _cd_refresh - the cooldown must not freeze the level it is watching -------------------------
# While ACC holds an Android battery override the reported level stops moving. During a sustained
# cooldown that means _lt_pause_cap stays true forever, the cycle never breaks, and the cell runs to
# 100% - a field-reported rc19 failure. _cd_refresh re-publishes the real kernel level as the cooldown
# sleeps, and must stand down when the capacity MASK owns the override instead.
_cd=$(body _cd_refresh "$AD")
if [ -n "$_cd" ]; then
  printf '%s' "$_cd" | grep -q 'capacity\[4\]' \
    && ok "_cd_refresh stands down when the capacity mask owns the override" \
    || no "_cd_refresh ignores the capacity mask - two writers would fight over Android's level"
  printf '%s' "$_cd" | grep -q 'batt_cap' \
    && ok "_cd_refresh republishes the real level" \
    || no "_cd_refresh does not read the real level"
  printf '%s' "$_cd" | grep -q 'dsys_batt set level' \
    && ok "and it pushes it back into Android" \
    || no "_cd_refresh never writes the level back"
  # It has to run DURING the sleep, not only before it: a single refresh then a full cooldown sleep
  # leaves the level stale for the whole interval, which is the bug.
  _mid=$(sed -n '/_cd_refresh$/,/esac/p' "$AD" | sed 's/^[[:space:]]*#.*//')
  printf '%s' "$_mid" | grep -q '_cdHalf / 2' \
    && ok "the cooldown sleep is split so the level is refreshed mid-interval" \
    || no "the cooldown sleeps in one block - the level goes stale for the whole interval"
else
  no "could not extract _cd_refresh"
fi

# ---- 2: _drop_blocked_sw - never abandon a switch while it is holding a cut ---------------------------
_db=$(body _drop_blocked_sw "$AD")
if [ -n "$_db" ]; then
  printf '%s' "$_db" | grep -q 'flip_sw on' \
    && ok "_drop_blocked_sw RELEASES the switch before abandoning it (same class as the t59 strand bug)" \
    || no "_drop_blocked_sw drops a blocked switch WITHOUT releasing it - if it was holding a cut, nothing will ever undo it"
  # The release must happen before the config is cleared, or the switch name is gone before the flip.
  _rel=$(printf '%s' "$_db" | grep -n 'flip_sw on' | head -1 | cut -d: -f1)
  _clr=$(printf '%s' "$_db" | grep -n 'charging_switch=' | head -1 | cut -d: -f1)
  if [ -n "$_rel" ] && [ -n "$_clr" ]; then
    [ "$_rel" -lt "$_clr" ] 2>/dev/null \
      && ok "and it releases BEFORE clearing the switch from config" \
      || no "the switch is cleared from config before the release - the release has nothing to act on"
  fi
  printf '%s' "$_db" | grep -q '_BLRELEASE' \
    && ok "the release is marked so the blacklist cannot veto this one final write" \
    || no "no release marker - the blacklist would refuse the very write that un-strands the phone"
  # A silently failed persist means every restart resurrects the blocked switch while the daemon
  # refuses to use it: a limit that is not enforced and never says so.
  printf '%s' "$_db" | grep -qE 'sed -i|--set charging_switch=' \
    && ok "it persists the change" \
    || no "the blocked switch is never persisted - it returns on every restart"
else
  no "could not extract _drop_blocked_sw"
fi

# ---- 3: ctrl_charging - the UI export must not be rebuilt every loop -----------------------------------
# Measured on a Mi A3 at idle: 1673 of 2428 forks per minute were this export, about half a core with
# the screen off. It is AccA's feed, not a safety function.
_cc=$(sed -n '/^  ctrl_charging()/,/^  }/p' "$AD" | sed 's/^[[:space:]]*#.*//')
if [ -n "$_cc" ]; then
  printf '%s' "$_cc" | grep -q '_wsLvl' \
    && ok "ctrl_charging gates the state export on something having actually moved" \
    || no "the state export is rebuilt unconditionally every loop - the idle fork storm is back"
  # The probes deciding whether to publish must not themselves fork, or nothing is saved.
  _probe=$(printf '%s' "$_cc" | sed -n '/_wsLvl=/,/_wsSt/p')
  printf '%s' "$_probe" | grep -q 'read -r' \
    && ok "and the probe uses read builtins, so no fork is spent deciding not to fork" \
    || no "the publish decision itself forks - it would cost what it saves"
  printf '%s' "$_cc" | grep -q 'SECONDS' \
    && ok "with a time bound so the export can never sit stale indefinitely" \
    || no "no time bound on the export - a quiet phone could show stale data forever"
else
  no "could not extract ctrl_charging"
fi

# ---- 4: accd exxit - only undo overrides something actually set ------------------------------------------
_ex=$(body exxit "$AD")
if [ -n "$_ex" ]; then
  printf '%s' "$_ex" | grep -q 'dsys-override' \
    && ok "accd exxit keys Android-override cleanup on the marker, not on an unconditional reset" \
    || no "accd exxit resets Android battery state unconditionally - it would clobber overrides it never set"
  printf '%s' "$_ex" | grep -q 'trap - EXIT' \
    && ok "and it disarms its own trap so the handler cannot re-enter" \
    || no "accd exxit does not disarm its trap"
else
  no "could not extract accd exxit"
fi

# ---- 5: acc.sh exxit and the switch-test marker ------------------------------------------------------------
# rc22 records the pid in .testingsw instead of merely creating it, so a marker left by a process that
# died can be told apart from a test that is genuinely running.
if grep -q 'echo $$ > $TMPDIR/.testingsw' "$AS" 2>/dev/null; then
  ok "the switch-test marker records its pid, so a stale one is detectable"
else
  no "the switch-test marker is a bare touch - a crashed test is indistinguishable from a running one"
fi
_ax=$(body exxit "$AS")
if [ -n "$_ax" ]; then
  printf '%s' "$_ax" | grep -q 'daemonWasUp' \
    && ok "acc.sh exxit restarts the daemon it stopped" \
    || no "acc.sh exxit does not restart the daemon - a switch test would leave the phone unmanaged"
  printf '%s' "$_ax" | grep -qE 'trap - EXIT' \
    && ok "and disarms its trap on the way out" \
    || no "acc.sh exxit does not disarm its trap"
else
  no "could not extract acc.sh exxit"
fi

# ---- 6: sdp - count the flip where it actually happens ------------------------------------------------------
# .dpol_unstable is what stops the re-latch loop on mode-dependent-sign hardware, but only the coulomb
# arbitration used to set it, and that needs a >=150uAh move. A pack at taper moves less than that, and
# taper is exactly when the sign oscillates. Measured on a Mi A3 at 74%: 15 latches, 0 flips counted.
_sdp=$(body sdp "$MF")
if [ -n "$_sdp" ]; then
  # No BRE alternation: neither phone's grep implements it, so 'a\|b' matches the LITERAL string and
  # this assertion reported a defect that was not there. One substring covers both spellings anyway.
  printf '%s' "$_sdp" | grep -q 'dpol_flips' \
    && ok "sdp counts a polarity change where the change is observed" \
    || no "sdp does not count flips - the instability guard can never arm at taper"
  printf '%s' "$_sdp" | grep -q 'dpol_unstable' \
    && ok "and arms the instability marker once it has seen enough" \
    || no "sdp never sets .dpol_unstable"
  printf '%s' "$_sdp" | grep -q 'TMPDIR/.dpol' \
    && ok "and persists the learned polarity to a file, not just a shell variable" \
    || no "polarity lives only in a variable - a cache republish would drop it (measured on a Pixel)"
else
  no "could not extract sdp"
fi

# ---- 7: set_prop must survive a malformed config -----------------------------------------------------------
if [ -f "$SP" ]; then
  _sp=$(body set_prop "$SP")
  if [ -n "$_sp" ]; then
    printf '%s' "$_sp" | grep -q 'defaultConfig' \
      && ok "set_prop loads defaults first, so a malformed config is repaired rather than fatal" \
      || no "set_prop does not preload defaults - a bad config line would kill the whole command"
  else
    no "could not extract set_prop"
  fi
else
  no "set-prop.sh not found"
fi

fin
