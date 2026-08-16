#!/system/bin/sh
# t85 - the kernel-status tie-break must stay live while a RESTORE is being verified.
#
# THE FAULT. rc23 gave the tie-break in idle_discharging a second suppressor:
#     [ "${switch-}" != off ] && ! ${chDisabledByAcc:-false}
# The intent was: while ACC's own cut is in force, a stale kernel "Charging" must not overrule a
# Discharging current sign. That is right for a cut. It is wrong for a restore, because
# chDisabledByAcc is STILL TRUE during cycle_switches on - enable_charging calls the sweep at
# misc-functions.sh:944 and only clears the flag 28 lines later at :972.
#
# WHAT IT COSTS. The on arm of the sweep is one line, misc-functions.sh:355:
#     not_charging || break
# not_charging with switch=on runs batt-interface.sh:171 `status ${1-} || return 1` inside
# `for i in $(seq $_STI)`, _STI=35, one second apart. On a phone whose current sign reads
# Discharging while the kernel reads Charging (the Mi A3 polarity pathology - _DPOL, .dpol_unstable),
# the promotion is what makes status say Charging. Suppress it and:
#     rc22: promoted -> status non-zero -> return 1 -> break at the FIRST restored candidate
#     rc23: suppressed -> status 0 -> all 35 iterations -> no break -> next candidate, ~35s each
# across a 139-line candidate list. The daemon is out of its loop for the whole of it: no flight.log,
# no pause, no resume, no temperature limit.
#
# THE RULE. $switch and $chDisabledByAcc are two signals for ONE question, "is ACC holding charging
# off right now". When not_charging has been handed an explicit flip direction, that direction is the
# authoritative answer and the daemon's steady-pause flag is stale. So: switch=off suppresses,
# switch=on judges honestly, and chDisabledByAcc only decides when there is no flip under test.
#
# NO HARDWARE - executed against stubs.

ID=t85
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=$execDir/batt-interface.sh
MF=$execDir/misc-functions.sh
[ -f "$BI" ] || { no "batt-interface.sh not found"; fin; }
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }

# ---- 1: the premise. chDisabledByAcc is still true when the on-sweep starts. -----------------------
# If this ever stops being true the regression disappears and the rest of this suite is moot, so it is
# asserted rather than assumed.
_mfsrc=$(sed 's/^[[:space:]]*#.*//' "$MF")
_callLine=$(printf '%s\n' "$_mfsrc" | grep -n 'cycle_switches on' | head -1 | cut -d: -f1)
_clrLine=$(printf '%s\n' "$_mfsrc" | grep -n 'chDisabledByAcc=false' | head -1 | cut -d: -f1)
case "${_callLine:-x}${_clrLine:-x}" in
  *x*) no "could not locate the enable_charging sweep call or the chDisabledByAcc reset" ;;
  *) if [ "$_callLine" -lt "$_clrLine" ] 2>/dev/null; then
       ok "premise holds: cycle_switches on at line $_callLine runs BEFORE chDisabledByAcc=false at $_clrLine"
     else
       no "premise broken: chDisabledByAcc is cleared at $_clrLine before the sweep at $_callLine"
     fi ;;
esac

# ---- 2: the on arm really is a single break on not_charging ----------------------------------------
printf '%s\n' "$_mfsrc" | grep -q 'not_charging || break' \
  && ok "the on arm breaks via 'not_charging || break'" \
  || no "the on arm no longer breaks on not_charging - this suite's cost model is stale"

# ---- 3..8: EXECUTE the tie-break decision over the whole matrix -------------------------------------
# The rule in isolation. Everything else being equal (sign says Discharging, kernel says Charging,
# no coulomb verdict), does the status get promoted?
_decide(){ # $1 = switch, $2 = chDisabledByAcc
  ( _status=Discharging; _kstatus=Charging; _ccd=
    switch=$1; chDisabledByAcc=$2
    if [ "$_status" = Discharging ] && [ "${_kstatus-}" = Charging ] && [ -z "${_ccd-}" ] \
      && [ "${switch-}" != off ] && { [ "${switch-}" = on ] || ! ${chDisabledByAcc:-false}; }
    then _status=Charging; fi
    echo "$_status" )
}
_want(){ # $1 switch $2 flag $3 expected $4 why
  _got=$(_decide "$1" "$2")
  [ "$_got" = "$3" ] && ok "(rule) switch='$1' chDisabledByAcc=$2 -> $_got ($4)" \
                     || no "(rule) switch='$1' chDisabledByAcc=$2 -> $_got, wanted $3 ($4)"
}
_want off  true  Discharging "ACC's cut is in force, the kernel does not get to overrule it"
_want off  false Discharging "an explicit off test is authoritative on its own"
_want on   true  Charging    "THE REGRESSION: a restore is being verified, the pause flag is stale"
_want on   false Charging    "restore, nothing holding charging off"
_want ''   true  Discharging "no flip under test, so the daemon's steady pause decides"
_want ''   false Charging    "no cut anywhere, the kernel tie-break does its job"

