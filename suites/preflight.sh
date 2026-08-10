#!/system/bin/sh
# preflight.sh - everything that can be proven WITHOUT a charger.
#
#   sh preflight.sh
#
# Splitting the full test in two is not a convenience, it is what makes the plugged half worth
# running. The behavioural suite takes a quarter of an hour on live hardware and can only exercise
# what THIS phone can reach; if a unit test or the rc21 differential is already failing, that time
# is spent measuring a build already known to be broken. So: prove the cheap, exhaustive things
# first, unplugged, and only ask for the cable once they are green.
#
#   1  UNITS         every suite in suites/accd, source and logic, no hardware
#   2  DIFFERENTIAL  rc21 against rc22 on identical inputs
#   3  INVARIANTS    the phone is as we found it, and the daemon is healthy
#   4  IDLE COST     CPU and forks per minute, the regression guard
#
# Stage 4 exists because the 5.5x idle regression in rc22 was invisible to every other stage: the
# units and the differential both passed while it was live, because both compare the build against
# itself or against expectations, and the cost was in neither. A standing cheap measurement is the
# only thing that would have caught it.
#
# shutdown_temp is never written. Nothing here changes a user setting.

set -u

M=/data/adb/vr25/acc
DD=/data/adb/vr25/acc-data
TD=/dev/.vr25/acc
AB=${AB:-/data/local/tmp/ab}
DL=/sdcard/Download; [ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
OUT=$DL/preflight-$(date +%Y%m%d-%H%M%S).txt
SCR=/data/local/tmp/preflight-scratch
mkdir -p "$SCR" 2>/dev/null
T0=$(date +%s)

log(){ echo "$*"; echo "$*" >> "$OUT"; }
sec(){ log ""; log "######## $* ########"; }

G=/sys/class/power_supply/battery
for _c in /sys/class/power_supply/*/capacity; do
  _d=${_c%/capacity}
  [ -n "$(cat $_c 2>/dev/null)" ] && [ -n "$(cat $_d/status 2>/dev/null)" ] && { G=$_d; break; }
done

S1=skip; S2=skip; S3=skip; S4=skip

log "=== preflight: $(getprop ro.product.device) / ACC $(sed -n 's/^versionCode=//p' $M/module.prop) ==="
log "level $(cat $G/capacity)%  temp $(( $(cat $G/temp) / 10 ))C  status $(cat $G/status)"

# This half is defined by being unplugged. A cable does not break anything here, but stage 4 would
# then be measuring a charging phone and meaning something different, so say so rather than assume.
_plug=no
for f in /sys/class/power_supply/*/present; do
  case $f in */battery/*|*/bms/*|*maxfg*) continue;; esac
  [ "$(cat $f 2>/dev/null)" = 1 ] && _plug=yes
done
log "plugged: $_plug"
[ "$_plug" = no ] || log "NOTE: a charger is attached - stage 4 measures a charging phone, not idle."

# ---- 1: units -----------------------------------------------------------------------------------
sec "STAGE 1  unit suites"
_p=0; _f=0; _fail=
for _t in $M/suites/accd/t*.sh; do
  [ -f "$_t" ] || continue
  _n=$(basename "$_t" .sh)
  if execDir=$M sh "$_t" > $SCR/u.out 2>&1; then
    _p=$((_p + 1))
  else
    _f=$((_f + 1)); _fail="$_fail $_n"; log "  FAIL  $_n"
    sed -n 's/^  FAIL/      /p' $SCR/u.out | head -4 | while IFS= read -r _l; do log "$_l"; done
  fi
  rm -f $SCR/u.out 2>/dev/null
done
log "  -> $_p suites passed, $_f failed${_fail:+ ($_fail )}"
[ "$_f" -eq 0 ] && S1=pass || S1=FAIL

# ---- 2: differential ----------------------------------------------------------------------------
sec "STAGE 2  differential, rc21 vs rc22"
if [ -f "$AB/ab.sh" ] && [ -d "$AB/rc21/install" ] && [ -d "$AB/rc22/install" ]; then
  ROOT=$AB sh "$AB/ab.sh" > $SCR/ab.out 2>&1 || :
  grep -E "FLIPPED|held |PROBLEMS|runtime|VERDICT" $SCR/ab.out | while IFS= read -r _l; do log "  $_l"; done
  # Read the count the tool itself reports; never re-derive it here. A re-derived grep that
  # silently matched nothing once scored this stage clean while seventeen assertions were failing.
  _bad=$(sed -n 's/^ *PROBLEMS *: *//p' $SCR/ab.out | tail -1)
  case "${_bad:-x}" in ''|*[!0-9]*) _bad=99;; esac
  [ "$_bad" -eq 0 ] && S2=pass || S2=FAIL
  rm -f $SCR/ab.out 2>/dev/null
else
  log "  skipped: no A/B tree at $AB - this run cannot claim any fix is PROVEN,"
  log "           only that the candidate passes its own tests."
fi

# ---- 3: invariants ------------------------------------------------------------------------------
sec "STAGE 3  invariants"
_bad=0
_q=$(cat $TD/acc.lock 2>/dev/null)
if [ -n "$_q" ] && [ -d "/proc/$_q" ]; then
  log "  ok    daemon alive ($_q)"
else
  log "  FAIL  daemon is DOWN"; _bad=$((_bad + 1))
fi

_sd=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
if [ "${_sd:-0}" -ge 40 ] 2>/dev/null; then
  log "  ok    shutdown_temp sane (${_sd}C)"
else
  log "  FAIL  shutdown_temp is '${_sd}'"; _bad=$((_bad + 1))
fi

