#!/system/bin/sh
# fulltest.sh - everything, in the order that fails fastest.
#
#   sh fulltest.sh          run all four stages
#   sh fulltest.sh 3        start from stage 3
#
# THE FOUR STAGES, cheapest first. A failure in an early stage means the later ones would only be
# measuring a build that is already known broken, so each stage gates the next.
#
#   1  UNITS        16 source/logic tests against the installed build          ~30s
#   2  DIFFERENTIAL 55 assertions, rc21 against rc22, same inputs both ways    ~15s
#   3  MEGATEST     the full behavioural suite on live hardware                ~12min
#   4  INVARIANTS   the phone is exactly as it was found                       ~10s
#
# WHY THIS ORDER
#   Stage 3 is fifty times the cost of stages 1 and 2 together and can only exercise what THIS phone
#   can reach. Stages 1 and 2 run every code path, including ones no phone here can execute - bug 28
#   lived in a branch neither test device can enter, and was proven in stage 2. Running the cheap
#   exhaustive checks first means a broken build is caught in seconds instead of a quarter of an hour.
#
# WHAT A PASS MEANS
#   Stage 2 is the one that proves a FIX. Stages 1 and 3 test the candidate in isolation, so they
#   answer "does it work", while stage 2 answers "is it different from what users have" - and a fix
#   that does not change behaviour against rc21 has not been demonstrated at all.
#
# SAFETY
#   Stage 3 changes real settings and restores them from a trap; stage 4 asserts that restore.
#   shutdown_temp is never written. Stop with TERM, never KILL.

set -u

M=/data/adb/vr25/acc
DD=/data/adb/vr25/acc-data
TD=/dev/.vr25/acc
AB=${AB:-/data/local/tmp/ab}
FROM=${1:-1}
DL=/sdcard/Download; [ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$DL/fulltest-$STAMP.txt
DONE=$TD/.fulltest-done
# Android has no /tmp. Using it made every unit suite report FAIL because the redirect could not be
# created - sixteen identical failures that had nothing to do with the tests.
SCR=${SCR:-/data/local/tmp/fulltest-scratch}
mkdir -p "$SCR" 2>/dev/null
T0=$(date +%s)

log(){ echo "$*"; echo "$*" >> "$OUT"; }
sec(){ log ""; log "################ $* ################"; }
G=/sys/class/power_supply/battery
for _c in /sys/class/power_supply/*/capacity; do _d=${_c%/capacity}
  [ -n "$(cat $_c 2>/dev/null)" ] && [ -n "$(cat $_d/status 2>/dev/null)" ] && { G=$_d; break; }; done

S1=skip; S2=skip; S3=skip; S4=skip
rm -f "$DONE" 2>/dev/null

log "=== full test: $(getprop ro.product.device) / build $(sed -n 's/^versionCode=//p' $M/module.prop) ==="
log "level $(cat $G/capacity)%  temp $(( $(cat $G/temp) / 10 ))C  status $(cat $G/status)"

# A hot pack makes every thermal result meaningless, and stage 3 refuses anyway - better to say so
# here than fifteen minutes in.
_t=$(( $(cat $G/temp 2>/dev/null || echo 300) / 10 ))
if [ "$_t" -ge 39 ] 2>/dev/null; then
  log ""
  log "REFUSING: pack is ${_t}C. Let it reach 35C or below - the thermal sections need headroom"
  log "          between the pack and the limit they arm, and there is none up here."
  printf 'refused=hot temp=%s\n' "$_t" > "$DONE" 2>/dev/null
  exit 0
fi

# ---- 1: units -----------------------------------------------------------------------------------
if [ "$FROM" -le 1 ]; then
sec "STAGE 1  unit suite"
_p=0; _f=0; _fail=
for _t in $M/suites/accd/t*.sh; do
  [ -f "$_t" ] || continue
  _n=$(basename "$_t" .sh)
  if execDir=$M sh "$_t" >$SCR/ft.$$ 2>&1 || execDir=$M sh "$_t" >$SCR/ft.$$ 2>&1; then
    _p=$((_p+1)); log "  ok    $_n  $(tail -1 $SCR/ft.$$)"
  else
    _f=$((_f+1)); _fail="$_fail $_n"; log "  FAIL  $_n"
    sed -n 's/^  FAIL/      /p' $SCR/ft.$$ | head -4 | while IFS= read -r _l; do log "$_l"; done
  fi
  rm -f $SCR/ft.$$ 2>/dev/null
done
log "  -> $_p suites passed, $_f failed${_fail:+ ($_fail )}"
[ "$_f" -eq 0 ] && S1=pass || S1=FAIL
fi

# ---- 2: differential ----------------------------------------------------------------------------
if [ "$FROM" -le 2 ]; then
sec "STAGE 2  differential, rc21 vs rc22"
if [ -d "$AB/rc21/install" ] && [ -d "$AB/rc22/install" ]; then
  ROOT=$AB sh "$AB/ab.sh" > $SCR/ab.$$ 2>&1 || :
  grep -E "FLIPPED|held |PROBLEMS|runtime|VERDICT" $SCR/ab.$$ | while IFS= read -r _l; do log "  $_l"; done
  grep -E "^  SAME|^  DRIFT" $SCR/ab.$$ | while IFS= read -r _l; do log "$_l"; done
  # Read the count ab.sh already computed. Re-deriving it here with grep got it wrong twice over:
  # toybox has no \| alternation, so the pattern matched nothing and the gate scored zero failures
  # while the very next line PRINTED seventeen of them with -E. The suite reported STABLE with
  # stage 2 broken. Never re-derive a number the tool under test already reports.
  _bad=$(sed -n 's/^ *PROBLEMS *: *//p' $SCR/ab.$$ | tail -1)
  case "${_bad:-x}" in ''|*[!0-9]*) _bad=99;; esac
  [ "$_bad" -eq 0 ] && S2=pass || S2=FAIL
  rm -f $SCR/ab.$$ 2>/dev/null
