#!/system/bin/sh
# t72 - diag-collect.sh: the gate that decides whether a crash report contains any crash evidence.
#
# REBOOT_SIGNAL is what attaches the pstore, last_kmsg and the full dmesg. When it is false those
# three are deferred -- and they are the only artifacts that can say why a phone went down.
#
# Both crashes actually reported from the field fell straight through it:
#   - a Motorola kansas (MT6835) hung and returned with ro.boot.bootreason=hang_detect. MediaTek's
#     userspace-hang watchdog is not a panic and matched nothing in the pattern.
#   - a OnePlus hung during boot after a dirty module update; the user escaped by holding power,
#     which reports reboot,longkey. Ordinary-looking, so the bundle arrived with no kernel evidence.
#
# The first attempt at the fix over-corrected: matching bare `powerkey` fires on cold,powerkey, which
# is what an ordinary Mi A3 reports for being switched on with the button. That is the adaptive gate
# not existing. It is the LONG press that means something.
#
# NO HARDWARE for the pattern; the marker cases use fake files.

ID=t72
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

DC=${DC:-/data/local/tmp/diag-collect.sh}
[ -f "$DC" ] || DC=${execDir:-/data/adb/vr25/acc}/diag-collect.sh
[ -f "$DC" ] || { no "diag-collect.sh not found (set DC=)"; fin; }

W=${TMPDIR:-/data/local/tmp}/t72.$$
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null
trap 'rm -rf "$W" 2>/dev/null' EXIT

# The pattern exactly as the script carries it - lifted, never retyped, or this test drifts from it.
RE=$(grep -m1 'REBOOT_SIGNAL=true' "$DC" | sed -n "s/.*grep -iqE '\([^']*\)'.*/\1/p")
[ -n "$RE" ] || { no "could not lift the boot-reason pattern out of $DC"; fin; }

hit(){ printf '%s\n' "$1" | grep -iqE "$RE"; }

# ---- 1: the two field reports must both fire -------------------------------------------------------
hit hang_detect      && ok "hang_detect fires (the Motorola)"        || no "hang_detect still quiet - the MediaTek hang report gets no kernel evidence"
hit 'reboot,longkey' && ok "reboot,longkey fires (the OnePlus boot hang, escaped by holding power)" \
                     || no "reboot,longkey still quiet - a forced escape from a boot hang looks normal"

# ---- 2: the ordinary reasons must stay quiet, or the gate is not a gate -------------------------------
for _q in 'reboot,userrequested' 'cold,powerkey' 'reboot,adb' 'shutdown,battery' 'reboot,ota'; do
  hit "$_q" && no "$_q FIRES - a healthy phone would attach the heavy dumps to every bundle" \
             || ok "$_q stays quiet"
done

# ---- 3: the rest of the abnormal family ---------------------------------------------------------------
for _a in kernel_panic watchdog_bite wdt HWT 'hard_reset' 'shutdown,thermal' keys_clear oom_kill; do
  hit "$_a" && ok "$_a fires" || no "$_a does not fire - abnormal reason treated as normal"
done

# ---- 4: ACC's own bootloop latch forces the signal regardless of the reason -----------------------------
# A phone that bootlooped and made ACC self-disable has the most direct evidence there is, and the
# reset reason after a dirty update says nothing useful.
grep -q '\.no-early-cap" \] && REBOOT_SIGNAL=true' "$DC" \
  && ok ".no-early-cap (the 3-strike bootloop latch) forces the signal" \
  || no "the bootloop latch does not force the signal - the one phone that PROVABLY looped gets a thin bundle"
grep -q "early-boot-count: \[1-9\]" "$DC" \
  && ok "a recorded incomplete boot in reboot-history forces the signal" \
  || no "the per-boot counter in reboot-history is not consulted"

# ---- 5: the pstore ratio cannot abort the collector ------------------------------------------------------
# _pp comes from grep -c on a file that may be unreadable; empty operands make $(( )) a syntax error,
# which would kill the collector in the middle of gathering a crash report.
_guard=$(sed -n '/_PS=\/sys\/fs\/pstore/,/REBOOT_SIGNAL=true; fi/p' "$DC")
_pg=0; printf '%s' "$_guard" | grep -q 'case ${_pp:-x} in' && _pg=1
_lg=0; printf '%s' "$_guard" | grep -q 'case ${_pl:-x} in' && _lg=1
{ [ "$_pg" = 1 ] && [ "$_lg" = 1 ]; } \
  && ok "both arithmetic operands are proven numeric before the division" \
  || no "operands unguarded (pp=$_pg pl=$_lg) - an empty one aborts the whole collector"

# EXECUTE the guarded form with the hostile inputs, to be sure the guard is the right shape.
_r=$( ( _pl=100; _pp=
        case ${_pl:-x} in ''|*[!0-9]*) _pl=0;; esac
        case ${_pp:-x} in ''|*[!0-9]*) _pp=0;; esac
        [ "$_pl" -gt 0 ] && [ $(( _pp * 100 / _pl )) -ge 2 ] && echo FIRED || echo quiet ) 2>&1 )
[ "$_r" = quiet ] && ok "an empty match count survives and reads as no signal" \
                   || no "empty _pp produced [$_r] instead of a clean 'quiet'"