if [ -f $TD/.mcc-settling ]; then
  log "  FAIL  the settling mutex is stuck - a CLI set did not finish"; _bad=$((_bad + 1))
else
  log "  ok    settling mutex clear"
fi

_is=$(cat $G/input_suspend 2>/dev/null)
_lv=$(cat $G/capacity 2>/dev/null)
_pa=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
if [ "${_is:-0}" = 1 ] && [ "${_lv:-0}" -lt "${_pa:-100}" ] 2>/dev/null; then
  log "  FAIL  input_suspend=1 at ${_lv}% below a pause of ${_pa}% - charge path left cut"
  _bad=$((_bad + 1))
else
  log "  ok    charge path not left cut below the pause level"
fi

# The fix that mattered this round. present() must still fall through to online() (bug 28), and
# online_f must still be cached, or the once-a-second idle path starts forking again.
if grep -q '_onlineF' $M/batt-interface.sh 2>/dev/null; then
  log "  ok    online_f cache present (idle path fork-free)"
else
  log "  FAIL  online_f cache is GONE - the 5.5x idle regression is back"; _bad=$((_bad + 1))
fi

# The fast-charge contract. A re-kick renegotiates QC/PD down to a 5V floor that only a physical
# replug recovers, so ACC must never fire one against a contract it is already holding. This guard
# was wrong four times in four different ways, and every version passed the behavioural section
# that supposedly covers it - so check the LEDGER, which records what actually happened.
if [ -f $TD/.write-ledger ]; then
  _fired=$(grep -c 'apsd_rerun <- 1' $TD/.write-ledger 2>/dev/null) || _fired=0
  case "${_fired:-0}" in ''|*[!0-9]*) _fired=0;; esac
  _held=$([ -f $TD/.hvcontract ] && echo yes || echo no)
  if [ "$_fired" -eq 0 ] 2>/dev/null; then
    log "  ok    no charger re-detection fired this session (contract latch: $_held)"
  else
    # Not automatically a fault: on a 5V-only supply a re-kick is the correct repair. It is a
    # fault when it happened while a contract was latched, which is what the ledger reason says.
    _bad_rk=$(grep -c 'aimed for best contract' $TD/.write-ledger 2>/dev/null) || _bad_rk=0
    case "${_bad_rk:-0}" in ''|*[!0-9]*) _bad_rk=0;; esac
    log "  note  ${_fired} re-detection(s) fired (latch: $_held) - check the ledger reasons"
    if [ "$_held" = yes ]; then
      log "  FAIL  a re-kick fired while a high-voltage contract was latched"
      _bad=$((_bad + 1))
    fi
  fi
fi
[ "$_bad" -eq 0 ] && S3=pass || S3=FAIL

# ---- 4: idle cost -------------------------------------------------------------------------------
sec "STAGE 4  idle cost"
_A=$(cat $TD/acc.lock 2>/dev/null)
if [ -n "$_A" ] && [ -d "/proc/$_A" ]; then
  # cutime+cstime as well as utime+stime: accd is a shell script, so most of its cost sits in
  # children it has already reaped. Counting only its own stat undercounts by most of the work.
  _c0=$(awk '{print $14+$15+$16+$17}' /proc/$_A/stat 2>/dev/null || echo 0)
  _k0=$(sed -n 's/^processes //p' /proc/stat)
  _t0=$(date +%s)
  sleep 90
  _c1=$(awk '{print $14+$15+$16+$17}' /proc/$_A/stat 2>/dev/null || echo 0)
  _k1=$(sed -n 's/^processes //p' /proc/stat)
  _t1=$(date +%s)
  _el=$(( _t1 - _t0 )); [ "$_el" -gt 0 ] || _el=1
  _ms=$(( ( _c1 - _c0 ) * 1000 / 100 * 60 / _el ))
  _fk=$(( ( _k1 - _k0 ) * 60 / _el ))
  log "  accd  ${_ms} ms/min   forks ${_fk}/min   over ${_el}s"
  # Reference points, measured on these two phones held awake, per minute of awake time:
  #   Mi A3      rc21 1108   rc22 before the fix 6011   rc22 after 1076
  #   Pixel 6a   rc21 2876   rc22 before the fix 3256   rc22 after 2260
  # A phone allowed to deep-sleep reads well below any of those, so this is a smell test and not
  # a threshold: it catches a screaming number, not a few percent of drift.
  if [ "$_ms" -gt 12000 ] 2>/dev/null; then
    log "  FAIL  ${_ms} ms/min is far above anything measured on either test phone"
    S4=FAIL
  else
    log "  ok    within the range measured for this build"
    S4=pass
  fi
else
  log "  skipped: no daemon to measure"
fi

# ---- verdict ------------------------------------------------------------------------------------
_rt=$(( $(date +%s) - T0 ))
log ""
log "=================================================================="
log "  1 units         : $S1"
log "  2 differential  : $S2"
log "  3 invariants    : $S3"
log "  4 idle cost     : $S4"
log "  runtime         : $(( _rt / 60 ))m$(( _rt % 60 ))s"
log ""
case "$S1$S2$S3$S4" in
  *FAIL*)
    log "  PREFLIGHT: FAILED - do not plug in yet, the build is broken above." ;;
  passpasspasspass)
    log "  PREFLIGHT: CLEAR - ready for the plugged behavioural suite." ;;
  *)
    log "  PREFLIGHT: INCOMPLETE - a stage was skipped; see above." ;;
esac
log "  report: $OUT"
printf 'units=%s diff=%s inv=%s idle=%s secs=%s\n' "$S1" "$S2" "$S3" "$S4" "$_rt" > $TD/.preflight-done 2>/dev/null
sync 2>/dev/null || :
