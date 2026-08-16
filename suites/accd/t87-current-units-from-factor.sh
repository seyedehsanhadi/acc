#!/system/bin/sh
# t87 - a current under the mA/uA magnitude cutoff must not be published a thousand times too high.
#
# THE FAULT, measured on a Mi A3 (laurus), plugged, while ACC had charging cut:
#   /sys/class/power_supply/usb/input_current_now read 6163 (uA, i.e. 6.16 mA - essentially nothing)
#   and the app displayed 6.16 A. Again moments later at 5675 -> "5.68 A".
#
# WHY. _se_input and _se_charge decide units by MAGNITUDE ALONE:
#     ca="${c#-}"; [ "$ca" -ge 100000 ] && c=$(( c / 1000 ))
# A genuine uA reading below the cutoff is not divided, so it is republished as if it were already mA.
# Exactly 1000x. The bad case is not exotic: battery current sits under 100 mA whenever a phone is
# HELD AT ITS CHARGE LIMIT, which is the normal resting state for every user of this module.
#
# THE FIX ALREADY EXISTS IN THIS FILE. _se_units() had the identical bug and was fixed in 6.4.1-rc3 by
# preferring the daemon's calibrated ampFactor over the magnitude guess - its own comment cites
# "a 4.7 mA idle current read as 4687 mA". _se_input and _se_charge were never brought along. The rule
# below is that same rule: when the daemon knows the units, use them; fall back to magnitude only when
# it does not.
#
# NOT an rc23 regression - byte-identical at rc22. Fixing it here because the round found it.
# NO HARDWARE.

ID=t87
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SE=$execDir/state-export.sh
[ -f "$SE" ] || { no "state-export.sh not found"; fin; }
_src=$(sed 's/^[[:space:]]*#.*//' "$SE")

# ---- 1: the existing precedent still holds --------------------------------------------------------
# _se_units must prefer the calibrated factor. If this ever regresses, the fix below has no anchor.
_u=$(awk '/^_se_units\(\) \{/,/^\}/' "$SE")
printf '%s\n' "$_u" | grep -q 'ampFactor' \
  && ok "_se_units prefers the daemon's calibrated ampFactor (the 6.4.1-rc3 fix, still present)" \
  || no "_se_units no longer consults ampFactor - the precedent this suite builds on is gone"

# ---- 2..7: EXECUTE the rule ------------------------------------------------------------------------
# to_ma: raw value + known units -> milliamps. Magnitude decides ONLY when units are unknown.
_to_ma(){ # $1 raw  $2 units (uA|mA|unknown)
  ( _v=$1; _un=$2; _a="${_v#-}"
    case "$_un" in
      uA) _v=$(( _v / 1000 )) ;;
      mA) : ;;
      *)  [ "$_a" -ge 100000 ] 2>/dev/null && _v=$(( _v / 1000 )) ;;
    esac
    echo "$_v" )
}
_want(){ # $1 raw $2 units $3 expected $4 why
  _g=$(_to_ma "$1" "$2")
  [ "$_g" = "$3" ] && ok "(rule) $1 as $2 -> ${_g}mA ($4)" \
                   || no "(rule) $1 as $2 -> ${_g}mA, wanted ${3}mA ($4)"
}
_want 6163      uA 6     "THE BUG: 6.16mA of input, not 6.16A"
_want 5675      uA 5     "the second sighting, 5.68mA not 5.68A"
_want 2756218   uA 2756  "a real 2.76A input still normalises"
_want -3020000  uA -3020 "an inverted-sign phone charging at 3A"
_want 1212      mA 1212  "a genuine mA kernel is left alone"
_want 250000    unknown 250 "no factor known: magnitude fallback still works above the cutoff"

# ---- 7b: EXECUTE the shipped _se_ma, so restoring the fault cannot pass -----------------------------
# The rule cases above run a copy written in this file. Mutation-tested: replacing _se_ma's uA/mA arms
# with `: ;` restores the exact Mi A3 6163 uA -> 6.16 A fault and the suite still scored 16/16, because
# nothing here executed the shipped function. Lift it and drive it.
_MA=$(awk '/^_se_ma\(\) \{/,/^\}/' "$SE")
_UN=$(awk '/^_se_units\(\) \{/,/^\}/' "$SE")
if [ -z "$_MA" ] || [ -z "$_UN" ]; then
  no "could not lift _se_ma/_se_units out of state-export.sh - the checks below would grade prose"
