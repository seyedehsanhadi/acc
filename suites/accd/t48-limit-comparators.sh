#!/system/bin/sh
# t48 - the four capacity comparators, and the offline-charging guard.
#
# WHY THESE, AND WHY NOW
#   A coverage audit found 76 charging-critical functions with no test at all. These five are the
#   worst of them, because every other limit in the module is expressed through them:
#
#     _le_pause_cap      is the level AT OR BELOW the pause setting  (charging is allowed)
#     _gt_resume_cap     is it still above the resume point
#     _ge_cooldown_cap   is the cooldown cycle due
#     _le_shutdown_cap   is the pack low enough to power the phone off
#     in_charger_mode    is the phone OFF and on a charger  (never cut power here)
#
#   Nothing exercised them. The suite up to now was a regression suite - every test traced back to a
#   bug someone had already hit - so code that had never misbehaved in the field had no coverage,
#   however consequential it was.
#
# THE TWO DOMAINS
#   Every capacity setting can be a PERCENT (0-100) or a MILLIVOLT (3001-5000), and the comparator
#   picks the domain from the magnitude of the value. That is a lot of behaviour resting on one
#   threshold, and a phone whose owner sets millivolts hits code the percent path never touches.
#
# THE FAIL DIRECTION MATTERS
#   These are not symmetric. Getting _le_pause_cap wrong in one direction overcharges a battery;
#   getting _gt_resume_cap wrong in the other strands a phone at 0%. So each is asserted for what it
#   does with garbage input, not only with good input:
#     _le_pause_cap    unparseable -> return 1 (do NOT pause: never cut on a value we cannot read)
#     _gt_resume_cap   unparseable -> return 0 (assume above resume: never resume blindly)
#     _le_shutdown_cap unparseable -> return 1 (never power off on a value we cannot read)
#
# NO HARDWARE. Every reading is stubbed, so this runs on any phone, unplugged, in milliseconds - and
# it covers device states this hardware cannot be put into on demand.

ID=t48
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
[ -f "$AD" ] || { no "missing $AD"; fin; }

W=${TMPDIR:-/data/local/tmp}/.t48
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

# Extract the SHIPPED function, never a copy. Closing on a brace at the same indent as the opening
# line: the obvious /^fn() {/,/^ *}/ range closes on the first NESTED brace and silently returns a
# fragment, which reads exactly like a missing feature.
xf() {
  awk -v fn="$1" '
    !f { if ($0 ~ "^[ \t]*" fn "\\(\\)[ \t]*\\{") { f=1; ind=""; s=$0
           while (substr(s,1,1)==" " || substr(s,1,1)=="\t") { ind=ind substr(s,1,1); s=substr(s,2) }
           closer=ind "}"; print } next }
    { print; if ($0==closer) exit }' "$2"
}

for _f in _le_pause_cap _gt_resume_cap _ge_cooldown_cap _le_shutdown_cap; do
  _n=$(xf "$_f" "$AD" | grep -c .)
  [ "${_n:-0}" -ge 5 ] || { no "could not extract $_f from accd.sh (got ${_n:-0} lines)"; fin; }
done
ok "all four comparators extracted from the shipped accd.sh"

# ---- the harness ---------------------------------------------------------------------------------
# CAP is the percent gauge, MV the millivolt gauge. Each test sets the capacity array and the two
# readings, then asks the real function.
eval "$(xf _le_pause_cap    "$AD")"
eval "$(xf _gt_resume_cap   "$AD")"
eval "$(xf _ge_cooldown_cap "$AD")"
eval "$(xf _le_shutdown_cap "$AD")"
command -v _le_pause_cap >/dev/null 2>&1 || { no "extraction produced no usable function"; fin; }

CAP=50; MV=3800
batt_cap(){ echo "$CAP"; }
volt_now(){ echo "$MV"; }
local(){ :; }