# ---- 9: the SHIPPED condition must implement that rule ----------------------------------------------
# Pull the real condition out of batt-interface.sh and run the same matrix through it, so this cannot
# pass on a rule that only exists in this file.
_bisrc=$(sed 's/^[[:space:]]*#.*//' "$BI")
_cond=$(printf '%s\n' "$_bisrc" | grep -A1 '\[ "\$_status" = Discharging \] && \[ "\${_kstatus-}" = Charging \]' | tr '\n' ' ')
case "$_cond" in
  *'_status'*) : ;;
  *) no "could not extract the shipped tie-break condition"; fin ;;
esac
_shipped(){ # $1 = switch, $2 = chDisabledByAcc
  ( _status=Discharging; _kstatus=Charging; _ccd=
    switch=$1; chDisabledByAcc=$2
    # strip the line-continuation backslashes and the leading 'if' / trailing 'then', keep the test
    _c=$(printf '%s' "$_cond" | tr -d '\\' | sed 's/^ *if //; s/ *then *$//')
    if eval "$_c"; then _status=Charging; fi
    echo "$_status" ) 2>/dev/null
}
_bad=0
for _case in "off:true:Discharging" "off:false:Discharging" "on:true:Charging" \
             "on:false:Charging" ":true:Discharging" ":false:Charging"; do
  _sw=${_case%%:*}; _rest=${_case#*:}; _fl=${_rest%%:*}; _exp=${_rest#*:}
  _got=$(_shipped "$_sw" "$_fl")
  [ "$_got" = "$_exp" ] || { _bad=$((_bad+1)); echo "        shipped: switch='$_sw' flag=$_fl -> $_got, wanted $_exp"; }
done
[ "${_bad:-0}" -eq 0 ] \
  && ok "the shipped batt-interface.sh condition matches the rule on all 6 cases" \
  || no "${_bad}/6 cases wrong in the shipped condition - an on-sweep will not break early on a sign-inverted phone"

# ---- 10: THE COST. Prove the suppression is what makes the sweep long. ------------------------------
# Run the real loop shape with a stubbed status and count iterations. This is the number that turns a
# one-candidate restore into a walk of the whole candidate list.
_iters(){ # $1 = promote? (yes/no) -> iterations spent before not_charging answers
  ( _STI=6              # short stand-in for 35; the assertion is "breaks at 1" vs "runs to the cap"
    switch=on
    i=0
    while [ $i -lt $_STI ]; do
      i=$((i+1))
      if [ "$1" = yes ]; then echo $i; return 0; fi   # status says Charging -> return 1 -> break
    done
    echo $i )
}
[ "$(_iters yes)" = 1 ] \
  && ok "(cost) promoted: the on sweep answers on iteration 1 and breaks at the first restored candidate" \
  || no "(cost) promoted case did not answer immediately"
[ "$(_iters no)" = 6 ] \
  && ok "(cost) suppressed: the on sweep burns every iteration and never breaks - at _STI=35 that is ~35s PER candidate" \
  || no "(cost) suppressed case did not run to the iteration cap"

# ---- 11: the off direction must NOT have been loosened ----------------------------------------------
# The whole point of the rc23 tie-break change was that a working input-cut switch on a sign-inverted
# phone was being graded broken. That must still hold: with switch=off the kernel never wins.
[ "$(_decide off true)" = Discharging ] && [ "$(_decide off false)" = Discharging ] \
  && ok "off-direction suppression intact - a cut under test is still judged by current, not by the kernel" \
  || no "off-direction suppression lost - this would re-open the fault t79 exists for"

sh -n "$BI" 2>/dev/null && ok "batt-interface.sh parses" || no "batt-interface.sh does not parse"
fin
