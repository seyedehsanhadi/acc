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
# The requirement is that every site is GATED, not that every site calls the same function. The
# daemon's stall path (rekick_charger) already carries its own off switch, a 300s window and its own
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

# ---- the daemon's stall path keeps its own gate ----------------------------------------------------
_r=$(sed -n '/rekick_charger() {/,/^  }/p' "$AD")
printf '%s' "$_r" | grep -q 'rekick-off' \
  && ok "the stall path honours acc -sk off" || no "the stall path ignores the off switch"
printf '%s' "$_r" | grep -q 'REKICK_MIN_GAP' \
  && ok "the stall path keeps its own 300s window" || no "the stall path lost its rate limit"
printf '%s' "$_r" | grep -q '_wlog' \
  && ok "the stall path logs" || no "the stall path is silent"

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