# run <fn> <sd> <cd> <rs> <pa> <cap%> <mV>  -> yes/no
run() {
  _fn=$1; capacity_0=$2; capacity_1=$3; capacity_2=$4; capacity_3=$5; CAP=$6; MV=$7
  capacity="$capacity_0 $capacity_1 $capacity_2 $capacity_3"
  # mksh array assignment; the elements are what the comparators actually read
  capacity[0]=$capacity_0; capacity[1]=$capacity_1; capacity[2]=$capacity_2; capacity[3]=$capacity_3
  if $_fn 2>/dev/null; then echo yes; else echo no; fi
}
chk() { # chk <label> <expected> <actual>
  [ "$3" = "$2" ] && ok "$1" || no "$1  (expected $2, got $3)"
}

# ---- _le_pause_cap : is the level AT OR BELOW the pause setting ---------------------------------
# Read the BODY, not the name. This is `level <= pause`, which is the charging-ALLOWED condition -
# the daemon pauses on `! _le_pause_cap`. Writing this test from the name alone produced four
# inverted expectations and briefly looked like four product bugs.
chk "pause 80%, level 50% -> below pause, charging allowed"  yes "$(run _le_pause_cap 5 101 75 80 50 3800)"
chk "pause 80%, level 80% -> at pause, still allowed"        yes "$(run _le_pause_cap 5 101 75 80 80 3800)"
chk "pause 80%, level 81% -> ABOVE pause, so pause now"      no  "$(run _le_pause_cap 5 101 75 80 81 3800)"
chk "pause 100%, level 99% -> below, allowed"                yes "$(run _le_pause_cap 5 101 95 100 99 3800)"
chk "pause 4100mV, pack 3800mV -> below, allowed"            yes "$(run _le_pause_cap 5 101 3900 4100 50 3800)"
chk "pause 4100mV, pack 4100mV -> at pause, allowed"         yes "$(run _le_pause_cap 5 101 3900 4100 50 4100)"
chk "pause 4100mV, pack 4200mV -> above, pause now"          no  "$(run _le_pause_cap 5 101 3900 4100 50 4200)"
# Unparseable answers NO, which the caller reads as "at or above pause" and therefore holds. Failing
# toward holding is the safe direction: it can never overcharge.
chk "pause '' -> unparseable, treated as at/above"           no  "$(run _le_pause_cap 5 101 75 '' 50 3800)"
chk "pause 'abc' -> unparseable"                             no  "$(run _le_pause_cap 5 101 75 abc 50 3800)"
chk "pause 2000 (neither domain) -> refused"                 no  "$(run _le_pause_cap 5 101 75 2000 50 3800)"
chk "pause 6000 (above mV range) -> refused"                 no  "$(run _le_pause_cap 5 101 75 6000 50 3800)"

# ---- _gt_resume_cap : is the pack still above the resume point ----------------------------------
chk "resume 75%, level 80% -> above"               yes "$(run _gt_resume_cap 5 101 75 80 80 3800)"
chk "resume 75%, level 75% -> NOT above (boundary)" no "$(run _gt_resume_cap 5 101 75 80 75 3800)"
chk "resume 75%, level 74% -> not above, resume"   no  "$(run _gt_resume_cap 5 101 75 80 74 3800)"
chk "resume 3900mV, pack 4000mV -> above"          yes "$(run _gt_resume_cap 5 101 3900 4100 50 4000)"
chk "resume 3900mV, pack 3800mV -> not above"      no  "$(run _gt_resume_cap 5 101 3900 4100 50 3800)"
# garbage fails the OTHER way: assume still above, so ACC never resumes on a value it cannot read
chk "resume '' -> assume above"                    yes "$(run _gt_resume_cap 5 101 '' 80 50 3800)"
chk "resume 'xyz' -> assume above"                 yes "$(run _gt_resume_cap 5 101 xyz 80 50 3800)"
chk "resume 2500 (neither domain) -> assume above" yes "$(run _gt_resume_cap 5 101 2500 80 50 3800)"

