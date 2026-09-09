#!/system/bin/sh
# t-field-reports-0908 - the three field reports of 2026-09-08, each pinned by the shape that
# produced it. Every fixture here is taken from a real diagnostic bundle.
#
#   OnePlus 8 Pro (IN2023, kona, oplus), AMPS 7.3.1
#     "unit corrected to uA (ctrl node .../constant_charge_current=3000000)" -> baseline BYPASS ->
#     "could NOT reach native charging". battery/current_now is mA on that phone; every control node
#     is uA; and unlike the OnePlus 7 Pro there is no bms supply to cross-check against. Covered by
#     suites/amps/t-units.sh and t-reader-hardening.sh; what is pinned HERE is the consequence the
#     user saw: an empty chargingSwitch with nothing in the logs to explain it.
#
#   Fairphone 5 (lahaina), rc24
#     a) exported input: "voltageMv":15000 with the phone UNPLUGGED. usb/voltage_now read 18000 -
#        18 mV of noise on a microvolt node - and the "under 100000 means it is already mV" fallback
#        turned that into 18 V, which the 1-50 V sanity check then accepted. The same number reaches
#        the re-kick guard, whose high-voltage latch is 6.5 V.
#     b) cutByAcc stayed true for 174 consecutive flight records while unplugged and draining from
#        44% to 36%. switch_release_observed answers false for any switch that is not an input cut
#        (this phone uses charging_enabled), and with no charger there is never a later pass with
#        real charging current to clear it. ACC then believed it already owned a cut at the next
#        plug-in: "shows charging, stays at the same percentage", cured by a daemon restart.
#
# NO HARDWARE. Production functions are lifted from the build under test and run against files.

ID=t-field-reports-0908
execDir=${execDir:-install}
execDir=$(cd "$execDir" && pwd)
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
is(){ [ "$2" = "$3" ] && ok "$1 -> $2" || no "$1 -> got [$2], want [$3]"; }

W=$(mktemp -d "${TMPDIR:-/data/local/tmp}/field-0908.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT HUP INT TERM
wnl(){ mkdir -p "${1%/*}"; printf '%s\n' "$2" > "$1"; }

. "$execDir/state-export.sh"

# ---- FP5 (a): a supply voltage of 18 mV is not an 18 V bus ----------------------------------------
_se_voltage_mv 18000 "" bus;      is "usb/voltage_now=18000 (18mV noise) is not a bus voltage" "$_semv" null
_se_voltage_mv 15000 "" bus;      is "15000 uV likewise"                                       "$_semv" null
_se_voltage_mv 9000000 "" bus;    is "a real 9V bus survives"                                  "$_semv" 9000
_se_voltage_mv 5000000 "" bus;    is "a real 5V bus survives"                                  "$_semv" 5000
_se_voltage_mv 7280960 "" bus;    is "7.28V HVDCP3 survives"                                   "$_semv" 7280
# the pack's own node keeps the old behaviour: some kernels really do publish millivolts there
_se_voltage_mv 3715486;           is "pack voltage in uV"                                      "$_semv" 3715
_se_voltage_mv 3715;              is "pack voltage already in mV"                              "$_semv" 3715

# ---- FP5 (a): a supply that never said it was online cannot supply the input reading --------------
ACC_PSY=$W
wnl "$W/usb/online" 0; wnl "$W/usb/voltage_now" 18000; wnl "$W/usb/current_now" 0
wnl "$W/wireless/online" 0; wnl "$W/wireless/current_now" 255000
mkdir -p "$W/main"; wnl "$W/main/current_now" 0; wnl "$W/main/voltage_now" 18000   # no online node at all
_in=$(_se_input)
case "$_in" in
  *'"voltageMv":null'*) ok "no online supply -> the exported input is null, not a phantom bus" ;;
  *) no "exported input from an offline phone: $_in" ;;
