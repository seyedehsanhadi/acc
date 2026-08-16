#!/system/bin/sh
# t71 - acc-switch-scan.sh: the restore filter and the pause-level lookup.
#
# ONE DEFECT, silent, found by reading what the code actually matches against.
#
#   restore_on FILTERED THE WHOLE LINE. A switch line is a sequence of "<node> <on> <off>" triples,
#   and grouped lines are ordinary: the tester emits a Pixel's four current paths on one line, and a
#   OnePlus pairs charging_enabled with op_disable_charge. The filter that skips charger-negotiation
#   nodes was a case against "$1" -- the entire line -- so ONE current_max anywhere on a line skipped
#   the restore of every other node on it. A line that cuts with input_suspend and also touches
#   usb/current_max was therefore never released: the phone stays not charging until a reboot, which
#   is precisely what restore_all_on exists to prevent.
#
#   (A second change in this file, resolving the scan's pause level from the config, was written
#   and REVERTED the same day; see the note at the bottom of this test and in the script.)
#
# NO HARDWARE. Both functions are executed against fake files.

ID=t71
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SS=$execDir/acc-switch-scan.sh
[ -f "$SS" ] || SS=/data/local/tmp/acc-switch-scan.sh
[ -f "$SS" ] || { no "acc-switch-scan.sh not found"; fin; }

W=${TMPDIR:-/data/local/tmp}/t71.$$
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null
trap 'rm -rf "$W" 2>/dev/null' EXIT

RFN=$(sed -n '/^restore_on() *{/,/^}/p' "$SS")
[ -n "$RFN" ] || { no "restore_on() not found"; fin; }
SFN=$(sed -n '/^restore_on_safe() *{/,/^}/p' "$SS")
[ -n "$SFN" ] || { no "restore_on_safe() not found - the sweep and the per-candidate restore must be separate"; fin; }

# TWO functions, deliberately different, and conflating them was itself a bug (rc23b).
#
#   restore_on       per candidate. Replays the candidate's OWN line, whose ON field is the high
#                    release value. Restores EVERYTHING, including current nodes: write_off had just
#                    set them to 0 and nothing else puts them back.
#   restore_on_safe  the belt-and-braces sweep over the whole switch FILE, which may contain a
#                    probe-time snapshot line. Skips current nodes so a stale negotiated value is
#                    never replayed - but per NODE, so a grouped line keeps its other nodes.
ron() {  # $1 line -> the node list _write was asked to restore
  ( eval "$RFN"
    _write(){ shift; printf '%s\n' "$*"; }
    restore_on "$1" ) 2>/dev/null
}
rsafe() {
  ( eval "$SFN"
    _write(){ shift; printf '%s\n' "$*"; }
    restore_on_safe "$1" ) 2>/dev/null
}

SUS=/sys/class/power_supply/battery/input_suspend
CMX=/sys/class/power_supply/usb/current_max
OPD=/sys/class/power_supply/battery/op_disable_charge

# ---- 1: THE BUG - a grouped line must still release its cutting switch ---------------------------
_r=$(ron "$SUS 0 1 $CMX 5000000 0")
case "$_r" in
  *"$SUS 0 1"*) ok "a grouped line still releases input_suspend (the shipped bug: it did not)" ;;
  *)            no "input_suspend was NOT restored on a line that also carries current_max: [$_r] -- phone left cut until reboot" ;;
esac

# ---- 1b: rc23b - the per-candidate restore must PUT CURRENT NODES BACK ----------------------------
# write_off wrote 0 to them. If restore_on skips them they stay at 0: the phone cannot draw current,
# and every candidate after this one is measured on a phone that cannot charge. Confirmed on a Mi A3,
# where a scan left main/current_max, usb/current_max, pc_port/current_max, constant_charge_current,
# constant_charge_current_max and charge_control_limit all reading 0.
case "$_r" in
  *"$CMX 5000000 0"*) ok "the candidate's own current node is released high (5000000), not left at 0" ;;
  *)                  no "current_max was NOT restored by the per-candidate path: [$_r] -- it stays 0 and contaminates every later candidate" ;;
esac
_r=$(ron "/sys/class/power_supply/main/current_max 3000000 0")
case "$_r" in
  *"main/current_max 3000000 0"*) ok "a current-node candidate tested on its own is released too" ;;
  *)                              no "a lone current-node candidate was left at its off value: [$_r]" ;;
esac

# ---- 2: the SWEEP still refuses to replay a snapshot ----------------------------------------------
_r=$(rsafe "$CMX 5000000 0 /sys/class/power_supply/main/input_current_limit 3000000 0")
[ -z "$(printf '%s' "$_r" | tr -d ' \n')" ] \
  && ok "the sweep calls _write with nothing for a line of only negotiation nodes" \
  || no "the sweep replayed a negotiation line: [$_r]"

