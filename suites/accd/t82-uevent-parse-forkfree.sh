#!/system/bin/sh
# t82 - parsing the battery uevent must not fork. It is already in a shell variable.
#
# write_state is 60-75% of an unplugged loop pass, and it runs on EVERY pass: the gate compares
# uiRefresh (default 60) against a 120s nap, so it is always due. Inside it, nine command
# substitutions each wrap a three-stage pipeline:
#     _c1=$(printf '%s\n' "$_ue1" | sed -n 's/^POWER_SUPPLY_CURRENT_NOW=//p' | head -1)
# subshell + printf + sed + head = about 4 processes, nine times = ~36 processes per pass, to pull
# six fields out of text the shell is already holding. Measured cost of the whole pass on a Pixel
# 6a: ~158 forks. This is roughly a quarter of it, and it performs no I/O at all.
#
# The replacement walks the text with parameter expansion, which forks nothing. The semantics that
# must be preserved exactly, because the median-sample picker downstream depends on them:
#   - FIRST match wins (sed -n .../p | head -1)
#   - a missing key yields empty
#   - a value containing '=' survives whole (sed strips only the leading KEY=)
#   - an empty text yields empty for every key
#   - a key that is a PREFIX of another must not match it (STATUS must not match STATUS_EX)
#
# NO HARDWARE.

ID=t82
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SE=$execDir/state-export.sh
[ -f "$SE" ] || { no "state-export.sh not found"; fin; }

# ---- 1: no parse pipelines remain --------------------------------------------------------------
# -cE, not -c with a BRE alternation. toybox grep has no BRE alternation at all: the pattern
# matched the LITERAL string, found nothing, and _p was always 0 - which is this check's PASS
# value. So the assertion guarding the fork-free parse could never fail, on either phone, since
# the day it was written.
# Strip comments first. _ue_get's own rationale QUOTES the pipeline it replaced, so counting the raw
# file scores the documentation as a leftover - which is how a real 9-vs-0 result came back as 1.
_p=$(sed 's/^[[:space:]]*#.*//' "$SE" | grep -cE "printf '%s\\\\n' \"\\\$ue|printf '%s\\\\n' \"\\\$_ue" 2>/dev/null) || _p=0
case "${_p:-0}" in ''|*[!0-9]*) _p=0;; esac
[ "${_p:-0}" -eq 0 ] 2>/dev/null \
  && ok "no printf|sed|head pipelines left in the uevent parse" \
  || no "${_p} printf|sed|head uevent pipelines remain - about 4 processes each, every pass (the shipped cost)"

# ---- 2: the fork-free extractor exists ----------------------------------------------------------
grep -q '^_ue_get()' "$SE" \
  && ok "_ue_get() exists" \
  || no "_ue_get() not defined - nothing replaced the pipelines"

# ---- 3..N: EXECUTE it and compare against the pipeline it replaces --------------------------------
_FN=$(sed -n '/^_ue_get() {/,/^}/p' "$SE")
if [ -z "$_FN" ]; then
  no "could not extract _ue_get() to execute"
else
  SAMPLE='POWER_SUPPLY_NAME=battery
POWER_SUPPLY_STATUS=Discharging
POWER_SUPPLY_PRESENT=1
POWER_SUPPLY_CAPACITY=32
POWER_SUPPLY_CURRENT_NOW=-109375
POWER_SUPPLY_VOLTAGE_NOW=3763750
POWER_SUPPLY_TEMP=246
POWER_SUPPLY_CHARGE_COUNTER=1018000
POWER_SUPPLY_SERIAL_NUMBER=13G8=230031401AA
POWER_SUPPLY_STATUS=Charging'

  _get(){ ( eval "$_FN"; _ue_get "$1" "$2"; printf '%s' "$_ueval" ) 2>/dev/null; }
  _old(){ printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }

  for _k in POWER_SUPPLY_STATUS POWER_SUPPLY_CURRENT_NOW POWER_SUPPLY_CAPACITY \
            POWER_SUPPLY_VOLTAGE_NOW POWER_SUPPLY_TEMP POWER_SUPPLY_CHARGE_COUNTER; do
    _n=$(_get "$_k" "$SAMPLE"); _o=$(_old "$_k" "$SAMPLE")
    [ "$_n" = "$_o" ] \
      && ok "$_k -> [$_n] matches the pipeline" \
      || no "$_k mismatch: builtin gave [$_n], pipeline gave [$_o]"
  done

  # first match wins - STATUS appears twice in the sample, Discharging then Charging
  _n=$(_get POWER_SUPPLY_STATUS "$SAMPLE")
  [ "$_n" = Discharging ] \
    && ok "duplicate key takes the FIRST value, as head -1 did" \
    || no "duplicate key gave [$_n], expected Discharging - the median picker depends on this"

  # a value containing '=' must survive whole
  _n=$(_get POWER_SUPPLY_SERIAL_NUMBER "$SAMPLE"); _o=$(_old POWER_SUPPLY_SERIAL_NUMBER "$SAMPLE")
  [ "$_n" = "$_o" ] && [ "$_n" = '13G8=230031401AA' ] \
    && ok "a value containing '=' survives whole" \
    || no "'=' in a value broke: builtin [$_n] vs pipeline [$_o]"

  # missing key -> empty
  _n=$(_get POWER_SUPPLY_NOPE "$SAMPLE")
  [ -z "$_n" ] && ok "a missing key yields empty" || no "a missing key yielded [$_n]"

  # empty text -> empty, and must not hang
  _n=$(_get POWER_SUPPLY_STATUS "")
  [ -z "$_n" ] && ok "empty uevent yields empty" || no "empty uevent yielded [$_n]"

  # a key must not match a longer key that starts with it
  _n=$(_get POWER_SUPPLY_CAPACITY 'POWER_SUPPLY_CAPACITY_LEVEL=Normal
POWER_SUPPLY_CAPACITY=77')
  [ "$_n" = 77 ] \
    && ok "a key does not match a longer key sharing its prefix" \
    || no "prefix collision: got [$_n], expected 77"

  # single line, no trailing newline
  _n=$(_get POWER_SUPPLY_STATUS 'POWER_SUPPLY_STATUS=Full')
  [ "$_n" = Full ] && ok "a single unterminated line parses" || no "single line gave [$_n]"
fi

sh -n "$SE" 2>/dev/null && ok "state-export.sh parses" || no "state-export.sh does not parse"
fin
