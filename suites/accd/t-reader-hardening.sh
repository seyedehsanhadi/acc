#!/system/bin/sh
# t-reader-hardening - the sensor readers must survive the shapes a real driver emits.
#
# WHY THIS EXISTS. The rc25 sensor rework replaced `cat` with `{ read -r v < node; } || v=` in
# current_now, temperature_now, volt_now and cc_now, and made a reading that cannot be scaled
# answer null. Three shapes then stopped working that rc24 handled, and all three are shapes a
# kernel actually produces. Section 2 below is NOT a regression: an input reading that could be
# either scale stays unreadable on purpose, and this file pins that rule so it is not "fixed" by
# accident.
#
#   1  A node with NO trailing newline. `read` returns non-zero at EOF even though it has already
#      assigned the value, so `|| v=` threw the value away. Every reader went blind, status()
#      answered Unknown on every pass, and the resume branch in accd (_le_resume_cap &&
#      not_charging) never fires on Unknown -- a phone paused at its limit would have stayed there.
#   2  No provable unit at all (a phone with no second gauge, or a daemon that started while the
#      pack sat idle so no current ever carried a magnitude). current_factor returned nothing and
#      status() refused for every reading afterwards, including a clean -895 mA charging current.
#
# A zero current needs no factor: zero is zero in either unit. Demanding one there is what made a
# daemon that started at the cap answer Unknown forever.
#
# NO HARDWARE. Production readers are lifted from the build under test and run against files.
# toybox printf does not honour "--", so every fixture write goes through printf '%s'.

ID=t-reader-hardening
execDir=${execDir:-install}
execDir=$(cd "$execDir" && pwd)
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