else
  log "  skipped: no rc21 tree at $AB/rc21 - stage 2 is the only one that proves a FIX, so this"
  log "           run cannot claim any bug is fixed, only that the candidate works."
  S2=skip
fi
fi

# ---- 3: behavioural -----------------------------------------------------------------------------
if [ "$FROM" -le 3 ]; then
sec "STAGE 3  megatest on live hardware"
if [ -f "$M/suites/megatest.sh" ]; then
  rm -f $TD/.megatest-done 2>/dev/null
  sh "$M/suites/megatest.sh" > $SCR/mt.$$ 2>&1 || :
  grep -E "^  PASS|^  FAIL|^  skip|^=====" $SCR/mt.$$ | while IFS= read -r _l; do log "$_l"; done
  # Prefer the megatest's own sentinel over counting lines here. A grep that silently matches
  # nothing scores a clean run, which is the failure mode that made stage 2 lie.
  # No sed backreference. A  written from a non-raw string is the OCTAL escape for chr(1), not a
  # literal backreference - the pattern shipped with an EMPTY replacement, the parse returned
  # nothing, and the fail-closed default scored this stage FAIL on a run the megatest itself
  # reported as fail=0. grep -o has no replacement to lose.
  _mf=$(grep -o "fail=[0-9][0-9]*" $TD/.megatest-done 2>/dev/null | cut -d= -f2 | tail -1)
  if [ -z "$_mf" ]; then _mf=$(grep -cE "^  FAIL" $SCR/mt.$$ 2>/dev/null || :); fi
  case "${_mf:-x}" in ''|*[!0-9]*) _mf=99;; esac
  [ "$_mf" -eq 0 ] && S3=pass || S3=FAIL
  rm -f $SCR/mt.$$ 2>/dev/null
else
  log "  skipped: megatest.sh not installed"
fi
fi

# ---- 4: the phone is as we found it -------------------------------------------------------------
sec "STAGE 4  invariants"
_bad=0
_q=$(cat $TD/acc.lock 2>/dev/null)
if [ -n "$_q" ] && [ -d "/proc/$_q" ]; then log "  ok    daemon alive ($_q)"; else log "  FAIL  daemon is DOWN"; _bad=$((_bad+1)); fi
_sd=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
if [ "${_sd:-0}" -ge 40 ] 2>/dev/null; then log "  ok    shutdown_temp sane (${_sd}C)"; else log "  FAIL  shutdown_temp is '${_sd}'"; _bad=$((_bad+1)); fi
_mcc=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()')
if [ -z "$_mcc" ]; then log "  ok    no leftover current cap"; else log "  note  a ${_mcc} mA cap is set - intended?"; fi
if [ -f $TD/.mcc-settling ]; then log "  FAIL  the settling mutex is stuck - a CLI set did not finish"; _bad=$((_bad+1)); else log "  ok    settling mutex clear"; fi
_is=$(cat $G/input_suspend 2>/dev/null)
_lv=$(cat $G/capacity 2>/dev/null); _pa=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
if [ "${_is:-0}" = 1 ] && [ "${_lv:-0}" -lt "${_pa:-100}" ] 2>/dev/null; then
  log "  FAIL  input_suspend=1 at ${_lv}% with a pause of ${_pa}% - the phone is cut below its resume point"
  _bad=$((_bad+1))
else
  log "  ok    charge path not left cut below the pause level"
fi
[ "$_bad" -eq 0 ] && S4=pass || S4=FAIL

# ---- verdict ------------------------------------------------------------------------------------
_el=$(( $(date +%s) - T0 ))
log ""
log "=================================================================="
log "  1 units         : $S1"
log "  2 differential  : $S2"
log "  3 behavioural   : $S3"
log "  4 invariants    : $S4"
log "  runtime         : $(( _el / 60 ))m$(( _el % 60 ))s"
log ""
case "$S1$S2$S3$S4" in
  passpasspasspass)
    log "  VERDICT: STABLE. Every unit test passes, every intended fix differs from rc21, the"
    log "           behavioural suite is clean on this hardware, and the phone is as it was found." ;;
  *FAIL*)
    log "  VERDICT: NOT STABLE. See the failing stage above." ;;
  *)
    log "  VERDICT: INCOMPLETE - a stage was skipped, so no stability claim is made." ;;
esac
log "  report: $OUT"
printf 'build=%s units=%s diff=%s behav=%s inv=%s secs=%s\n' \
  "$(sed -n 's/^versionCode=//p' $M/module.prop)" "$S1" "$S2" "$S3" "$S4" "$_el" > "$DONE" 2>/dev/null
sync 2>/dev/null || :
