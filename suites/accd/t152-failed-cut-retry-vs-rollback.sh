#!/system/bin/sh
# t152 - what `return 7` leaves behind, and whether the ownership flag has to move to get it right.
#
# TWO CLAIMS ARE GRADED HERE, both taken from the comment block that sits directly above the
# confirmation in disable_charging.
#
#   CLAIM A: "by this line $flip is empty AND chDisabledByAcc is still false - both suppressors of
#   the kernel-status tie-break are therefore off". That was true before rc23e. rc23e added
#   `flip=off` on the line immediately before the confirmation, and rc24 shipped it. So the
#   premise of the claim is checked here against the file rather than believed: if `flip=off` is
#   there, `switch` is `off` inside not_charging and the tie-break is already suppressed, which
#   makes hoisting chDisabledByAcc above the confirmation a second suppressor for an arbiter that
#   is already quiet.
#
#   CLAIM B: the failed-cut arm must hand the node back before `return 7`. The comment three lines
#   into that arm says the opposite - report failure, let the daemon retry next tick, and do NOT
#   tear anything down because the switch "only needs another loop to settle". Both cannot hold.
#   The settle model below runs the two policies over the same switch and counts the passes each
#   one needs.
#
# A switch that settles is not hypothetical: sw_holds exists because level switches are applied by
# the firmware on its own ~30s tick, and it waits up to 4 of them. not_charging itself samples for
# _STI seconds. So "did not confirm this pass" and "does not work" are different states, and only
# one of them justifies undoing the write.
#
# NO HARDWARE - the confirmation block is lifted from the shipped file and driven with stubs.

ID=t152
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
BI=$execDir/batt-interface.sh
[ -f "$MF" ] || { no "misc-functions.sh not found under $execDir"; fin; }

_dis=$(sed -n '/^disable_charging() {/,/^}/p' "$MF")
[ -n "$_dis" ] || { no "could not read disable_charging"; fin; }

# ---- 0. the harness can fail ---------------------------------------------------------------------
[ 1 = 2 ] && no "harness: 1 equals 2" || ok "harness: the assertions discriminate"

# ---- 1. CLAIM A: is the tie-break already suppressed at the confirmation? --------------------------
_pre=$(printf '%s\n' "$_dis" | sed -n '1,/if ! not_charging; then/p')
printf '%s' "$_pre" | grep -q '^    flip=off' \
  && ok "flip=off is set before the confirmation, so not_charging sees switch=off" \
  || no "flip=off is not set before the confirmation - the tie-break really is unsuppressed there"

# The rule itself, copied from the shipped condition in batt-interface.sh and driven.
_promote(){ # $1 switch, $2 chDisabledByAcc -> the status the tie-break leaves standing
  ( _status=Discharging; _kstatus=Charging; _ccd=
    switch=$1; chDisabledByAcc=$2
    if [ "${_acc_nopromo:-0}" != 1 ] \
      && [ "$_status" = Discharging ] && [ "${_kstatus-}" = Charging ] && [ -z "${_ccd-}" ] \
      && [ "${switch-}" != off ] && { [ "${switch-}" = on ] || ! ${chDisabledByAcc:-false}; }
    then _status=Charging; fi
    echo "$_status" )
}
[ "$(_promote off false)" = Discharging ] \
  && ok "switch=off alone suppresses the promotion, with the ownership flag still false" \
  || no "switch=off did not suppress the promotion - the hoist is load-bearing after all"
[ "$(_promote off true)" = Discharging ] \
  && ok "switch=off with the flag true gives the same answer, so the hoist changes nothing here" \
  || no "the two suppressors disagree"
[ "$(_promote '' false)" = Charging ] \
  && ok "with no flip under test the promotion fires, which is the case the flag is for" \
  || no "the tie-break no longer fires where it is supposed to"