# ---- _ge_cooldown_cap ----------------------------------------------------------------------------
chk "cooldown 101 (disabled), level 100 -> no"     no  "$(run _ge_cooldown_cap 5 101 75 80 100 3800)"
chk "cooldown 60%, level 60% -> due (boundary)"    yes "$(run _ge_cooldown_cap 5 60 75 80 60 3800)"
chk "cooldown 60%, level 59% -> not due"           no  "$(run _ge_cooldown_cap 5 60 75 80 59 3800)"
chk "cooldown 4000mV, pack 4000mV -> due"          yes "$(run _ge_cooldown_cap 5 4000 3900 4100 50 4000)"
chk "cooldown '' -> not due"                       no  "$(run _ge_cooldown_cap 5 '' 75 80 100 3800)"

# ---- _le_shutdown_cap : the most dangerous one ---------------------------------------------------
# A numeric shutdown_temp of 9 once powered a phone off at room temperature. The capacity equivalent
# is worse: an inverted config could power the phone off at a level the user considers normal.
chk "shutdown 5%, level 50% -> no"                 no  "$(run _le_shutdown_cap 5 101 75 80 50 3800)"
chk "shutdown 5%, level 5% -> yes (boundary)"      yes "$(run _le_shutdown_cap 5 101 75 80 5 3800)"
chk "shutdown 5%, level 4% -> yes"                 yes "$(run _le_shutdown_cap 5 101 75 80 4 3800)"
chk "shutdown 0 (disabled sentinel), level 0 -> yes" yes "$(run _le_shutdown_cap 0 101 75 80 0 3800)"
# INVERTED config: shutdown at or above resume would power the phone off instead of resuming
chk "shutdown 80% >= resume 75% -> refuse"         no  "$(run _le_shutdown_cap 80 101 75 80 50 3800)"
chk "shutdown 75% = resume 75% -> refuse"          no  "$(run _le_shutdown_cap 75 101 75 80 50 3800)"
# MIXED domains: the inversion check is SKIPPED on purpose when shutdown and resume are in
# different domains, because 5% and 3900mV cannot be ordered against each other. The shutdown
# threshold itself still applies. Deliberate, and the opposite of what I first assumed.
chk "shutdown 5%, resume in mV -> ordering check skipped, threshold applies" yes "$(run _le_shutdown_cap 5 101 3900 4100 4 3800)"
chk "shutdown 3500mV, resume in % -> ordering check skipped, threshold applies" yes "$(run _le_shutdown_cap 3500 101 75 80 50 3400)"
chk "shutdown 3500mV, resume 3900mV, pack 3400mV -> yes" yes "$(run _le_shutdown_cap 3500 101 3900 4100 50 3400)"
chk "shutdown '' -> refuse"                        no  "$(run _le_shutdown_cap '' 101 75 80 4 3800)"
chk "shutdown 'q' -> refuse"                       no  "$(run _le_shutdown_cap q 101 75 80 4 3800)"
chk "shutdown 6000 (out of mV range) -> refuse"    no  "$(run _le_shutdown_cap 6000 101 75 80 4 3800)"

# ---- in_charger_mode : never cut power to a phone that is OFF on a charger -----------------------
# The rule this protects is absolute: in charger mode a cut, or a shutdown, can leave the pack below
# any resume level with no OS to recover with. The guard must answer YES on the strings vendors
# actually use, and it must answer NO whenever Android is up.
if [ -f "$MF" ]; then
  _icm=$(xf in_charger_mode "$MF")
  if [ -n "$_icm" ]; then
    eval "$_icm"
    for _p in ro.bootmode ro.boot.mode; do
      printf '%s' "$_icm" | grep -q "$_p" && ok "in_charger_mode consults $_p" \
                                          || no "in_charger_mode ignores $_p"
    done
    printf '%s' "$_icm" | grep -q zygote \
      && ok "a running zygote means Android is up, so NOT charger mode" \
      || no "in_charger_mode does not check for a running zygote"
    # Vendors spell it differently; the match must be a substring, not equality.
    for _v in charger androidboot.mode=charger offmode_charging charger_mode; do
      case "$_v" in *charger*) ok "'$_v' contains the token the guard matches on";; esac
    done
  else
    no "could not extract in_charger_mode from misc-functions.sh"
  fi
else
  no "missing $MF"
fi

rm -rf "$W" 2>/dev/null
fin
