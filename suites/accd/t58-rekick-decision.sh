#!/system/bin/sh
# t58 - the re-kick DECISION, exercised directly, one case at a time.
#
# WHY THIS EXISTS, AND WHY IT SHOULD HAVE EXISTED FIRST
#   The guard in rekick_usb has now been wrong three times, in three different ways, and every one
#   reached a user's phone before it was noticed:
#
#     v1  looked only for VENDOR session nodes. A Mi A3 has none, so the list was empty, the loop
#         ran zero times, and the guard reported "no fast session" while a live 7.7V QuickCharge 3
#         contract was running. Cap cycling then destroyed it.
#     v2  required vbus >= 6V AND input limit > 600mA. ACC'S OWN CAP drives the limit to 500mA, so
#         during a cap cycle the guard read its own cap as a sick charger and permitted the re-kick
#         at precisely the worst moment. Ledger: two leaked through, supply ended at 4675mV.
#     v3  required vbus >= 6V, read instantaneously. A QC3 contract SAGS UNDER LOAD - measured
#         6433-6712mV while delivering ~2A - and the moment it dipped the guard permitted a re-kick
#         that made the drop permanent. Ledger: apsd_rerun at 07:28:59, supply then 4860mV/400mA.
#
#   All three passed the behavioural section that supposedly covers this (T-REKICK). It passes when
#   the RATE LIMIT suppresses a re-kick, which is a different reason, so it cannot distinguish a
#   working guard from a broken one. Three bad versions shipped behind a green tick.
#
#   The missing piece was never more integration testing. It was a test that asks the guard the
#   question directly - "given this exact state, do you fire?" - for every state that matters, in
#   seconds, against a synthetic sysfs tree where nothing real can be harmed.
#
# HOW
#   rekick_usb is extracted from the shipped source and evaluated here with its collaborators
#   stubbed: _rekick_due (the rate limit), _wlog (the ledger), and a fake power-supply tree. The
#   assertion is the RETURN VALUE plus whether apsd_rerun was actually written - a guard that
#   returns 1 but writes the node first would still destroy the contract.
#
# NO HARDWARE. Nothing outside the scratch directory is touched.

ID=t58
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }

W=${TMPDIR:-/data/local/tmp}/.t58
rm -rf "$W" 2>/dev/null

# The function under test, lifted verbatim from what ships.
_body=$(sed -n '/^rekick_usb()/,/^}/p' "$MF")
[ -n "$_body" ] || { no "could not extract rekick_usb"; fin; }

# ---- the rig -------------------------------------------------------------------------------------
# Each case gets a clean synthetic tree. Fires are recorded by the fake nodes themselves, so the
# check is "did the write happen", not "did the function say it would not".
setup() {  # $1 vbus (empty = node absent), $2 icl, $3 latch(yes/no), $4 rekick-off(yes/no)
  rm -rf "$W" 2>/dev/null
  mkdir -p "$W/ps/usb" "$W/ps/battery" "$W/tmp" "$W/data" 2>/dev/null
  [ -n "${1-}" ] && printf '%s\n' "$1" > "$W/ps/usb/voltage_now"
  printf '%s\n' "${2:-2000000}" > "$W/ps/usb/current_max"
  : > "$W/ps/usb/apsd_rerun"
  : > "$W/ps/battery/rerun_aicl"
  printf 'usb/current_max::v000::1800000\n' > "$W/tmp/ch-curr-ctrl-files"
  [ "${3-}" = yes ] && : > "$W/tmp/.hvcontract"
  [ "${4-}" = yes ] && : > "$W/data/.rekick-off"
  return 0
}

# Returns: "<rc> <fired>" where fired is 1 if apsd_rerun was written.
run_guard() {  # $1 = _rekick_due result (0 = due, 1 = too soon)
  ( cd "$W/ps" 2>/dev/null || exit 9
    TMPDIR="$W/tmp"
    dataDir="$W/data"
    _rekick_due(){ return ${1:-0}; }
    eval "_rekick_due(){ return $1; }"
    _wlog(){ :; }
    eval "$_body"
    rekick_usb t58 >/dev/null 2>&1
    _rc=$?
    _fired=0
    [ -s "$W/ps/usb/apsd_rerun" ] && _fired=1
    echo "$_rc $_fired"
  )
}