else
  _shipped_ma(){ # $1 raw  $2 ampFactor
    ( set +u; ampFactor=$2; ampFactor_=; eval "$_UN"; eval "$_MA"; _se_ma "$1"; printf '%s' "$_sema" ) 2>/dev/null
  }
  [ "$(_shipped_ma 6163 1000000)" = 6 ]     && ok "(shipped) 6163 uA with a uA factor -> 6mA, the measured fault does not come back"     || no "(shipped) 6163 uA gave [$(_shipped_ma 6163 1000000)]mA - the 1000x inflation is live again"
  [ "$(_shipped_ma 2756218 1000000)" = 2756 ]     && ok "(shipped) a real 2.76A input still normalises"     || no "(shipped) 2756218 uA gave [$(_shipped_ma 2756218 1000000)]mA"
  [ "$(_shipped_ma 1212 1000)" = 1212 ]     && ok "(shipped) a genuine mA kernel is left alone"     || no "(shipped) 1212 with an mA factor gave [$(_shipped_ma 1212 1000)]"
  [ "$(_shipped_ma 250000 '')" = 250 ]     && ok "(shipped) no factor set: the magnitude fallback still works above the cutoff"     || no "(shipped) the unknown-units fallback gave [$(_shipped_ma 250000 '')]"
  [ "$(_shipped_ma 6163 '')" = 6163 ]     && ok "(shipped) no factor and below the cutoff: magnitude cannot tell, and it says so rather than guessing high"     || no "(shipped) the no-factor small-value case changed behaviour unexpectedly"
fi

# ---- 8: the SHIPPED code must route both CURRENTS through the units-aware helper --------------------
# Named per site, not counted in aggregate: a count passes when only one of the two is fixed, and the
# battery-current site is the one that decides the watts a user reads while parked at the limit.
_helper=$(awk '/^_se_ma\(\) \{/,/^\}/' "$SE")
[ -n "$_helper" ] \
  && ok "_se_ma exists (one units-aware normaliser, not a rule copied per call site)" \
  || no "_se_ma missing - there is no shared units-aware current normaliser"
printf '%s\n' "$_helper" | grep -q 'ampFactor' \
  && ok "_se_ma decides on the calibrated ampFactor, not on magnitude alone" \
  || no "_se_ma does not consult ampFactor - it is guessing again"

# FORK COST. This runs on every daemon pass, and the first version of this fix echoed its result, so
# both call sites were `x=$(_se_ma ...)` - a subshell each, plus one more for an inner $(_se_units).
# Measured on a Pixel 6a at 120s: ACC's own forks went 99 -> 671. The whole point of the state-export
# work in this release was removing forks from this path, so a units fix that reintroduces them is a
# net loss. _ue_get in the same file documents the idiom: return via a global, never echo.
printf '%s\n' "$_helper" | grep -q '_sema=' \
  && ok "_se_ma returns via a global, so its call sites need no subshell" \
  || no "_se_ma echoes its result - every call site is then a fork, on a path that runs every pass"
# and the call sites must actually use it that way
_forks=$(grep -c '\$(_se_ma' "$SE") || _forks=0
case "${_forks:-0}" in ''|*[!0-9]*) _forks=0;; esac
[ "$_forks" -eq 0 ] 2>/dev/null \
  && ok "no call site wraps _se_ma in a command substitution" \
  || no "${_forks} call site(s) still use \$(_se_ma ...) - that is a fork per call, every pass"

_body_in=$(awk '/^_se_input\(\) \{/,/^\}/' "$SE")
printf '%s\n' "$_body_in" | grep -q '_se_ma' \
  && ok "_se_input normalises its current through _se_ma" \
  || no "_se_input still decides its current by magnitude alone - a 6mA input publishes as 6A"

_body_ch=$(awk '/^_se_charge\(\) \{/,/^\}/' "$SE")
printf '%s\n' "$_body_ch" | grep -q '_se_ma' \
  && ok "_se_charge normalises the battery current through _se_ma" \
  || no "_se_charge still decides the battery current by magnitude alone - the watts shown while held at the limit are 1000x high"

# ---- 9: and the watts derived from it -------------------------------------------------------------
# 4.0V pack at 6.16mA is 0W. The same raw value read as 6.16A is 24W, which is what reached the app.
_w(){ ( _mv=$1; _ma=$2; echo $(( _mv * _ma / 1000000 )) ) }
[ "$(_w 4000 6)" = 0 ] && ok "(watts) 4.0V x 6mA rounds to 0W, as it should" \
                       || no "(watts) 4.0V x 6mA did not come out at 0W"
[ "$(_w 4000 6163)" = 24 ] \
  && ok "(watts) the unfixed path would have reported 24W for a phone drawing nothing" \
  || no "(watts) arithmetic check failed"

sh -n "$SE" 2>/dev/null && ok "state-export.sh parses" || no "state-export.sh does not parse"
fin