[ "$(_promote '' true)" = Discharging ] \
  && ok "the flag suppresses the promotion for every OTHER status() call made while it is up" \
  || no "the flag does not suppress outside a flip test"

# Where the hoisted flag is actually visible: between the hoist and either exit.
_win=$(printf '%s\n' "$_dis" | sed -n '/^    chDisabledByAcc=true/,/^    (set +eux; eval/p')
_calls=$(printf '%s\n' "$_win" | grep -c 'not_charging\|is_charging\|read_status\|status ')
echo "  status-consuming calls inside the hoist window: $_calls"
[ "$_calls" -le 1 ] \
  && ok "the only consumer in the window is the confirmation itself, which switch=off already covers" \
  || no "$_calls consumers sit in the window - the hoist changes more than the confirmation"

# ---- 2. CLAIM B: the settle model ----------------------------------------------------------------
# One switch, two policies, same hardware. The switch needs $SETTLE consecutive passes with the cut
# APPLIED before the kernel reports it. A policy that removes the write resets that progress.
settle(){ # $1 = rollback|keep, $2 = passes the switch needs, $3 = passes to run
  _applied=0; _held=0; _pass=0; _writes=0
  while [ $_pass -lt $3 ]; do
    _pass=$((_pass + 1))
    _writes=$((_writes + 1))          # every pass writes the cut
    _applied=$((_applied + 1))
    if [ $_applied -ge $2 ]; then _held=$_pass; break; fi
    # the confirmation failed this pass -> return 7
    case $1 in
      rollback) _applied=0; _writes=$((_writes + 1)) ;;   # the write is undone, progress lost
      keep)     : ;;                                      # the cut stays, progress kept
    esac
  done
  echo "$_held $_writes"
}
set -- $(settle keep 3 10);     _kHeld=$1; _kWr=$2
set -- $(settle rollback 3 10); _rHeld=$1; _rWr=$2
echo "  a switch that needs 3 applied passes to report: keep-the-cut held on pass ${_kHeld:-never} ($_kWr writes); roll-back held on pass ${_rHeld:-never} ($_rWr writes)"
[ "${_kHeld:-0}" -gt 0 ] 2>/dev/null \
  && ok "keeping the cut lets a settling switch reach a confirmed hold" \
  || no "keeping the cut never reached a hold - the model is wrong"
[ "${_rHeld:-0}" -eq 0 ] 2>/dev/null \
  && ok "rolling back never reaches a hold for the same switch: each pass undoes the previous one" \
  || no "rolling back also settled, so the two policies do not differ here"
[ "$_rWr" -gt "$_kWr" ] \
  && ok "rolling back costs $_rWr node writes against $_kWr - the thrash is measurable" \
  || no "the write counts did not differ"

# A switch that confirms on the first pass must behave identically under both policies, or the
# rollback would be a regression for every working switch as well.
set -- $(settle keep 1 10);     _k1=$1
set -- $(settle rollback 1 10); _r1=$1
[ "$_k1" = "$_r1" ] && [ "$_k1" = 1 ] \
  && ok "a switch that confirms immediately is unaffected by either policy" \
  || no "the policies differ on an immediately-confirming switch ($_k1 vs $_r1)"

# ---- 3. what the shipped file currently does ------------------------------------------------------
_arm=$(printf '%s\n' "$_dis" | sed -n '/if ! not_charging; then/,/return 7/p')
if printf '%s' "$_arm" | grep -q 'flip_sw on'; then
  echo "  shipped policy: ROLLBACK (the failed-cut arm re-arms the switch before returning 7)"
  printf '%s' "$_arm" | grep -q 'chDisabledByAcc=false' \
    && ok "the rollback at least keeps the flag and the node consistent" \
    || no "the node is re-armed but the ownership flag is left true"
else
  echo "  shipped policy: KEEP (the failed-cut arm leaves the cut in place and retries next pass)"
  ok "the failed-cut arm matches the retry-next-tick comment above it"
fi

fin
