#!/system/bin/sh
# Run the daemon's actual branch condition and resume block with private controls.
execDir=${execDir:-/data/adb/vr25/acc}
W=${TMPDIR_T:-/data/local/tmp}/owned-hold-$$
mkdir -p "$W"; cd "$W" || exit 2
TMPDIR=$W; dataDir=$W
trap 'cd /; rm -rf "$W"' EXIT
route=$(sed -n '/^      if is_charging.*; then/p' "$execDir/accd.sh")
[ -n "$route" ] || exit 2
resume=$(sed -n '/^        if \$xIdle && _le_pause_cap/,/^        # auto-shutdown/p' "$execDir/accd.sh" | sed '$d')
[ -n "$resume" ] || exit 2
is_charging(){ $sense; }
_le_resume_cap(){ $due; }
_temp_hold(){ [ "$temp" -ge 500 ]; }
temp_now(){ echo "$temp"; }
enable_charging(){ released=true; chDisabledByAcc=false; }
disable_charging(){ released=false; }
present(){ false; }
cc_now(){ echo 0; }
sleep(){ :; }
xIdle=false; temperature=(45 50 40 55); loopDelay=(0 0)
maxChargingCurrent=(); capacity=(5 101 70 75 false)
P=0; F=0
check(){
 sense=$1; chDisabledByAcc=$2; due=$3; temp=$4; released=false
 eval "$route :; else $resume; fi"
 if [ "$released" = "$5" ]; then P=$((P+1)); echo "PASS $6"; else F=$((F+1)); echo "FAIL $6"; fi
}
check true true true 300 true 'false Charging cannot strand an owned hold below resume'
check true true true 400 true 'owned hold resumes at the resume temperature'
check true true true 410 false 'owned hold stays paused above the resume temperature'
check true true false 300 false 'owned hold stays paused above resume capacity'
check true false true 300 false 'a healthy charge needs no release'
check false true true 300 true 'ordinary discharge resume is retained'
check false true false 300 false 'ordinary discharge hold is retained'
handoff=$(sed -n '/^    if \[ -f \$TMPDIR\/.sw \]/,/^    fi/p' "$execDir/misc-functions.sh")
[ -n "$handoff" ] || exit 2
flip_sw(){ flipped="${chargingSwitch[*]}"; }
resume_handoff(){ eval "$handoff"; }
chargingSwitch=(battery/input_suspend 0 1 --)
echo 'chargingSwitch=()' > "$TMPDIR/.sw"
resume_handoff
if [ "$flipped" = 'battery/input_suspend 0 1 --' ]; then P=$((P+1)); echo 'PASS empty handoff releases the original switch'; else F=$((F+1)); echo 'FAIL empty handoff loses the original switch'; fi
echo 'chargingSwitch=(battery/charging_enabled 1 0)' > "$TMPDIR/.sw"
resume_handoff
if [ "$flipped" = 'battery/charging_enabled 1 0' ]; then P=$((P+1)); echo 'PASS a selected handoff switch is released'; else F=$((F+1)); echo 'FAIL selected handoff ignored'; fi
avoid=$(sed -n '/^          if ! \$allowIdleAbovePcap/,/; then/p' "$execDir/accd.sh")
[ -n "$avoid" ] || exit 2
allowIdleAbovePcap=false; xIdleCount=0
cap_idle_threshold(){ true; }
: > "$dataDir/.user-locked"
eval "$avoid scanned=true; else scanned=false; fi"
if ! $scanned; then P=$((P+1)); echo 'PASS idle avoidance respects a user-locked switch'; else F=$((F+1)); echo 'FAIL idle avoidance replaces a user-locked switch'; fi
rm "$dataDir/.user-locked"
eval "$avoid scanned=true; else scanned=false; fi"
if $scanned; then P=$((P+1)); echo 'PASS automatic idle avoidance remains available'; else F=$((F+1)); echo 'FAIL automatic idle avoidance disabled'; fi
echo "t-owned-hold-resume: $P passed, $F failed"
[ "$F" = 0 ]
