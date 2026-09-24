#!/system/bin/sh
# Replay the shipped routing, latch reset, pause, recovery and resume decisions.
# All hardware/CLI operations are mocked; all writes stay in a private directory.
# The same test runs against the reported build and the fix (execDir selects it).
execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
W=${TMPDIR_T:-/data/local/tmp}/thermal-retry-$$
mkdir -p "$W" || exit 2
TMPDIR=$W; dataDir=$W; config=$W/config
trap 'rm -rf "$W"' EXIT
for fn in _le_resume_cap _lt_pause_cap _ge_pause_cap _temp_hold mt_reached; do
  body=$(sed -n "/^  $fn() {/,/^  }/p" "$AD")
  [ -n "$body" ] || exit 2
  eval "$body"
done
# The baseline has no new helper; its actual gates call mt_reached instead.
eval "$(sed -n '/^  _thermal_hold_active() {/,/^  }/p' "$AD")"
route=$(sed -n '/^      if is_charging.*; then/p' "$AD")
head=$(sed -n '/^        xIdle=false$/,/^        # disable charging after a reboot/p' "$AD" | sed '$d')
pause=$(sed -n '/^        if .* || _ge_pause_cap; then/p' "$AD")
resume=$(sed -n '/^        elif _le_resume_cap && /,/^          _temp_hold || enable_charging$/p' "$AD")
monitor=$(awk '/^          if present && / { p=1 } p { print; if ($0 == "          fi 2>/dev/null || :") exit }' "$AD")
for block in "$route" "$head" "$pause" "$resume" "$monitor"; do
  [ -n "$block" ] || { echo 'FAIL missing source block'; exit 2; }
done
case "$monitor" in *'ctrl_charging()'*|*'force_off()'*) echo 'FAIL unbounded extraction'; exit 2;; esac
temperature_now(){ echo "$temp"; }
temp_now(){ echo "$temp"; }
batt_cap(){ echo "$level"; }
volt_now(){ echo "$voltage"; }
is_charging(){ $flow; }
not_charging(){ ! $flow; }
present(){ $attached; }
sleep(){ :; }
cc_now(){ echo 0; }
disable_charging(){ cuts=$((cuts+1)); chDisabledByAcc=true; }
enable_charging(){ released=true; chDisabledByAcc=false; }
warn_once_per(){ warning=$1; }
notif(){ :; }
printf '#!/system/bin/sh\nexit 0\n' > "$W/acca"
chmod 700 "$W/acca"
P=0; F=0
ok(){ P=$((P+1)); echo "PASS $*"; }
no(){ F=$((F+1)); echo "FAIL $*"; }
reset_case(){
  rm -f "$W/.user-locked" "$W/.lockfail-count" "$W/.sw-blacklist" "$W/.breach" "$W/.autolock-count" "$W/.autolock-gaveup"
  capacity=(5 101 70 75 false); temperature=(35 40 30 50); loopDelay=(0 0)
  chargingSwitch=(battery/charging_enabled 1 0 --)
  level=17; voltage=3800; temp=410; mtReached=true; chDisabledByAcc=true
  flow=true; attached=true; warning=; cuts=0; released=false
}
tick(){
  cuts=0; released=false
  eval "$route
    $head
    $pause
      disable_charging || :
      $monitor
    fi
  else
    if false; then :;
    $resume
    fi
  fi"
}
reset_case
tick
[ "$cuts" = 1 ] && ok 'reported hot hold retries below resume capacity' || no 'reported hot hold bypasses enforcement'

reset_case
level=72; mtReached=false; chDisabledByAcc=false
tick
[ "$cuts/$mtReached" = 1/true ] && ok 'first hot pass cuts and latches above resume capacity' || no 'first hot pass fails'
temp=350; tick
[ "$cuts/$mtReached/$released" = 1/true/false ] && ok 'resumed charging is cut throughout the cooling band' || no 'cooling band loses enforcement or latch'
temp=300; tick
[ "$released" = true ] && ok 'cool thermal hold releases at 72%, above capacity resume' || no 'cool thermal hold is stranded above capacity resume'

reset_case
temp=300; mtReached=false; tick
[ "$released/$cuts" = true/0 ] && ok 'false Charging verdict cannot strand a cool owned hold' || no 'cool owned hold resume regressed'
reset_case
flow=false; tick
[ "$cuts/$released" = 0/false ] && ok 'working hot hold is not repeatedly rewritten' || no 'working hold was disturbed'
reset_case
temp=350; mtReached=false; chDisabledByAcc=false; tick
[ "$cuts/$released" = 0/false ] && ok 'healthy charge below max remains undisturbed' || no 'healthy charge was interrupted'

reset_case
: > "$W/.user-locked"
tick; tick; tick
[ "$warning" = lockhold ] && ok 'failed manual thermal switch warns after confirmed retries' || no 'failed manual thermal switch stays silent'
[ "${chargingSwitch[*]}" = 'battery/charging_enabled 1 0 --' ] && [ ! -f "$W/.sw-blacklist" ] && ok 'manual switch lock remains intact' || no 'manual switch was replaced'

reset_case
tick; tick; tick
if [ -f "$W/.sw-blacklist" ] && grep -qxF 'battery/charging_enabled 1 0' "$W/.sw-blacklist" && [ -z "${chargingSwitch[*]}" ]; then
  ok 'failed automatic thermal switch is blacklisted and cleared'
else
  no 'failed automatic thermal switch is never replaced'
fi

reset_case
chargingSwitch=()
for pass in 1 2 3 4 5 6 7; do tick; done
[ "$warning" = nostop ] && ok 'exhausted thermal discovery warns below capacity limit' || no 'exhausted thermal discovery stays silent'

reset_case
attached=false; tick
[ ! -f "$W/.lockfail-count" ] && ok 'unplugged samples do not indict a switch' || no 'unplugged sample counted as switch failure'
reset_case
level=80; temp=250; mtReached=false
tick; tick; tick
[ "$warning" = swclear-lockfail ] && ok 'capacity breach recovery remains available' || no 'capacity breach recovery regressed'
reset_case
capacity=(5 101 3900 4200 false); voltage=3800; tick
[ "$cuts" = 1 ] && ok 'thermal retry also works with voltage limits' || no 'voltage limits bypass thermal retry'
echo "t-thermal-owned-retry: $P passed, $F failed"
[ "$F" = 0 ]