_r=$( ( _pl=; _pp=50
        case ${_pl:-x} in ''|*[!0-9]*) _pl=0;; esac
        case ${_pp:-x} in ''|*[!0-9]*) _pp=0;; esac
        [ "$_pl" -gt 0 ] && [ $(( _pp * 100 / _pl )) -ge 2 ] && echo FIRED || echo quiet ) 2>&1 )
[ "$_r" = quiet ] && ok "an empty line count cannot divide by zero" \
                   || no "empty _pl produced [$_r]"

# ---- vendor battery authentication ------------------------------------------------------------
# A Xiaomi kernel gates HIGH-VOLTAGE charging on a battery check. Fail it and the phone holds a 5V
# contract no matter what the charger offers -- which looks exactly like throttling, so ACC gets
# blamed for a decision made below it.
#
# Field report, curtana/Redmi Note 9S, "still not getting fast charge": charger advertised 9V/3A,
# 15V/3A, 20V/4.5A and negotiated Type-C high (3.0A); phone sat at 4.75V/1.43A. The reason was two
# dmesg lines the bundle already carried and never surfaced, while ACC's entire write ledger for the
# session was a plug-time re-kick that RAISED the contract 4732mV -> 4785mV.
DC=${DC:-$execDir/diag-collect.sh}
[ -f "$DC" ] || { no "diag-collect.sh not found"; fin; }
grep -q '_V_bs' "$DC" \
  && ok "the verdict checks vendor battery authentication" \
  || no "nothing reports a battery-auth failure - the phone looks throttled and ACC takes the blame"
grep -q 'batterysecret' "$DC" \
  && ok "  and it looks for the batterysecret verdict specifically" \
  || no "  the check does not name batterysecret"

# EXECUTE THE SHIPPED BLOCK, not a copy of it. A re-implementation here passed while a mutation
# that gutted the real extractor went undetected -- the same gap t74 had before t75 replaced it.
# The block reads /data/local/tmp/.acc-dmesg first, so a fixture at that path drives the real code.
_BSB=$(sed -n '/_V_bs=\$(grep -aoE/,/^  esac$/p' "$DC")
[ -n "$_BSB" ] || { no "could not extract the battery-auth block from diag-collect.sh"; fin; }
printf '%s' "$_BSB" | grep -q 'batterysecret' \
  || { no "the extracted block does not mention batterysecret - extraction is wrong"; fin; }
# Take the fixture path OUT OF THE BLOCK rather than assuming it. Assuming it put the fixture
# somewhere the code never reads, so every "stays quiet" case passed because nothing was found at
# all -- passing for the wrong reason, which is worse than failing.
_BSFIX=$(printf '%s' "$_BSB" | sed -n "s/.*verifed\[\[:space:\]\]\*:\[0-9\]' \([^ ]*\) 2>.*/\1/p" | head -1)
[ -n "$_BSFIX" ] || { no "could not work out which file the block reads"; fin; }
mkdir -p "$(dirname "$_BSFIX")" 2>/dev/null
# The block reads an absolute Android path. On a dev box that path does not exist and cannot be
# created, and the execute-based checks below would then all pass by finding nothing -- the wrong
# reason. Say so and stop rather than bank five hollow passes; on a phone this is always writable.
if ! : > "$_BSFIX" 2>/dev/null; then
  ok "(not on a device: $_BSFIX is not writable, so the executed battery-auth checks are skipped)"
  fin
fi
rm -f "$_BSFIX" 2>/dev/null
bsv() {
  ( printf '%s\n' "$1" > "$_BSFIX" 2>/dev/null
    _vn=0
    _out=$(eval "$_BSB" 2>/dev/null)
    rm -f "$_BSFIX" 2>/dev/null
    case "$_out" in *"battery authentication FAILED"*) echo FIRED;; *) echo quiet;; esac )
}
# prove the fixture actually drives the code before trusting any verdict below
[ "$(bsv 'usbpd usbpd0: batterysecret set usbpd verifed :0')" = FIRED ] \
  || { no "the fixture at $_BSFIX does not reach the shipped block - every check below would be meaningless"; fin; }
ok "the fixture at $_BSFIX drives the shipped block"
[ "$(bsv 'usbpd usbpd0: batterysecret set usbpd verifed :0')" = FIRED ] \
  && ok "a failed battery check is reported (the curtana line, verbatim)" \
  || no "the real failing line did not fire"
[ "$(bsv 'usbpd usbpd0: batterysecret set usbpd verifed :1')" = quiet ] \
  && ok "a PASSED battery check says nothing" \
  || no "verified=1 fired - that would accuse a healthy phone"
[ "$(bsv '')" = quiet ] \
  && ok "a phone with no batterysecret at all says nothing (absence is not failure)" \
  || no "an empty dmesg fired"
[ "$(bsv 'batterysecret verify process :0')" = quiet ] \
  && ok "the in-progress 'verify process' line is not mistaken for the verdict" \
  || no "'verify process :0' fired - that is the attempt, not the result"
# the last verdict wins: a plug that failed then succeeded must not report
[ "$(bsv 'batterysecret set usbpd verifed :0
batterysecret set usbpd verifed :1')" = quiet ] \
  && ok "the LAST verdict wins, so an earlier failure that later passed is not reported" \
  || no "an old failing line still fires after a later pass"

fin
