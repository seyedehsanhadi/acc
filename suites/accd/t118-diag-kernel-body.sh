#!/system/bin/sh
# t118 - the collector must be able to carry the artifact its own index advertises.
#
# THE FIELD REPORT (bramble, Pixel 4a 5G)
#   The bundle's DropBox index listed, in its own words:
#
#       2026-08-18 11:08:21 SYSTEM_LAST_KMSG (compressed text, 15387 bytes)
#
#   an abnormal reboot nine minutes before the charging fault being reported. The manifest then said
#
#       NOTE   reboot-signal fired -> attached full dmesg + all pstore variants + last_kmsg
#
#   and reboot/ contained bootreason.txt and reboot-history.txt. No kernel log, from either path.
#
# THE THREE FAULTS
#   1. Android DRAINS /sys/fs/pstore into DropBox as SYSTEM_LAST_KMSG. So after the drain the pstore
#      tier finds an empty directory and the body is in DropBox -- but the body glob was
#      (crash|anr|panic|tombstone) and matches no part of that name. The index greps for last_kmsg,
#      so the bundle advertised a file it structurally could not collect.
#   2. The reboot NOTE asserted its attachments instead of counting them. The same disease this file
#      already fixed one tier down for /proc/last_kmsg, where "every bundle on a device with
#      /proc/last_kmsg claimed to carry a file it did not have".
#   3. The redactor read a DropBox filename as an email address. "data_app_anr@1786997280406.txt.gz"
#      is name + @ + digits + .txt, which satisfied the address pattern, so six manifest lines came
#      back as "dropbox-body -> crash/dropbox-bodies/[EMAIL]" and named nothing.
#
# HOW THIS IS GRADED
#   Both arms. Each case must show rc23 failing and the current tree passing, or it proves nothing.

ID=t118
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t118}
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

for a in "$ARM23" "$ARM24"; do
  [ -f "$a/diag-collect.sh" ] || { no "no diag-collect.sh in $a"; fin; }
done
ok "both collector arms present"

echo
echo "-- 0  the collector still parses"
for a in "$ARM23" "$ARM24"; do
  if /system/bin/sh -n "$a/diag-collect.sh" 2>$W/syn; then :; else no "syntax error in $a: $(cat $W/syn)"; fi
done
[ "$F" -eq 0 ] && ok "both arms parse under /system/bin/sh"

# A DropBox directory shaped like bramble's: the kernel body is OLDER than a burst of app bodies.
mkdbx(){
  rm -rf $W/dbx 2>/dev/null; mkdir -p $W/dbx
  : > "$W/dbx/SYSTEM_LAST_KMSG@1787065701000.txt.gz"
  sleep 1
  for i in 1 2 3 4 5 6 7 8; do : > "$W/dbx/data_app_anr@178706600000$i.txt.gz"; done
}

# The two globs, lifted verbatim from each arm.
glob_of(){ grep -o 'ls -t /data/system/dropbox/[^|]*' "$1/diag-collect.sh" | sed "s#/data/system/dropbox/#$W/dbx/#g"; }

echo
echo "-- 1  can the kernel body be reached at all?"
mkdbx
_g23=$(glob_of "$ARM23"); _g24=$(glob_of "$ARM24")
_h23=$(eval "$_g23" 2>/dev/null | grep -c KMSG)
_h24=$(eval "$_g24" 2>/dev/null | grep -c KMSG)
echo "     rc23 globs reach KMSG: $_h23     current: $_h24"
if [ "$_h23" -eq 0 ] && [ "$_h24" -ge 1 ]; then
  ok "the SYSTEM_LAST_KMSG body is now reachable, where rc23's glob could never match it"
elif [ "$_h23" -ge 1 ]; then
  no "rc23 already reached it - this case cannot see the defect, so it proves nothing"
else
  no "the current glob still cannot reach a SYSTEM_LAST_KMSG body"
fi

echo
echo "-- 2  can a burst of ANRs crowd it out?"
# Eight app bodies, all NEWER than the kernel body, against a head -6 budget.
_first=$(eval "$_g24" 2>/dev/null | head -3 | grep -c KMSG)
[ "$_first" -ge 1 ] && ok "the kernel body survives 8 newer ANRs (it is on its own budget)" \
                    || no "8 newer ANRs pushed the kernel body out of the collected set"

