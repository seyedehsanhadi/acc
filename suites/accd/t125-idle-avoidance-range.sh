#!/system/bin/sh
# t125 - allowIdleAbovePcap=false must work in the range its own documentation recommends.
#
# THE REPORT. pause 60, resume 40, aiapc=false, phone parked at 59% instead of cycling down to 40.
#
# THE CAUSE. cap_idle_threshold() required `pause_capacity > 60` before idle-avoidance could run,
# while default-config.txt recommends 40-60 for exactly this setting. 60 -gt 60 is false, so the
# daemon fell through to plain disable_charging and idled at the limit. The same gate existed in
# the millivolt domain as `pause > 3900`.
#
# THE SHAPE OF THE FIX. The arbitrary gates are gone; the OVERSHOOT margin is not. The
# force-discharge branch and the settle branch both spend the same 2-attempt xIdleCount budget,
# and they are mutually exclusive only because this returns false until the level is above the
# pause level while the settle branch needs level <= pause. That property is asserted here too,
# because relaxing it to ">= pause" is the obvious-looking change and it would spend the budget in
# one pass and toggle the charging switch at the limit.
#
# NO HARDWARE - cap_idle_threshold is driven directly with synthetic readings.

ID=t125
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found at $AD"; fin; }

# Pull the function out and drive it with stubs.
_fn=$(sed -n '/^  cap_idle_threshold() {/,/^  }$/p' "$AD")
[ -n "$_fn" ] || { no "could not extract cap_idle_threshold"; fin; }
eval "$(printf '%s' "$_fn" | sed 's/^  //')"
command -v cap_idle_threshold >/dev/null 2>&1 || { no "cap_idle_threshold did not define"; fin; }

_lvl=0; _mv=0
batt_cap(){ echo "$_lvl"; }
volt_now(){ echo "$_mv"; }

# $1 pause  $2 level(or mV)  $3 expected yes/no  $4 label
t(){
  eval "set -A capacity 5 101 40 $1 false" 2>/dev/null || { no "$4 (cannot build array)"; return; }
  _lvl=$2; _mv=$2
  if cap_idle_threshold 2>/dev/null; then _got=yes; else _got=no; fi
  [ "$_got" = "$3" ] && ok "$4" || no "$4 (got $_got, wanted $3)"
}

# ---- 1. THE REPORTED CASE: pause 60, the top of the recommended range --------------------------
t 60 61 yes "pause 60, level 61 -> idle-avoidance RUNS (was dead: 60 -gt 60 was false)"
t 60 60 no  "pause 60, level 60 -> does not run at the limit itself"
t 60 75 yes "pause 60, level 75 -> runs"

# ---- 2. the rest of the documented 40-60 range -------------------------------------------------
t 40 41 yes "pause 40, level 41 -> runs"
t 50 51 yes "pause 50, level 51 -> runs"
t 45 44 no  "pause 45, level 44 -> below the limit, does not run"

# ---- 3. above 60 must be unchanged, and one percent earlier than the old pause+2 ---------------
t 75 76 yes "pause 75, level 76 -> runs (the old gate waited for 77)"
t 75 75 no  "pause 75, level 75 -> does not run at the limit itself"
t 80 79 no  "pause 80, level 79 -> below the limit, does not run"

# ---- 4. the millivolt domain lost the same arbitrary gate --------------------------------------
t 3800 3900 yes "pause 3800mV, 3900mV -> runs (was dead: 3800 -gt 3900 was false)"
t 3800 3820 no  "pause 3800mV, 3820mV -> inside the +50mV margin, does not run"
t 4100 4200 yes "pause 4100mV, 4200mV -> runs"

# ---- 5. garbage config must not act, and must not abort under set -u ---------------------------
eval "set -A capacity 5 101 40 abc false" 2>/dev/null || :
if cap_idle_threshold 2>/dev/null; then no "a non-numeric pause was treated as actionable"
else ok "a non-numeric pause returns 1 rather than aborting"; fi

# ---- 6. THE PROPERTY THAT MUST NOT BE RELAXED --------------------------------------------------
# The force-discharge branch (~1583) and the settle branch (~1911) both spend xIdleCount, and the
# budget is 2. They are mutually exclusive ONLY while this function is false at level == pause,
# because the settle branch requires level <= pause. If someone "fixes" this to >= pause, both
# fire in one pass: the budget is gone immediately and the switch is toggled at the limit, which
# is the ~40-toggles-in-21-minutes churn the budget exists to prevent.
_viol=0
for _p in 40 55 60 75 80; do
  eval "set -A capacity 5 101 40 $_p false" 2>/dev/null || :
  _lvl=$_p
  cap_idle_threshold 2>/dev/null && _viol=$(( _viol + 1 ))
done
[ "$_viol" -eq 0 ]   && ok "never true at level == pause, so it cannot collide with the settle branch"   || no "$_viol pause value(s) fire AT the limit - the xIdleCount budget would be spent in one pass"

# ---- 7. the documentation and the shipped value must agree ------------------------------------
DC=$execDir/default-config.txt
if [ -f "$DC" ]; then
  _ship=$(sed -n 's/^allowIdleAbovePcap=//p' "$DC" | head -1)
  _doc=$(awk '/allow_idle_above_pcap/,/^# If set to false/' "$DC" | sed -n 's/^# Default: //p' | head -1)
  [ -n "$_ship" ] && [ "$_ship" = "$_doc" ]     && ok "shipped allowIdleAbovePcap=$_ship matches the documented default"     || no "shipped '$_ship' but documented '$_doc'"
  # and write-config must not flip it on the first write
  WC=$execDir/write-config.sh
  if [ -f "$WC" ] && grep -q "aiapc:-$_ship" "$WC"; then
    ok "write-config.sh defaults it to $_ship too"
  else
    no "write-config.sh would rewrite a missing value to something other than $_ship"
  fi
else
  sk "default-config.txt not present"
fi

fin
