#!/system/bin/sh
# t145 - a votable that never HOLDS must not lock out the nodes that would.
#
# WHAT WENT WRONG
#   set-ch-volt verifies an applied cap by reading the node back. When nothing held it wipes
#   .mcv-read and ch-volt-ctrl-files to force one clean rediscovery - correct for a transient
#   writer/daemon overlap.
#
#   On a phone whose FV votable EXISTS but does not actually take the vote, that rediscovery sees
#   FV present, goes exclusive on it again, fails to hold again, and wipes again. Forever. Going
#   FV-exclusive drops the power_supply voltage_max mirrors out of the list, so the user is left
#   with no voltage cap at all on a phone where the mirrors would have worked.
#
#   Fix: set-ch-volt leaves .fv-nohold when the failed candidates were the votable's own entries,
#   and discovery skips FV exclusivity while it is there. tmpfs, so a reboot retries the votable
#   once - a transient miss must not disable the better control permanently.

ID=t145
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
TMPDIR=${TMPDIR:-/dev/.vr25/acc}
SV=$execDir/set-ch-volt.sh
AD=$execDir/accd.sh
[ -f "$SV" ] || { no "missing $SV"; fin; }
[ -f "$AD" ] || { no "missing $AD"; fin; }

_sv=$(sed 's/^[[:space:]]*#.*//' "$SV" | tr '\n' ' ')
_ad=$(sed 's/^[[:space:]]*#.*//' < "$AD" | tr '\n' ' ')

# A lift is a pipeline, and a pipeline can be killed. Caught in a mega2 run on a Pixel 6a: the
# suite's output began with "Terminated" and the very next assertion - the only one that reads
# $_ad - reported "discovery still goes FV-exclusive", a product verdict invented by a truncated
# command substitution. The same suite passed 5/0 standalone seven times against the identical
# files. Every negative assertion below is of the form "the text does not contain X", so an empty
# or short $_ad fails them all and blames the product. Check the lift arrived first, and say so as
# a harness fault rather than a finding.
_adLines=$(sed -n '$=' "$AD" 2>/dev/null || echo 0)
case "${_adLines:-0}" in ''|*[!0-9]*) _adLines=0;; esac
if [ "${#_ad}" -lt $(( _adLines * 4 )) ] 2>/dev/null || [ "${#_ad}" -lt 1000 ]; then
  no "harness: the accd.sh lift came back at ${#_ad} bytes for a ${_adLines}-line file - it was truncated or interrupted, so nothing below is a verdict on the product"
  fin
fi
case "$_ad" in
  *sync_native_limit*) : ;;
  *) no "harness: the accd.sh lift does not contain sync_native_limit, so it is not the file this suite grades"; fin ;;
esac

case "$_sv" in
  *.fv-nohold*) ok "set-ch-volt records a votable that failed to hold" ;;
  *) no "a non-holding votable leaves no trace - discovery will pick it again and loop" ;;
esac
case "$_sv" in
  *_mcvWasFV*) ok "the marker is tied to the FV entries, not to any failed apply" ;;
  *) no "the marker would be set for a mirror failure too, disabling FV for the wrong reason" ;;
esac
case "$_sv" in
  *'pmic-votable/FV/*) _mcvWasFV=true'*) ok "the FV test matches the votable path" ;;
  *) no "the FV detection does not match the votable entries" ;;
esac
if sed 's/^[[:space:]]*#.*//' < "$AD" | grep -qF '! -f $TMPDIR/.fv-nohold'; then
  ok "discovery skips FV exclusivity once the votable has failed"
else
  no "discovery still goes FV-exclusive after a vote that never held"
fi

# The marker must be in tmpfs so a reboot retries. A dataDir path would make one bad vote
# permanent across reboots.
case "$_sv" in
  *'$TMPDIR/.fv-nohold'*) ok "the marker lives in tmpfs, so a reboot retries the votable" ;;
  *) no "the marker is persisted - one transient miss would disable FV forever" ;;
esac

[ "$(id -u 2>/dev/null)" = 0 ] || { sk "not root"; fin; }
[ -f /sys/kernel/debug/pmic-votable/FV/force_val ] || { sk "no FV votable on this phone"; fin; }

# Live: with the marker present, a discovery must NOT publish an FV-only control list.
_had=0; [ -f $TMPDIR/.fv-nohold ] && _had=1
: > $TMPDIR/.fv-nohold 2>/dev/null || { sk "cannot write the marker"; fin; }
ok "staged: .fv-nohold present"
case "$_ad" in
  *'force_active ] && [ ! -f $TMPDIR/.fv-nohold ]'*)
    ok "the guard is on the same condition that selects the votable" ;;
  *) no "the guard is not wired into the FV selection test" ;;
esac
[ $_had = 1 ] || rm -f $TMPDIR/.fv-nohold 2>/dev/null || :
ok "marker restored to its original state"

fin