echo
echo "-- 2b  a PURGED body must not be attached, nor spend the budget"
# DropBox leaves a zero-byte *.lost placeholder where it purged a body. A Mi A3 offered seven of
# them and no surviving log; the first cut of this fix copied three empty files and called them OK.
rm -rf $W/dbx 2>/dev/null; mkdir -p $W/dbx
for i in 1 2 3 4 5 6 7; do : > "$W/dbx/SYSTEM_LAST_KMSG@178731498728$i.lost"; done
sleep 1
echo "real kernel log" > "$W/dbx/SYSTEM_LAST_KMSG@1787380667730.txt.gz"   # newest? no - oldest wins ls -t
# Make the REAL body the OLDEST, so only skipping the placeholders can reach it.
touch -t 202001010000 "$W/dbx/SYSTEM_LAST_KMSG@1787380667730.txt.gz" 2>/dev/null
_sel=$(eval "$(glob_of "$ARM24")" 2>/dev/null)
_nlost=0; _nreal=0
for f in $_sel; do [ -s "$f" ] && _nreal=$((_nreal+1)) || _nlost=$((_nlost+1)); done
echo "     glob offers $_nreal real + $_nlost purged"
# The collector filters with [ -s ]; assert the surviving set the loop would copy.
_copied=0; _k=0
for f in $_sel; do [ "$_k" -ge 3 ] && break; [ -s "$f" ] || continue; _k=$((_k+1)); _copied=$((_copied+1)); done
[ "$_copied" -eq 1 ] && ok "7 purged placeholders are skipped and the one surviving body is still reached"                      || no "the budget copied $_copied bodies (expected the 1 surviving one)"
grep -q '\[ -s "$f" \] || { _dblost=' "$ARM24/diag-collect.sh"   && ok "the collector skips zero-byte bodies rather than announcing them as attached"   || no "the collector does not test for a zero-byte body"
grep -q 'not attachable' "$ARM24/diag-collect.sh"   && ok "purged bodies are reported honestly instead of silently"   || no "purged bodies are not reported"

echo
echo "-- 2c  the kernel body must not be gated behind --full"
# The pstore tier it substitutes for runs on a reboot signal in ANY mode. Gating the substitute on
# --full meant a normal bundle from a phone that had just rebooted abnormally carried no kernel log.
_kl=$(grep -n 'dropbox kernel-body' "$ARM24/diag-collect.sh" | head -1 | cut -d: -f1)
_rb=$(grep -n '^if \$REBOOT_SIGNAL; then' "$ARM24/diag-collect.sh" | head -1 | cut -d: -f1)
_fl=$(grep -n '^if \[ "\$MODE" = full \]; then' "$ARM24/diag-collect.sh" | head -1 | cut -d: -f1)
echo "     kernel-body line $_kl   reboot tier opens $_rb   --full opens $_fl"
if [ -n "$_kl" ] && [ -n "$_rb" ] && [ -n "$_fl" ] && [ "$_kl" -gt "$_rb" ] && [ "$_kl" -lt "$_fl" ]; then
  ok "the kernel body is collected in the reboot tier, so a normal bundle carries it too"
else
  no "the kernel body is not inside the reboot tier (line $_kl, tier $_rb..$_fl)"
fi

echo
echo "-- 2d  no tier may announce a zero-byte file as collected"
# cpf is the one place that reports what LANDED. Any tier that hand-rolls cp + man "OK" can announce
# an empty file as collected -- a Mi A3 carried two zero-byte ANR traces reported as OK.
_hand=$(grep -cE 'cp -f "\$(tb|an)".*man "OK' "$ARM24/diag-collect.sh")
_h23=$(grep -cE 'cp -f "\$(tb|an)".*man "OK' "$ARM23/diag-collect.sh")
echo "     rc23 hand-rolled crash copies: $_h23     current: $_hand"
if [ "$_h23" -ge 1 ] && [ "$_hand" -eq 0 ]; then
  ok "the tombstone and ANR tiers now report through cpf, which says EMPTY instead of OK"
elif [ "$_h23" -eq 0 ]; then
  no "rc23 has no hand-rolled crash copy - this case proves nothing"
else
  no "a crash tier still hand-rolls cp + man OK ($_hand site(s))"
fi
# and the tombstone count must count what landed, not what was attempted
grep -q 'if \[ -s "\$STAGE/crash/\$(basename "\$tb")" \]; then _n=' "$ARM24/diag-collect.sh"   && ok "the tombstone count counts files that landed"   || no "the tombstone count does not test that the file landed"