# and the sweep's skip is PER NODE, so a grouped line keeps its cutting switch
_r=$(rsafe "$SUS 0 1 $CMX 5000000 0")
case "$_r" in
  *"$SUS 0 1"*) ok "the sweep keeps input_suspend on a line that also carries current_max" ;;
  *)            no "the sweep dropped the whole line: [$_r] -- the phone stays cut" ;;
esac
case "$_r" in
  *current_max*) no "the sweep replayed current_max; a snapshot line would pin a stale value" ;;
  *)             ok "the sweep still excludes current nodes" ;;
esac

# ---- 3: an ordinary two-node group restores both ---------------------------------------------------
_r=$(ron "$SUS 0 1 $OPD 0 1")
{ case "$_r" in *"$SUS 0 1"*) true;; *) false;; esac; } && { case "$_r" in *"$OPD 0 1"*) true;; *) false;; esac; } \
  && ok "an ordinary grouped switch restores every node on the line" \
  || no "a grouped switch lost a node: [$_r]"

# ---- 4: a single plain switch is untouched ----------------------------------------------------------
_r=$(ron "$SUS 0 1")
case "$_r" in
  *"$SUS 0 1"*) ok "the ordinary single-switch case is unchanged" ;;
  *)            no "a plain switch stopped being restored: [$_r]" ;;
esac

# ---- 5: an empty line is harmless --------------------------------------------------------------------
_r=$(ron "")
[ -z "$(printf '%s' "$_r" | tr -d ' \n')" ] && ok "an empty line writes nothing" || no "an empty line produced [$_r]"
_r=$(rsafe "")
[ -z "$(printf '%s' "$_r" | tr -d ' \n')" ] && ok "an empty line writes nothing in the sweep either" || no "the sweep produced [$_r] for an empty line"

# ---- 6: the baseline guard between candidates ---------------------------------------------------------
# The restore is only half the guarantee. If a node refuses the write, or the charger needs a moment
# after being cut, the NEXT candidate's baseline is read on a phone that is not charging and every
# verdict from there on is noise. The scan has to notice and say so.
grep -q '^baseline_ok()' "$SS" \
  && ok "there is an explicit baseline check between candidates" \
  || no "no baseline_ok - a contaminated run still reports confident results"
grep -q 'contaminated=1' "$SS" \
  && ok "a failed baseline is recorded, not ignored" \
  || no "nothing records a contaminated run"
grep -q 'RESULTS-UNTRUSTWORTHY' "$SS" \
  && ok "and the user is told, on ONE greppable line, that the results are unreliable" \
  || no "the run goes quiet about results it knows are unreliable"

# rc23b: --apply must refuse to lock a switch chosen from a contaminated ranking. Observed live on a
# Pixel 6a: four drain-type switches cut passthrough, charging stayed down, and candidates 10-21 were
# every one of them measured on a phone that was not charging. Any of those could have ranked "best",
# and --apply would have locked it.
grep -q 'contaminated:-0' "$SS" \
  && ok "--apply refuses to auto-lock when the run flagged itself unreliable" \
  || no "--apply will lock a switch picked from data the scan itself called untrustworthy"
_c1=$(grep -n 'contaminated:-0' "$SS" | head -1 | cut -d: -f1)
_c2=$(grep -n 'anyResume" = 1' "$SS" | head -1 | cut -d: -f1)
{ [ -n "$_c1" ] && [ -n "$_c2" ] && [ "$_c1" -lt "$_c2" ]; } 2>/dev/null \
  && ok "  and it is checked FIRST, so the resume-verified branch cannot bypass it ($_c1 < $_c2)" \
  || no "  the contaminated check at ${_c1:-?} runs after the apply branch at ${_c2:-?}"

# ---- the pause level is deliberately NOT read from the config ------------------------------------
# A change to resolve pcap from capacity field 4 was written and reverted on 2026-08-11. The grep
# below matching nothing, and the fallback to the LIVE battery level winning, is the CORRECT
# behaviour: pcap is the OFF value written to a limit node during a scan, so it has to stop charging
# at the level the pack is actually at. Resolved to the configured pause (76 while scanning at 55%)
# the firmware would not stop and the scan would read a working level switch as "no effect".
grep -q '_pcap_from_config' "$SS"   && no "pcap is being resolved from the configured pause again - that makes a scan below the pause read a working level switch as 'no effect'"   || ok "pcap still resolves to the live battery level, which is what makes the scan observable"
grep -q 'PCAP=$(cat battery/capacity' "$SS"   && ok "the live-level fallback is present"   || no "the live-level fallback is gone - the token has nothing sane to resolve to"

fin
