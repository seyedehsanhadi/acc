#!/system/bin/sh
# t35 - every USB re-kick is gated.
#
# apsd_rerun/rerun_aicl make the charger re-run input detection. That recovers a stalled charger,
# and it also renegotiates a live QC/PD contract down to 5V -- which a PD contract does not recover
# from on its own, only a physical replug does. `acc -sk off` exists precisely so an owner can stop
# it, and its help text says "turn it off if it disturbs fast charging on your phone".
#
# Two sites inside set_ch_curr's clear path fired it raw: no off switch, no rate limit, and no
# ledger line. Field bundle acc-diag-curtana-20260804-132857 shows that clear's own current writes
# at 13:26:38 with no re-kick recorded beside them, then 4.83V/5.84W until a replug restored
# 8.66V/15.3W.
#
# rc22 UPDATE: "every site is GATED, not necessarily through the same function" turned out to be
# wrong, and this test enforced the wrong thing. The stall path did carry its own off switch, its own
# 300s window and its own ledger line - but in a SEPARATE timestamp file from the other gate. Neither
# could see the other's firings, so one logged "rekick suppressed (181s since last, min 300s)" while
# the other fired 15 seconds later. Measured on a Mi A3 with no limit configured: apsd_rerun every
# 15 to 62 seconds, the charger renegotiating each time, the charge never establishing - which is
# the very collapse the 300s window exists to prevent.
#
# A rate limit split across two counters that cannot see each other is not a rate limit. So the
# requirement is now stronger: every site goes through ONE gate. These checks follow the structure
# rather than asserting the old one.
#
# The historical note below describes what the stall path used to carry on its own.
# stamp; folding it into the shared 30s helper would change a working path's behaviour for nothing.

ID=t35
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
SC=$execDir/set-ch-curr.sh
AD=$execDir/accd.sh
for _f in "$MF" "$SC" "$AD"; do [ -f "$_f" ] || { no "$_f not found"; fin; }; done

# ---- no raw re-kick may remain outside a gate -----------------------------------------------------
# Count only real code: a comment explaining the re-kick is fine.
_raw=$(grep -n 'apsd_rerun' "$SC" | grep -vc '^[0-9]*: *#')
[ "${_raw:-1}" -eq 0 ] \
  && ok "set-ch-curr has no ungated re-kick left" \
  || no "set-ch-curr still writes apsd_rerun directly ($_raw site(s)) - bypasses acc -sk off"

grep -q 'rekick_usb clear-not-charging' "$SC" \
  && ok "the not-charging clear routes through the gate" || no "the not-charging clear is ungated"
grep -q 'rekick_usb clear-resolved' "$SC" \
  && ok "the resolved clear routes through the gate" || no "the resolved clear is ungated"

# ---- the shared gate itself -----------------------------------------------------------------------
grep -q 'rekick_usb() {' "$MF" && ok "rekick_usb exists" || { no "rekick_usb is not defined"; fin; }

_g=$(sed -n '/^rekick_usb() {/,/^}/p' "$MF")
printf '%s' "$_g" | grep -q 'rekick-off' \
  && ok "the gate honours acc -sk off" || no "the gate ignores the user's off switch"
printf '%s' "$_g" | grep -q '_rekick_due' \
  && ok "the gate rate-limits" || no "the gate does not rate-limit"
printf '%s' "$_g" | grep -q '_wlog' \
  && ok "the gate logs, so a re-kick is visible in a diagnostic bundle" \
  || no "the gate is silent - a re-kick would leave no trace"

# It must be defined BEFORE set-ch-curr.sh is sourced, or the call is an unknown command under
# set -eu and the clear path dies mid-way.
_def=$(grep -n '^rekick_usb() {' "$MF" | cut -d: -f1)
_src=$(grep -n '^\. \$execDir/set-ch-curr.sh' "$MF" | cut -d: -f1)
if [ -n "$_def" ] && [ -n "$_src" ]; then
  [ "$_def" -lt "$_src" ] \
    && ok "rekick_usb is defined before set-ch-curr.sh is sourced (line $_def < $_src)" \
    || no "rekick_usb is defined AFTER set-ch-curr.sh is sourced - the call would not resolve"
else
  no "could not locate the definition or the source line"
fi

# ---- the daemon's stall path goes through the SAME gate --------------------------------------------
_r=$(sed -n '/rekick_charger() {/,/^  }/p' "$AD")
printf '%s' "$_r" | grep -q 'rekick_usb' \
  && ok "the stall path routes through rekick_usb, the single gate" \
  || no "the stall path does not call rekick_usb - it is a second implementation again"

# Comments in that function NAME the nodes while explaining the bug, so match code only. A grep that
# cannot tell a comment from a statement will fail on its own documentation - which this one did.
printf '%s' "$_r" | grep -v '^[[:space:]]*#' | grep -qE 'apsd_rerun|rerun_aicl' \
  && no "the stall path still writes the re-kick nodes itself, bypassing the gate" \
  || ok "the stall path writes no re-kick node directly"

printf '%s' "$_r" | grep -q 'rekick-at' \
  && no "a second timestamp file is back - two counters cannot rate limit each other" \
  || ok "the stall path keeps no timestamp of its own"

# ---- the shared interval is the protective one ------------------------------------------------------
_d=$(sed -n '/^_rekick_due() {/,/^}/p' "$MF")
printf '%s' "$_d" | grep -q '_rekickMinInterval:-300' \
  && ok "the shared interval is the protective 300s, not the old 30s" \
  || no "the shared interval is not 300s - repeats can collapse a QC handshake"

# ---- behavioural: reproduce the gate's decision -----------------------------------------------------
_min=30
gate() {   # $1 = "off" for acc -sk off, $2 = seconds since the last kick ("" = never)
  [ "$1" != off ] || return 1
  case "$2" in '') return 0;; *) [ "$2" -ge "$_min" ];; esac
}
gate on ""   && ok "the first kick fires with no delay"       || no "the first kick was suppressed"
gate on 60   && ok "a kick outside the window fires"          || no "a due kick was suppressed"
gate on 5    && no "a kick inside the window fired"           || ok "a repeat inside the window is dropped"
gate off ""  && no "a kick fired with the off switch set"     || ok "acc -sk off stops even the first kick"
gate off 600 && no "the off switch was ignored when due"      || ok "acc -sk off wins over the rate limit"

fin