esac
wnl "$W/usb/online" 1; wnl "$W/usb/voltage_now" 9000000; wnl "$W/usb/current_now" 1500000
_in=$(_se_input)
case "$_in" in
  *'"voltageMv":9000'*) ok "a genuinely online supply still reports its bus voltage" ;;
  *) no "online supply reported: $_in" ;;
esac

# ---- FP5 (b): the cut flag cannot survive the charger being gone ----------------------------------
# The tail of enable_charging, lifted verbatim.
_blk=$(sed -n '/if not_charging && present; then/,/^    fi$/p' "$execDir/misc-functions.sh")
[ -n "$_blk" ] || { no "could not lift the chDisabledByAcc block from enable_charging"; fin; }
_run(){ # $1 not_charging  $2 present  $3 switch_release_observed -> the flag afterwards
  ( chDisabledByAcc=true
    eval "not_charging(){ return $1; }; present(){ return $2; }; switch_release_observed(){ return $3; }"
    eval "$_blk"
    echo "$chDisabledByAcc" ) 2>/dev/null
}
is "unplugged, not charging, switch not an input cut" "$(_run 0 1 1)" false
is "unplugged, not charging, release observed"        "$(_run 0 1 0)" false
is "plugged, not charging, release NOT observed"      "$(_run 0 0 1)" true
is "plugged, not charging, release observed"          "$(_run 0 0 0)" false
is "plugged and charging again"                       "$(_run 1 0 1)" false

# ---- OnePlus 8 Pro: a stub current sensor must not make every switch look like it works ----------
# current_now is pinned at 0 on that phone while the kernel says Charging and the pack fills. The
# old first line of idle_discharging returned Idle before the coulomb arbitration could see it, so
# not_charging was true whatever the phone did, the first switch candidate "held", and the daemon
# pinned wireless/op_disable_charge - a WIRELESS node - on a wired charger. AMPS then reported that
# same node as "no effect".
eval "$(sed -n '/^idle_discharging() {/,/^}/p' "$execDir/batt-interface.sh")"
_id(){ # $1 curNow  $2 counter-now  $3 counter-then  $4 age(s)  $5 _DPOL -> the verdict
  # $2 inside cc_now() would be cc_now's OWN second argument, not this function's: the counter has
  # to travel in a variable or the arbitration never sees a reading and every case answers Idle.
  ( TMPDIR=$W; idleThreshold=10; curNow=$1; _CCNOW=$2; _DPOL=$5; _kstatus=Charging; _status=
    cc_now(){ echo "$_CCNOW"; }; present(){ return 0; }; eq(){ return 1; }
    printf '%s %s
' "$3" "$(( $(date +%s) - $4 ))" > "$W/.cc_then"
    idle_discharging >/dev/null 2>&1
    echo "$_status" ) 2>/dev/null
}
is "stub sensor at 0, counter climbing"        "$(_id 0 2758000 2757000 10 +)" Charging
is "stub sensor at 0, counter flat (a bypass hold stays a hold)" "$(_id 0 2758000 2758000 10 +)" Idle
is "stub sensor at 0, counter falling"         "$(_id 0 2757000 2758000 10 +)" Discharging
is "stub sensor at 0, counter window too old"  "$(_id 0 2758000 2757000 200 +)" Idle
is "a real charging current is unaffected"     "$(_id -1752000 2758000 2758000 10 +)" Charging
is "a real discharge is unaffected"            "$(_id 1752000 2757000 2758000 10 +)" Discharging

# ---- Fairphone 5: a one-time charge has to end even if the gauge never reports the target ---------
# `acc -f 100` writes a throwaway config with pause=100 and relies on a ':' hook to hand control
# back. The hook asked only "is the level at or above the target", so an aged pack that stops short
# of 100 left the daemon pinned at pause=100 with config.txt still reading 88.
_hook=$(grep -m1 "command -v _reexec" "$execDir/acc.sh")
case "$_hook" in
  *read_status*Full*) ok "the one-time-charge hook also ends on the firmware's own Full" ;;
  *) no "the hook still ends only on _ge_pause_cap: a pack that stops short stays overridden" ;;
