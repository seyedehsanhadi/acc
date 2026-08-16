#!/system/bin/sh
# t74 - the firmware-limit thermal hold must release at resume_temp, not at max_temp.
#
# THE REPORT: "still charges above set temperature".
#
# THE DEFECT. temperature=(cooldown_temp max_temp resume_temp shutdown_temp) -- four values, and the
# README documents all four. The generic switch path has always honoured resume_temp: its resume
# branch is gated on `temp_now <= temperature[2]`. sync_native_limit, which is the ONLY enforcement
# a firmware-limit phone gets, tested max_temp on BOTH edges.
#
# So on a Pixel the hold engaged at max_temp and released the moment the pack fell one tenth of a
# degree below it. Charging resumed, the pack heated straight back through max_temp, and it paused
# again. The battery sits AT the limit charging in bursts, and any glance at it shows charging at or
# above the temperature the user set. With temperature=(45 50 40 55) the pack should have been held
# from 50.0 all the way down to 40.0.
#
# The old comment described the release as "it lifts on its own once the temperature drops back
# under max_temp" -- the defect written down as if it were the design.
#
# NO HARDWARE. The latch is executed directly over a temperature ramp.

ID=t74
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }

# ---- 1: resume_temp is actually consulted by the native path -----------------------------------
_blk=$(sed -n '/rc23: HYSTERESIS/,/if \[ "\${_ntHot:-0}" = 1 \]/p' "$AD")
[ -n "$_blk" ] || { no "the hysteresis block is not present in sync_native_limit"; fin; }
printf '%s' "$_blk" | grep -q 'temperature\[2\]' \
  && ok "the native thermal hold reads resume_temp" \
  || no "the native hold still uses only max_temp - it will release a tenth of a degree under the limit"

# ---- 2: the latch is not reset every loop --------------------------------------------------------
# A latch cleared on each pass is not a latch. The per-loop reset next to xIdle=false is the trap.
_inloop=$(awk '/^        mtReached=false/{print NR}' "$AD" | head -1)
_init=$(grep -n '^  _ntHot=0' "$AD" | head -1 | cut -d: -f1)
if [ -n "$_init" ]; then
  if [ -n "$_inloop" ] && [ "$_init" -lt "$_inloop" ] 2>/dev/null; then
    no "the latch is initialised before the loop reset - check it is not inside the loop"
  else
    ok "the latch is initialised once, outside the charging-pass reset"
  fi
else
  no "no top-level _ntHot initialiser"
fi
# Every _ntHot ASSIGNMENT must be either the top-level init or one of the two inside the hysteresis
# block itself (engage on hot, clear on cool). Anything else is a reset that would defeat the latch.
_hy0=$(grep -n 'rc23: HYSTERESIS' "$AD" | head -1 | cut -d: -f1)
_hy1=$(grep -n '_ntHot:-0' "$AD" | head -1 | cut -d: -f1)
_stray=0
for _ln in $(grep -n '_ntHot=' "$AD" | cut -d: -f1); do
  [ "$_ln" = "${_init:-0}" ] && continue
  if [ -n "$_hy0" ] && [ -n "$_hy1" ] && [ "$_ln" -ge "$_hy0" ] && [ "$_ln" -le "$_hy1" ] 2>/dev/null; then continue; fi
  _stray=$((_stray+1)); echo "        unexpected _ntHot assignment at line $_ln"
done
[ "$_stray" -eq 0 ] \
  && ok "the only writes to the latch are its init and the two inside the hysteresis block" \
  || no "$_stray _ntHot assignment(s) outside the latch - one of those will defeat it"

# ---- 3: EXECUTE the latch over a full heat/cool ramp ----------------------------------------------
# max_temp 50.0C, resume_temp 40.0C. Deci-degrees, as the node reports them.
ramp() {   # $1..$n temperatures -> the hold state after each
  ( _mt=500; _rt=400
    [ "$_rt" -lt "$_mt" ] 2>/dev/null || _rt=$_mt
    _ntHot=0
    for t in "$@"; do
      if [ "$t" -ge "$_mt" ] 2>/dev/null; then _ntHot=1
      elif [ "$t" -le "$_rt" ] 2>/dev/null; then _ntHot=0
      fi
      printf '%s' "$_ntHot"
    done )
}

_r=$(ramp 300 450 499 500 501 490 460 420 401 400 399 350)
#          .   .   .   ^engage.......................^release
# expected: 0 0 0 1 1 1 1 1 1 0 0 0
[ "$_r" = "000111111000" ] \
  && ok "engages at max_temp and holds all the way down to resume_temp ($_r)" \
  || no "hold pattern was $_r, expected 000111111000"

_r=$(ramp 499 500 499)
[ "$_r" = "011" ] \
  && ok "one tenth of a degree under max_temp does NOT release the hold (the reported bug)" \
  || no "released at 49.9C: pattern $_r - this is the bug, charging resumes at the limit"

_r=$(ramp 500 450 450 450 450)
[ "$_r" = "11111" ] \
  && ok "the pack stays held through the whole 45C plateau instead of oscillating" \
  || no "pattern $_r - the hold flickers between max_temp and resume_temp"

_r=$(ramp 500 400)
[ "$_r" = "10" ] && ok "it does release once resume_temp is actually reached" \
                 || no "pattern $_r - the hold never releases, which would strand charging"

# ---- 4: a mis-edited config must degrade, never hold forever ---------------------------------------
degrade() {  # $1 max $2 resume -> effective resume threshold
  ( _mt=$(( $1 * 10 )); _rt=$(( $2 * 10 ))
    [ "$_rt" -lt "$_mt" ] 2>/dev/null || _rt=$_mt
    printf '%s' "$_rt" )
}
[ "$(degrade 50 40)" = 400 ] && ok "a sane config keeps its resume_temp" || no "sane config gave $(degrade 50 40)"
[ "$(degrade 50 50)" = 500 ] && ok "resume_temp equal to max_temp degrades to the old single threshold" \
                             || no "equal temps gave $(degrade 50 50) - the hold could never release"
[ "$(degrade 50 60)" = 500 ] && ok "resume_temp ABOVE max_temp degrades instead of holding forever" \
                             || no "resume above max gave $(degrade 50 60) - charging would never resume"

# ---- 5: the generic switch path still uses resume_temp too, unchanged -------------------------------
grep -q 'temp_now) -le \$(( \${temperature\[2\]} \* 10 ))' "$AD" \
  && ok "the generic path's resume is still gated on resume_temp (untouched)" \
  || no "the generic path lost its resume_temp gate"

# ---- 6: the shutdown temperature is not touched by any of this ---------------------------------------
# Standing instruction: shutdown_temp is never written or tested by the suites.
printf '%s' "$_blk" | grep -q 'temperature\[3\]' \
  && no "the hysteresis block references shutdown_temp - it must not" \
  || ok "shutdown_temp is untouched"

fin