W=$(mktemp -d "${TMPDIR:-/data/local/tmp}/reader-hardening.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT HUP INT TERM

. "$execDir/state-export.sh"
for fn in current_now current_factor temperature_now volt_now _cc_uevent cc_now status; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$execDir/batt-interface.sh")"
done
eval "$(sed -n '/^_iin_ma() {/,/^}/p' "$execDir/misc-functions.sh")"

TMPDIR=$W; dataDir=$W; mkdir -p "$W/battery" "$W/usb" "$W/bms"
cd "$W" || exit 1
ACC_PSY=$W
currFile=$W/battery/current_now; temp=$W/battery/temp; voltNow=$W/battery/voltage_now
battCapacity=$W/battery/capacity; battStatus=$W/battery/status
wnl(){ printf '%s\n' "$2" > "$1"; }
wnn(){ printf '%s' "$2" > "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1 -> $2" || no "$1 -> got [$2], want [$3]"; }

# ---- 1: a node with no trailing newline ----------------------------------------------------------
wnl "$currFile" -895;  is "current_now, newline"            "$(current_now)" -895
wnn "$currFile" -895;  is "current_now, NO newline"         "$(current_now)" -895
wnl "$temp" 250;       is "temperature_now, newline"        "$(temperature_now)" 250
wnn "$temp" 250;       is "temperature_now, NO newline"     "$(temperature_now)" 250
wnn "$voltNow" 3712937; is "volt_now, NO newline"           "$(volt_now)" 3712
wnn "$W/battery/charge_counter" 594000; is "cc_now, NO newline" "$(cc_now)" 594000
wnn "$W/usb/input_current_now" 2696040
inputAmpFactor=; is "_iin_ma, NO newline"                   "$(_iin_ma || echo UNREADABLE)" 2696

# a node that is genuinely empty still has to read as unavailable, not as a number
: > "$currFile";       is "current_now, empty node"         "$(current_now)" null
rm -f "$currFile";     is "current_now, absent node"        "$(current_now)" null

# ---- 2: an input node that really reports milliamps ----------------------------------------------
rm -f "${TMPDIR:-/dev}/.iinmicro"
inputAmpFactor=
# INTENTIONAL, and the same rule t115 pins: a small reading from a node with no microamp history
# is ambiguous (1800 uA collapsed, or 1800 mA healthy) and is reported as unreadable rather than
# guessed. inputAmpFactor is the escape hatch for a phone whose input node really is milliamps.
wnl "$W/usb/input_current_now" 1800;    is "input 1800, no history -> ambiguous" "$(_iin_ma || echo UNREADABLE)" UNREADABLE
wnl "$W/usb/input_current_now" 0;       is "input at zero"  "$(_iin_ma || echo UNREADABLE)" 0
wnl "$W/usb/input_current_now" 2696040; is "input 2696040 uA" "$(_iin_ma || echo UNREADABLE)" 2696
# once a node has been seen in microamps, a small reading from THAT node is a taper, not milliamps
wnl "$W/usb/input_current_now" 5353;    is "input taper after uA history" "$(_iin_ma || echo UNREADABLE)" 5
inputAmpFactor=1000; wnl "$W/usb/input_current_now" 1800
is "input with an explicit mA factor"   "$(_iin_ma || echo UNREADABLE)" 1800
inputAmpFactor=

# ---- 3: a unit that cannot be proven -------------------------------------------------------------
read_status(){ echo Charging; }
battStatusWorkaround=false; idleThreshold=10; curThen=$W/.mcc
wnl "$battStatus" Charging; wnl "$curThen" 0
ampFactor=; ampFactor_=

# no measurement node anywhere reads >= 16000, so milliamps is the only consistent reading
wnl "$currFile" -895; wnl "$W/bms/current_now" -900
is "factor with no microamp evidence"   "$(current_factor)" 1000
status; is "status on a mA phone with no proof" "$_status" Charging

# a microamp gauge that carries the current is proof, and it wins
wnl "$currFile" -1850000; wnl "$W/bms/current_now" -1850000
ampFactor=; ampFactor_=
is "factor with a microamp reading"     "$(current_factor)" 1000000
ampFactor=; ampFactor_=; status; is "status on a uA phone" "$_status" Charging

# Each shape below is a different phone. A proven unit is remembered per node (dataDir), which is
# right on one phone and wrong across the simulated ones, so forget it between them.
rm -f "$W/.current-unit"
# the OnePlus 7 Pro shape: battery in mA, second gauge in uA, ~1000x apart
wnl "$currFile" -895; wnl "$W/bms/current_now" -822265
ampFactor=; ampFactor_=
is "factor, mA battery beside a uA gauge" "$(current_factor)" 1000

# the OnePlus 8 Pro shape (kona, oplus): mA battery, uA input node, and NO bms to compare against.
# Only a ratio near 1000 may settle it - input and battery current differ physically by at most
# about 3x, so 500-2000x is a unit difference, not physics.
rm -f "$W/.current-unit"
rm -f "$W/bms/current_now"
wnl "$currFile" -1500; wnl "$W/usb/input_current_now" 1650000
ampFactor=; ampFactor_=
is "factor, mA battery beside a uA input node" "$(current_factor)" 1000

# and the shape that must NOT resolve: a uA phone idling at 8 mA while the charger runs the load.
# 2000000/8000 is 250x, which is a plausible physical ratio, so there is no verdict to give.
rm -f "$W/.current-unit"
wnl "$currFile" -8000; wnl "$W/usb/input_current_now" 2000000
ampFactor=; ampFactor_=
is "factor, uA phone under load - no verdict" "$(current_factor)" ""
rm -f "$W/usb/input_current_now"

# zero needs no factor at all
wnl "$currFile" 0; wnl "$W/bms/current_now" 0
ampFactor=; ampFactor_=
status; is "status at exactly zero current" "$_status" Charging

# ---- 4: the charger wattage must use the BUS voltage ---------------------------------------------
# Pixel 6a at 9V PD: main-charger/voltage_now reads the pack (4.03V) while the bus is at 8.95V.
# 1.56A x 4.04V reported 6.30W "from charger" while the pack was taking 11.31W, so consumed_watts
# came out at -5.01W - a charger delivering less than the battery receives.
mkdir -p "$W/main-charger" "$W/tcpm"
wnl "$W/main-charger/online" 1; wnl "$W/main-charger/voltage_now" 4033125
wnl "$W/tcpm/online" 1; wnl "$W/tcpm/voltage_now" 8950000
wnl "$W/usb/online" 1; wnl "$W/usb/voltage_now" 8925000
online_f(){ printf '%s
' "$W/main-charger/online" "$W/tcpm/online" "$W/usb/online"; }
_se_bus_mv 4033 4030;  is "battery-side supply voltage is replaced by the bus" "$_sebus" 8950
_se_bus_mv 8950 4030;  is "a real bus voltage is kept"                        "$_sebus" 8950
_se_bus_mv 7280 4200;  is "7.28V HVDCP3 beside a 4.2V pack is kept"           "$_sebus" 7280
_se_bus_mv null 4030;  is "an unreadable supply voltage stays unreadable"     "$_sebus" null
_se_bus_mv 4033 null;  is "no pack voltage to compare against, no rewrite"    "$_sebus" 4033
online_f(){ :; }
_se_bus_mv 4033 4030;  is "battery-side voltage with no other supply online"  "$_sebus" 4033

# ---- 6: cc_now must not be the daemon's single point of failure ----------------------------------
# Fairphone 5 (lahaina / qti_battery_charger over pmic_glink), 2026-09-09 bundle. /dev/.vr25/acc
# held NO .cc_then after 78576s of uptime, and nothing under install/ ever removes that file -- it
# is written on every pass where cc_now returns above zero. So cc_now answered 0 for the whole
# boot. On the SAME phone /data/adb/vr25/acc-data/.se-cc was present and state.json carried
# "ccDir":"falling", and _se_ccdir reads the counter out of battery/uevent rather than out of the
# per-property attribute file. One source worked and the other did not.
#
# That matters far past one missing figure. The coulomb counter is the only sign-convention-free
# arbiter ACC has. With it silent, and no learned _DPOL, idle_discharging falls through to the
# kernel status node -- the one signal that phone lies with -- and answered Charging while the
# pack drained at 1.33A and the SoC walked 23 -> 21%.
#
# So cc_now falls back to the uevent, which is the same value from the same driver and is proven
# readable on the phone where the attribute is not. The fallback is on the FAILURE path only: a
# phone whose attribute reads keeps the fork-free builtin read rc19 established.
uev="$W/battery/uevent"
rm -f "$W/battery/charge_counter"
wnl "$uev" "POWER_SUPPLY_NAME=battery
POWER_SUPPLY_STATUS=Charging
POWER_SUPPLY_CHARGE_COUNTER=749841
POWER_SUPPLY_CAPACITY=21"
is "cc_now, attribute absent, uevent carries it"   "$(cc_now)" 749841
: > "$W/battery/charge_counter"
is "cc_now, attribute empty, uevent carries it"    "$(cc_now)" 749841
wnl "$W/battery/charge_counter" "not-a-number"
is "cc_now, attribute garbage, uevent carries it"  "$(cc_now)" 749841
# The attribute still wins when it works: the fallback must never override a live reading.
wnl "$W/battery/charge_counter" 594000
is "cc_now, attribute readable, uevent ignored"    "$(cc_now)" 594000
# Neither source: still 0, so every caller keeps its status-only path.
rm -f "$W/battery/charge_counter" "$uev"
is "cc_now, no source at all"                      "$(cc_now)" 0
# A signed coulomb counter stays refused, from either source.
wnl "$uev" "POWER_SUPPLY_CHARGE_COUNTER=-594000"
is "cc_now, negative counter in the uevent"        "$(cc_now)" 0
rm -f "$uev"

# ---- 7: THE COUNTER MUST TRACK THE BATTERY, not merely be readable -------------------------------
# Fairphone 5, second field bundle (2026-09-09 17:42), on the build that was supposed to have fixed
# this. battery/charge_counter read 2667961 -- the SAME value as in the 10:34 bundle seven hours and
# thirty-two capacity points earlier. It is a frozen register. The uevent copy tracked the pack:
#
#   bundle 1  cap 21%  charge_full 3542000  ->  expected 743820   uevent 749841    attribute 2667961
#   bundle 2  cap 53%  charge_full 3546000  ->  expected 1879380  uevent 1868032   attribute 2667961
#
# The earlier fallback only fired when the attribute read FAILED. Here it succeeds and returns a
# wrong constant, so the fallback never engaged: the counter looked flat forever, ccDir stuck at
# "flat", polarity latched "unstable", and _se_class then had nothing left but the lying status
# word -- which is what put "charging" and a wattage on a phone that was draining while plugged.
#
# So validate against the gauge's own arithmetic: capacity% of charge_full. Whichever source is
# closer to that wins. Where both agree (every phone tested here) nothing changes.
uev="$W/battery/uevent"
ccsrc="${TMPDIR:-/dev}/.cc-src"
fp5(){ rm -f "$ccsrc"
  wnl "$W/battery/capacity" "$1"; wnl "$W/battery/charge_full" "$2"
  if [ ".$3" = .- ]; then rm -f "$W/battery/charge_counter"; else wnl "$W/battery/charge_counter" "$3"; fi
  if [ ".$4" = .- ]; then rm -f "$uev"; else wnl "$uev" "POWER_SUPPLY_CHARGE_COUNTER=$4"; fi
}

fp5 53 3546000 2667961 1868032
is "FP5: frozen attribute loses to the live uevent" "$(cc_now)" 1868032
fp5 21 3542000 2667961 749841
is "FP5: same verdict at the other end of the log"  "$(cc_now)" 749841

# The control that matters for every other phone: sources agree, so nothing changes.
fp5 50 3000000 1500000 1500000
is "agreeing sources: unchanged"                     "$(cc_now)" 1500000
fp5 50 3000000 1499000 1501000
is "trivially different sources: closer one wins"    "$(cc_now)" 1499000

# Without the arithmetic there is nothing to validate against, so behaviour must not change.
fp5 50 0 2667961 1868032
is "no charge_full: attribute still wins (unchanged)" "$(cc_now)" 2667961
rm -f "$W/battery/capacity"
wnl "$W/battery/charge_full" 3546000; wnl "$W/battery/charge_counter" 2667961
wnl "$uev" "POWER_SUPPLY_CHARGE_COUNTER=1868032"
rm -f "$ccsrc"
is "no capacity: attribute still wins (unchanged)"   "$(cc_now)" 2667961

# The decision is cached per device, so the check costs nothing after the first pass.
fp5 53 3546000 2667961 1868032
cc_now > /dev/null
is "the winning source is cached"                    "$(cat "$ccsrc" 2>/dev/null)" uevent

# Absent sources still degrade the way they did before.
fp5 53 3546000 - 1868032
is "attribute absent: uevent carries it"             "$(cc_now)" 1868032
fp5 53 3546000 2667961 -
is "uevent absent: attribute is all there is"        "$(cc_now)" 2667961
fp5 53 3546000 - -
is "neither source: 0"                               "$(cc_now)" 0
rm -f "$ccsrc" "$uev"

# ---- 8: A COARSE COUNTER MUST STILL BE ABLE TO RULE ----------------------------------------------
# Fairphone 5, 17:42 bundle: ccDir read "flat" while the pack drained at 0.3-0.8 A with the cable
# in. The source was fine -- state-export already reads the counter from battery/uevent -- but the
# window never grew. _se_ccdir rewrote its stamp on EVERY call, so with the daemon publishing every
# few seconds the window was always ~4 s. A fuel gauge that updates charge_counter in coarse steps
# shows d=0 across a 4 s window, so the answer was "flat" forever, the arbiter never ruled, polarity
# stayed latched "unstable", and _se_class fell through to the status word this kernel lies with.
#
# Keep the anchor until the counter actually MOVES (or the window goes stale past 90 s). A gauge
# that steps every call is unaffected; a coarse one accumulates a real delta and gets to rule.
CC="$W/cc-cache"
ccd(){ SE_CCCACHE="$CC" _se_ccdir "$1"; }
stamp(){ printf '%s %s
' "$1" "$(( $(date +%s) - $2 ))" > "$CC"; }

# THE DISCRIMINATING CASE: consecutive polls, no manual re-stamping between them. That is what the
# daemon actually does, and it is where the old code lost the window.
rm -f "$CC"; ccd 1868032 >/dev/null
stamp 1868032 12                              # anchor is 12s old
is "poll 2, counter has not moved"            "$(ccd 1868032)" flat
A=$(cat "$CC"); AGE=$(( $(date +%s) - ${A##* } ))
[ "$AGE" -ge 10 ] && ok "the 12s anchor SURVIVES a no-change poll (age now ${AGE}s)"                   || no "the anchor was reset by a no-change poll (age ${AGE}s) - the window can never grow"
# now the coarse gauge finally steps, with no manual re-stamp: the kept window must let it rule
is "poll 3, the counter steps down -> falling" "$(ccd 1863032)" falling

rm -f "$CC"; ccd 1868032 >/dev/null
stamp 1868032 12
ccd 1868032 >/dev/null
is "poll 3, the counter steps up -> rising"    "$(ccd 1873032)" rising

# a fine gauge that moves every call still behaves exactly as before
stamp 1000000 10
is "fine gauge, moved down"                   "$(ccd 994000)" falling
stamp 1000000 10
is "fine gauge, moved up"                     "$(ccd 1006000)" rising

# a stale anchor is re-taken rather than trusted forever
stamp 1868032 600
is "stale anchor (600s) cannot rule"          "$(ccd 1868032)" unknown
B=$(cat "$CC")
_age=$(( $(date +%s) - ${B##* } )); [ "$_age" -le 1 ] 2>/dev/null && _age=0
is "a stale anchor is refreshed"              "$_age" 0

# an impossible jump is still refused
stamp 1000000 10
is "impossible jump refused"                  "$(ccd 90000000)" unknown

# Genuine garbage is still refused BY THE PATH THAT USES IT. status() consults the current only to
# feed idle_discharging; with battStatusWorkaround off the answer is the kernel status word and the
# reading is never consulted, which is why refusing there stranded a paused phone (see status()).
wnl "$currFile" "not-a-number"; ampFactor=1000; ampFactor_=1000
battStatusWorkaround=true
status; _rc=$?
{ [ "$_status" = Unknown ] && [ "$_rc" = 1 ]; } \
  && ok "with inference on, a garbage current is refused (Unknown, rc=1)" \
  || no "garbage current gave [$_status] rc=$_rc, want Unknown rc=1"
battStatusWorkaround=false
status; _rc=$?
{ [ "$_status" = Charging ] && [ "$_rc" = 1 ]; } \
  && ok "with inference off, the kernel word survives a garbage current" \
  || no "garbage current with inference off gave [$_status] rc=$_rc, want Charging rc=1"

fin