esac
# and it still has to parse under the device shell, since it is sourced by the daemon
printf '%s
' "$(printf '%s' "$_hook" | sed "s/.*printf '[^']*' '//; s/' >> .*//")" > "$W/hook.sh"
sh -n "$W/hook.sh" 2>/dev/null && ok "the emitted hook parses under /system/bin/sh"                                || no "the emitted hook does not parse: $(cat "$W/hook.sh")"

# ---- OnePlus 8 Pro: a dropped switch has to leave a trace -----------------------------------------
# One key per way a switch can be dropped: charging carried on while ACC had it off, a locked
# switch stopped holding, a resume never came, and a switch that landed on the blocked list.
for _site in swclear-unsolicited swclear-lockfail resume-reselect swblocked; do
  grep -q "$_site" "$execDir/accd.sh" \
    && ok "the switch-clearing path '$_site' records why" \
    || no "'$_site' is missing - a switch can still vanish with no record"
done
# ---- FP5, second report (diag 20260908-111503): a supply cannot draw past its own limit ---------
# usb/current_now=9375000 at voltage_now=8984000 with input_current_limit=5000000, while the pack
# takes 444 mA. wireless/current_now carries the IDENTICAL 9375000 with wireless/online=0, so the
# register is mirrored rather than measured. rc24 printed "power_supply_amps 9.38 / watts 84.23 /
# consumed_watts 82.46" on a phone whose port had negotiated 5 A.
FP=$(mktemp -d "${TMPDIR:-/data/local/tmp}/fp5b.XXXXXX") || exit 1
wnl "$FP/usb/online" 1; wnl "$FP/usb/voltage_now" 8984000; wnl "$FP/usb/current_now" 9375000
wnl "$FP/usb/input_current_limit" 5000000
wnl "$FP/wireless/online" 0; wnl "$FP/wireless/current_now" 9375000
ACC_PSY=$FP; TMPDIR=$FP
rm -f "$FP/.iinmicro"; _se_input_ma 9375000 usb/current_now
is "9.375A behind a 5A limit is not a measurement" "$_sema" null
rm -f "$FP/.iinmicro"; _se_input_ma 2696040 usb/current_now
is "a real 2.696A under the same limit survives" "$_sema" 2696
rm -f "$FP/.iinmicro"; _se_input_ma 5400000 usb/current_now
is "8% of transient overshoot is allowed" "$_sema" 5400
rm -f "$FP/.iinmicro"; wnl "$FP/usb/input_current_limit" 0; _se_input_ma 2696040 usb/current_now
is "an unset limit rejects nothing" "$_sema" 2696
rm -f "$FP/.iinmicro" "$FP/usb/input_current_limit"; _se_input_ma 2696040 usb/current_now
is "no limit node at all rejects nothing" "$_sema" 2696
rm -f "$FP/.iinmicro"; wnl "$FP/usb/input_current_limit" 5000000
_in=$(_se_input)
case "$_in" in
  *'"voltageMv":8984'*'"currentMa":null'*) ok "the 8.98V bus is still reported, only the current is dropped" ;;
  *) no "exported input: $_in" ;;
esac
rm -rf "$FP"
ACC_PSY=$W; TMPDIR=${TMPDIR:-/data/local/tmp}

# ---- FP5, second report: the cut flag survived a full 99%->20% drain while plugged --------------
# flight.log, 1505 records: chDisabledByAcc went true at level 100 (the one-time charge to 100 the
# owner ran), stayed true across an unplug at record 29 (online=0 present=0), and was STILL true at
# record 207 (level 25) and at the tail (level 20, status=Charging, plugged). 164+ records with ACC
# believing it already owned a cut, so enable_charging never wrote the switch back on: "shows
# charging but stays at the percentage". The unplug at record 29 is where the chain has to break.
is "the flight-log unplug clears the flag" "$(_run 0 1 1)" false