# $1 label, $2 expected rc, $3 expected fired, $4.. setup args, then due
case_is() {
  _lbl=$1; _erc=$2; _efi=$3; shift 3
  setup "$@"
  _got=$(run_guard "${_due:-0}")
  _grc=${_got%% *}; _gfi=${_got##* }
  if [ "$_grc" = "$_erc" ] && [ "$_gfi" = "$_efi" ]; then
    ok "$_lbl"
  else
    no "$_lbl  (expected rc=$_erc fired=$_efi, got rc=$_grc fired=$_gfi)"
  fi
}

# ---- 1: the three historical failures, as explicit regression cases --------------------------------
# Each of these is a state a shipped version got WRONG. If any starts passing a re-kick again, that
# version's bug is back.

_due=0
# v3's killer: the latch is set and the line has sagged well below the threshold under load.
case_is "SAG: latch set, vbus 5800mV (loaded QC3) -> refuse, nothing written" \
        1 0 5800000 2000000 yes no

# v3's killer at its worst: sagged all the way to the floor, latch still set.
case_is "SAG: latch set, vbus at the 5V floor -> refuse (the contract is still ours to lose)" \
        1 0 5000000 2000000 yes no

# v2's killer: a healthy high-voltage contract while ACC'S OWN CAP holds the input limit at 500mA.
case_is "CAP: vbus 9V but input limit 500mA (our cap) -> refuse, the cap is not a sick charger" \
        1 0 9000000 500000 no no

# v2 again, with the latch already set.
case_is "CAP: latch set and input limit 500mA -> refuse" \
        1 0 9000000 500000 yes no

# ---- 2: the guard must still permit a genuine repair ------------------------------------------------
# The whole point of rekick_usb is a stalled charger. A guard that never fires is not safe, it is
# broken in the other direction: the phone sits on a live cable not charging.

case_is "STALL: no latch, 5V supply, limit collapsed to 0 -> PERMIT the repair" \
        0 1 5000000 0 no no

case_is "STALL: no latch, 5V supply -> PERMIT" \
        0 1 5000000 1500000 no no

# ---- 3: the latch is created when a contract is seen -------------------------------------------------
setup 9000000 2000000 no no
_got=$(run_guard 0)
if [ -f "$W/tmp/.hvcontract" ]; then
  ok "seeing a 9V contract with no latch CREATES the latch, so a later sag cannot open the door"
else
  no "a high-voltage contract did not create the latch - the next sag will permit a re-kick"
fi
[ "${_got%% *}" = 1 ] && ok "and that same call refuses" || no "it saw 9V and still permitted a re-kick"

# ---- 4: the pre-existing gates still come first ------------------------------------------------------
# These are load-bearing and must not have been traded away while fixing the contract logic.

case_is "OFF: acc -sk off refuses even with no latch and a dead 5V supply" \
        1 0 5000000 0 no yes

_due=1
case_is "RATE: too soon refuses even with no latch and a dead supply" \
        1 0 5000000 0 no no
_due=0

# ---- 5: boundary and malformed input ------------------------------------------------------------------
# The threshold is 6000000. A 5V supply drifting under load (5.0-5.2V measured) must never trip it,
# and the lowest real negotiated step is 9V, so the exact edge matters less than the direction of
# failure: an unreadable value must PERMIT (fail toward repairing a phone that will not charge).

case_is "EDGE: exactly 6000000 counts as a contract -> refuse" \
        1 0 6000000 2000000 no no

case_is "EDGE: 5999999 is below the bar -> permit" \
        0 1 5999999 2000000 no no

case_is "MALFORMED: garbage in voltage_now -> permit (fail toward repair)" \
        0 1 "not-a-number" 2000000 no no

case_is "ABSENT: no voltage_now node at all -> permit (fail toward repair)" \
        0 1 "" 2000000 no no

case_is "ZERO: voltage_now reads 0 -> permit" \
        0 1 0 2000000 no no

# A latch must win even when the voltage node is unreadable: the latch is the stronger statement.
case_is "LATCH beats an unreadable voltage -> refuse" \
        1 0 "" 2000000 yes no

# ---- 6: the holes an adversarial audit found after the first four versions -------------------------
# Four independent lenses attacked the design; each claimed hole was refuted by a separate reviewer
# before being accepted. These are the ones that survived.

# A sag is not one sample. The fallback must sample repeatedly, because the single window where it
# runs (daemon stopped, or mid aim-high poll) is exactly where a wrong answer is unrecoverable.
_fb=$(sed -n '/NO LATCH YET/,/^  fi$/p' "$MF" | sed 's/^[[:space:]]*#.*//')
printf '%s' "$_fb" | grep -q 'while'   && ok "the no-latch fallback SAMPLES rather than glancing once (the v3 failure mode)"   || no "the fallback still takes a single instantaneous read - one sag permits a contract-killing re-kick"

# The latch must not be inherited across a daemon restart: tmpfs outlives `acca -D stop`.
_ad=$(sed 's/^[[:space:]]*#.*//' "$execDir/accd.sh")
printf '%s' "$_ad" | grep -q 'rm -f $TMPDIR/.hvcontract'   && ok "the latch is cleared somewhere (unplug and/or daemon start)"   || no "nothing clears the latch"
_clears=$(printf '%s' "$_ad" | grep -c 'rm -f $TMPDIR/.hvcontract')
[ "${_clears:-0}" -ge 2 ] 2>/dev/null   && ok "cleared in BOTH places - on unplug and at daemon start, so a stale latch cannot be inherited"   || no "the latch is cleared in only ${_clears:-0} place; a latch set by a previous daemon run survives a stop/start and blocks every repair"

# The plug-time aim-high block writes apsd_rerun directly, bypassing rekick_usb entirely. It must
# be gated on the latch AND on a physically observed unplug - `freshPlug` alone is driven by
# `online`, which an input-cut switch zeroes on every capacity pause, so the block would re-run
# charger detection on a live contract at every resume.
_pl=$(sed -n '/AIM FOR THE BEST CONTRACT/,/^      fi$/p' "$execDir/accd.sh" | sed 's/^[[:space:]]*#.*//')
printf '%s' "$_pl" | grep -q 'hvcontract'   && ok "the aim-high block consults the latch before re-detecting"   || no "the aim-high block ignores the latch - it is the v3 bug in a second code path"
printf '%s' "$_pl" | grep -q 'sawUnplug'   && ok "and it requires a physically observed unplug, not just an online transition"   || no "aim-high is gated on freshPlug alone; an input-cut pause/resume re-triggers it mid-plug"
printf '%s' "$_ad" | grep -q 'sawUnplug=true'   && ok "sawUnplug is set from present(), the physical fact"   || no "sawUnplug is never set from present()"

rm -rf "$W" 2>/dev/null
fin