echo
echo "-- 3  the redactor must not eat a DropBox filename"
red(){ sed -n 's#^ *-e .\(s#[A-Za-z0-9._%+-].*EMAIL.*\)..\*$#\1#p' "$1/diag-collect.sh" | head -1; }
# Pull the address expression out of each arm and run it over both a filename and a real address.
runred(){
  _e=$(grep -o "s#\[A-Za-z0-9._%+-\][^#]*#\[EMAIL\]#g" "$1/diag-collect.sh" | head -1)
  [ -n "$_e" ] || { echo NOEXPR; return; }
  printf '%s\n' "$2" | sed -E -e "$_e"
}
_fn='dropbox-body -> crash/dropbox-bodies/data_app_anr@1786997280406.txt.gz'
_em='contact sy.ehsanhadi@gmail.com for details'
_f23=$(runred "$ARM23" "$_fn"); _f24=$(runred "$ARM24" "$_fn")
_e24=$(runred "$ARM24" "$_em")
echo "     rc23 on a filename: $_f23"
echo "     now  on a filename: $_f24"
case "$_f23" in *EMAIL*) _r23=ate ;; *) _r23=kept ;; esac
case "$_f24" in *EMAIL*) _r24=ate ;; *) _r24=kept ;; esac
if [ "$_r23" = ate ] && [ "$_r24" = kept ]; then
  ok "a DropBox filename now survives redaction, where rc23 replaced it with [EMAIL]"
elif [ "$_r23" = kept ]; then
  no "rc23 already kept the filename - this case proves nothing"
else
  no "the current redactor still reports the filename as [EMAIL]"
fi
case "$_e24" in *'[EMAIL]'*) ok "a real address is still redacted" ;;
                *) no "REGRESSION: a real address survived redaction: $_e24" ;; esac

echo
echo "-- 4  the reboot note must count, not assert"
_n23=$(grep -c 'NOTE   reboot-signal fired -> attached full dmesg + all pstore variants' "$ARM23/diag-collect.sh")
_n24=$(grep -c 'NOTE   reboot-signal fired -> attached full dmesg + all pstore variants' "$ARM24/diag-collect.sh")
if [ "$_n23" -ge 1 ] && [ "$_n24" -eq 0 ]; then
  ok "the note no longer claims pstore + last_kmsg were attached regardless of what landed"
elif [ "$_n23" -eq 0 ]; then
  no "rc23 does not carry the asserting note - this case proves nothing"
else
  no "the asserting note is still present"
fi
grep -q 'file(s) in reboot/' "$ARM24/diag-collect.sh" \
  && ok "the note reports a count of what actually landed" \
  || no "the note does not report a count"
grep -q 'SYSTEM_LAST_KMSG body under crash/' "$ARM24/diag-collect.sh" \
  && ok "the note points the reader at where the kernel log actually is" \
  || no "the note does not say where a drained kernel log went"

echo
echo "-- 5  can these cases still fail?"
mkdir -p $W/mut 2>/dev/null
# Put the old address expression back and confirm case 3 catches it.
sed 's#@\[A-Za-z\]\[A-Za-z0-9.-\]\*#@[A-Za-z0-9.-]+#' "$ARM24/diag-collect.sh" > $W/mut/diag-collect.sh
if cmp -s "$ARM24/diag-collect.sh" $W/mut/diag-collect.sh; then
  sk "could not mutate the address expression"
else
  _mm=$(runred "$W/mut" "$_fn")
  case "$_mm" in *EMAIL*) ok "mutation caught: the old expression eats the filename again" ;;
                 *) no "mutation NOT caught: case 3 cannot fail" ;; esac
fi
# Remove the kernel-body loop and confirm case 1 catches it.
grep -v 'dropbox/\*KMSG\*' "$ARM24/diag-collect.sh" > $W/mut/d2.sh
mkdir -p $W/mut2; cp $W/mut/d2.sh $W/mut2/diag-collect.sh
_g2=$(glob_of "$W/mut2")
_h2=$(eval "$_g2" 2>/dev/null | grep -c KMSG)
[ "$_h2" -eq 0 ] && ok "mutation caught: without the kernel-body loop the KMSG body is unreachable again" \
                 || no "mutation NOT caught: case 1 cannot fail"

fin