# ---- Pixel 6a, live: the one-time charge deadlocked AT its target ---------------------------------
# charge-once to 49% through AccA. The daemon paused correctly and then sat on the throwaway config
# indefinitely: battery/capacity 49, capacity[3] 49, but batt_cap 48, because batt_cap prefers
# Android's level and Android steps back a point as soon as charging stops. The level cannot rise
# again - the pause that answer caused is what stops it - so the restore hook can never fire.
# Same visible symptom as the Fairphone 5 report, with no aged pack required.
eval "$(sed -n '/^  _ge_pause_cap_raw() {/,/^  }/p' "$execDir/accd.sh")"
# Two nodes, disagreeing. $battCapacity is not always battery/capacity: on a Pixel 6a it is
# maxfg/capacity, and at a one-time target of 44% it read 43 while battery/capacity read 44 - so a
# test that asks only the first sits on the throwaway config for ever. Live-reproduced with the
# first version of this fix installed, which is why the rule is now "the highest source wins".
_two() { # $1 = $battCapacity value  $2 = battery/capacity value  $3 = cap  -> reached?
  ( battCapacity=$W/cap2; capacity=(5 101 47 "$3" false)
    echo "$1" > "$W/cap2"
    mkdir -p "$W/psy/battery"; echo "$2" > "$W/psy/battery/capacity"
    # ACC_PSY, not a sed rewrite of the path: the helper now resolves its second source through
    # that variable like the rest of the tree, so the fixture points it at the stub tree instead
    # of patching a literal that no longer exists.
    ACC_PSY=$W/psy; export ACC_PSY
    eval "$(sed -n '/^  _ge_pause_cap_raw() {/,/^  }/p' "$execDir/accd.sh")"
    _ge_pause_cap_raw && echo reached || echo not-yet ) 2>/dev/null
}

# Both level sources have to be STUBBED, or this fixture reads the phone it runs on: the function
# consults battery/capacity as well as $battCapacity, so "unreadable" only means unreadable when
# neither is the live node. That is also why the same case passed on a Mi A3 and failed on a Pixel
# 6a - the A3 refuses that read to a non-root shell, so it looked isolated and was not.
_raw() { # $1 = the level both sources report  $2 = pause cap  -> reached?
  _two "$1" "$1" "$2"
}
is "kernel 49 against a 49 target is reached"        "$(_raw 49 49)" reached
is "kernel 48 against a 49 target is not yet"        "$(_raw 48 49)" not-yet
is "kernel 50 against a 49 target is reached"        "$(_raw 50 49)" reached
is "an unreadable gauge ends the mode (safe side)"   "$(_raw '' 49)" reached
is "a garbage gauge ends the mode"                   "$(_raw abc 49)" reached
is "a garbage target ends the mode"                  "$(_raw 49 xx)" reached
is "a millivolt-shaped target is not treated as a percent" "$(_raw 49 4200)" reached
is "battCapacity lags at 43 while battery/capacity says 44 (Pixel 6a, live)" "$(_two 43 44 44)" reached
is "the other way round is equally reached"                                  "$(_two 44 43 44)" reached
is "both below the target is still not yet"                                  "$(_two 43 43 44)" not-yet
is "both unreadable ends the mode"                                           "$(_two '' '' 44)" reached
# and the emitted hook must consult it, while still parsing under the device shell
_h=$(grep -m1 "command -v _reexec" "$execDir/acc.sh")
case "$_h" in
  *_ge_pause_cap_raw*_ge_pause_cap*) ok "the restore hook asks the gauge first, then falls back" ;;
  *) no "the hook does not consult _ge_pause_cap_raw: $_h" ;;
esac

fin
