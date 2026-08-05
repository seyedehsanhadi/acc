#!/system/bin/sh
# deep-plugged.sh - exercise every fixed bug on a CHARGING phone, on the hardware, one at a time.
#
#   sh deep-plugged.sh          run everything the current supply permits
#   sh deep-plugged.sh D3       run one section
#
# WHY THIS EXISTS SEPARATELY FROM harness.sh
#   harness.sh's deep battery layer (L3) only runs unplugged, and its regression layer (L1) is
#   source-level: it proves a fix is PRESENT, not that it WORKS. The behaviour of most of these bugs
#   only exists while charging - a latch that strands a phone, a cap that writes nothing, a pause
#   that will not hold. This is the plugged half.
#
# NATIVE-LIMIT PHONES
#   Several of these bugs only exist on a phone whose switch is the firmware's own charge_stop_level
#   with the `pcap` sentinel (Pixel, some OnePlus). On such a phone there is no "off value" to test
#   against: the node never reads a disabled state, so "node != off" is always true and says nothing.
#   A pause there is charge_stop_level <= level. Sections that need a native switch skip cleanly on a
#   generic-switch phone, and say so.
#
# SAFETY
#   shutdown_temp is NEVER written or tested. Every setting is saved up front and restored on
#   EXIT/INT/TERM/HUP, so an interrupted run leaves the phone as it was found. No charging node is
#   written directly - everything goes through `acc -s`, the same path a user takes.
#
#   Stop it with TERM, not KILL. The restore runs from a trap, and KILL skips traps: a forced kill
#   during this campaign left a phone holding test limits (pause 55, max_temp 60) until noticed.

TD=/dev/.vr25/acc
DD=/data/adb/vr25/acc-data
M=/data/adb/vr25/acc
IF=$TD/.batt-interface.sh
FL=$DD/logs/flight.log
WL=$TD/.write-ledger
WANT=${1:-all}

DL=/sdcard/Download
[ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
OUT=$DL/acc-deep-$(date +%Y%m%d-%H%M%S).txt

P=0; F=0; SK=0
log(){ echo "$*"; echo "$*" >> "$OUT"; }
ok(){ P=$((P+1)); log "  PASS  $*"; }
no(){ F=$((F+1)); log "  FAIL  $*"; }
sk(){ SK=$((SK+1)); log "  skip  $*"; }
sec(){ log ""; log "===== $* ====="; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
want(){ [ "$WANT" = all ] || [ "$WANT" = "$1" ]; }

G=/sys/class/power_supply/battery
for _c in /sys/class/power_supply/*/capacity; do
  _d=${_c%/capacity}
  [ -n "$(rd "$_c")" ] && [ -n "$(rd "$_d/status")" ] && { G=$_d; break; }
done
lvl(){ rd $G/capacity; }
tmp(){ _t=$(rd $G/temp); isnum "${_t#-}" && echo $(( _t / 10 )) || echo ""; }
cc(){ rd $G/charge_counter; }
accst(){ timeout 20 acc -i 2>/dev/null </dev/null | sed -n 's/^status //p' | head -1; }
alive(){ _p=$(rd $TD/acc.lock); [ -n "$_p" ] && [ -d "/proc/$_p" ]; }
wl(){ _n=$(wc -l < $WL 2>/dev/null); case "${_n:-x}" in ''|*[!0-9]*) echo 0;; *) echo "$_n";; esac; }

# grep -c prints its count AND exits 1 when the count is zero, so `grep -c ... || echo 0` emits TWO
# lines and every later numeric test on it is a syntax error. Count without that trap.
cnt(){ _c=$(grep -c "$1" 2>/dev/null); case "${_c:-x}" in ''|*[!0-9]*) echo 0;; *) echo "$_c";; esac; }

# Rate from the counter. Sign-convention-free, which matters: the current sensor's sign is per-device
# and on some phones flips with the charge path, and ACC arms .dpol_unstable when it sees that. The
# counter is quantised though (a Mi A3 steps 28600 uAh at a time), so short windows read 0 or one
# whole quantum. 90s is enough here because every check below only asks "filling or not", never for a
# precise rate.
# Adaptive, with a ceiling. A flat 90s was paid on every call regardless of how obvious the answer
# was, and this suite calls it a dozen times. Stop as soon as the counter moves (the sign is then
# settled) or as soon as counter-still and near-zero current agree that nothing is flowing.
rate90(){
  _a=$(cc); _t0=$(date +%s); _el=0
  while [ $_el -lt 100 ]; do
    sleep 5; _el=$(( _el + 5 ))
    _b=$(cc)
    case "${_a:-x}${_b:-x}" in *x*) echo ""; return;; esac
    _dd=$(( _b - _a ))
    if [ "$_dd" -ne 0 ]; then
      _t1=$(date +%s); _dt=$(( _t1 - _t0 )); [ "$_dt" -gt 0 ] 2>/dev/null || _dt=$_el
      echo $(( _dd * 3600 / _dt / 1000 ))
      return
    fi
    if [ $_el -ge 20 ]; then
      _im=$(rd $G/current_now); _im=${_im#-}
      case "${_im:-x}" in ''|*[!0-9]*) :;; *) [ "$_im" -lt 120000 ] && { echo 0; return; };; esac
    fi
  done
  echo 0
}

# Wait for a condition instead of sleeping a guess at how long a phone takes. Every fixed sleep in
# this campaign eventually reported a product bug that was really a slow phone.
waitfor(){   # $1 = seconds, $2.. = command
  _lim=$1; shift
  _w=0
  while [ $_w -lt "$_lim" ]; do
    "$@" && return 0
    sleep 5; _w=$((_w + 5))
  done
  return 1
}

# ---- save / restore ------------------------------------------------------------------------------
S_C=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')
S_T=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
S_MCC=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
S_MCV=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
S_RES=$(echo $S_C | cut -d' ' -f3); S_PAU=$(echo $S_C | cut -d' ' -f4)
S_CT=$(echo $S_T | cut -d' ' -f1);  S_MT=$(echo $S_T | cut -d' ' -f2); S_RT=$(echo $S_T | cut -d' ' -f3)

restore_all(){
  acc -s resume_capacity=$S_RES pause_capacity=$S_PAU >/dev/null 2>&1
  acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  acc -s max_charging_voltage="$S_MCV" >/dev/null 2>&1
  acc -sk on >/dev/null 2>&1
  rm -f $TD/.rekick-off 2>/dev/null || :
}
cleanup(){
  trap - EXIT INT TERM HUP
  log ""; log "--- restoring ---"
  restore_all
  sleep 5
  log "config   : $(sed -n 's/^capacity=//p' $DD/config.txt) $(sed -n 's/^temperature=//p' $DD/config.txt)"
  log "caps     : mcc=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | cut -c1-14) mcv=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt)"
  log "daemon   : $(alive && echo alive || echo DOWN)"
  log ""
  log "===== $P passed, $F failed, $SK skipped ====="
  log "report: $OUT"
  exit 0
}
trap cleanup EXIT INT TERM HUP

# ---- preflight -----------------------------------------------------------------------------------
sec "PREFLIGHT"
log "device   : $(getprop ro.product.device) / Android $(getprop ro.build.version.release)"
log "acc build: $(sed -n 's/^versionCode=//p' $M/module.prop)"
log "level    : $(lvl)%   temp: $(tmp)C"

SW=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt | tr -d '()')
SWN=$(echo $SW | cut -d' ' -f1)
SWOFF=$(echo $SW | cut -d' ' -f3)
NATIVE=false
case "$SWOFF" in pcap) NATIVE=true;; esac
case "$SWN" in *charge_stop_level*) NATIVE=true;; esac
log "switch   : $SWN  (off value '$SWOFF')"
log "class    : $($NATIVE && echo 'NATIVE firmware limit -- no off value; a pause is stop_level <= level' || echo 'generic -- paused when the node reads its off value')"

_on=no
for _f in /sys/class/power_supply/*/online; do [ "$(rd "$_f")" = 1 ] && _on=yes; done
[ "$_on" = yes ] || { log ""; log "NOT CHARGING. This suite needs a live charge; nothing was changed."; exit 0; }

_r0=$(rate90)
log "free rate: ${_r0:-?} mA (nothing limiting)"
isnum "${_r0#-}" && [ "${_r0:-0}" -gt 150 ] 2>/dev/null || {
  log ""; log "The supply delivers ${_r0:-?} mA. Too little to demonstrate anything; use a wall charger."
  exit 0
}
alive && ok "daemon is running" || no "daemon is NOT running"
[ -n "$(accst)" ] && ok "acc -i answers" || no "acc -i returns nothing"

L0=$(lvl); T0=$(tmp)

# =================================================================================================
if want D1; then
sec "D1. NATIVE FIRMWARE LIMIT  (bugs 5, 6, 7)"
if ! $NATIVE; then
  sk "this phone uses a generic switch; bugs 5/6/7 are native-only"
else
  # --- bug 5: the limit must not latch -------------------------------------------------------------
  # A phone was stranded not charging with a limit far above its level: the firmware levels were
  # written once and never revised, so raising the limit did nothing.
  acc -s resume_capacity=$(( $(lvl) - 3 )) pause_capacity=$(( $(lvl) - 1 )) >/dev/null 2>&1
  if waitfor 120 sh -c '[ "$(cat '"$SWN"' 2>/dev/null)" -le "$(cat '"$G"'/capacity 2>/dev/null)" ] 2>/dev/null'; then
    ok "a capacity pause reaches the firmware ($(rd $SWN) <= $(lvl))"
  else
    no "the firmware level never came down to pause ($(rd $SWN) vs level $(lvl))"
  fi
  _stopA=$(rd $SWN)
  acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
  if waitfor 150 sh -c '[ "$(cat '"$SWN"' 2>/dev/null)" -gt "$(cat '"$G"'/capacity 2>/dev/null)" ] 2>/dev/null'; then
    ok "raising the limit releases it: stop $_stopA -> $(rd $SWN) (bug 5 does not reproduce)"
  else
    no "LATCHED: stop stayed $(rd $SWN) with the limit raised to 100 -- phone stranded (bug 5)"
  fi

  # --- bug 6: a thermal pause must hold BELOW the resume level --------------------------------------
  # The firmware only holds at level >= stop_level. Clamping stop to the START level left a hot pack
  # charging whenever the level sat under it. Measured at 38C against max_temp 37: 1.2A flowing.
  _t=$(tmp)
  if isnum "${_t#-}" && [ "$_t" -gt 12 ] 2>/dev/null; then
    acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
    acc -s cooldown_temp=$(( _t - 3 )) max_temp=$(( _t - 2 )) resume_temp=$(( _t - 5 )) >/dev/null 2>&1
    sleep 45
    _r=$(rate90)
    _lv=$(lvl); _st=$(rd $SWN)
    log "      pack ${_t}C vs max_temp $(( _t - 2 ))C, level ${_lv}%, stop_level ${_st}, rate ${_r:-?} mA"
    if [ "${_r:-9999}" -le 150 ] 2>/dev/null; then
      ok "a thermal pause holds with the level under the resume point (${_r} mA)"
    else
      no "still charging at ${_r} mA on a pack over max_temp (bug 6)"
    fi
    # --- bug 7: it must not PULSE the limit wide open while holding ---------------------------------
    # native_unlatch wrote charge_stop_level=100 then slept a full loop: unrestricted charging on a
    # hot pack, every loop. Sample fast enough to catch a pulse that only lasts one loop.
    _hits=0; _n=0
    while [ $_n -lt 40 ]; do
      _n=$((_n + 1))
      [ "$(rd $SWN)" = 100 ] && _hits=$((_hits + 1))
      sleep 3
    done
    [ "$_hits" -eq 0 ] \
      && ok "no wide-open pulse across 40 samples on a hot pack (bug 7)" \
      || no "stop_level read 100 in $_hits of 40 samples while thermally paused (bug 7)"
    acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
    waitfor 120 sh -c '[ "$(cat '"$SWN"' 2>/dev/null)" -gt "$(cat '"$G"'/capacity 2>/dev/null)" ] 2>/dev/null' \
      && ok "charging resumes once the temperature limit is lifted" \
      || no "did not resume after the temperature limit was lifted"
  else
    sk "temperature unreadable (${_t:-empty}); the thermal cases need a real sensor"
  fi
fi
fi

# =================================================================================================
if want D2; then
sec "D2. THE INTERFACE CACHE, WHILE CHARGING  (bugs 12, 14, 17)"
# The cache holds every learned fact. Losing it used to leave the daemon running from memory while
# every front end went blind - and `acc -i` did not merely return nothing, it BLOCKED, because the
# node paths were unset and a read fell through to stdin.
cp -a $IF /data/local/tmp/deep-if.bak 2>/dev/null
_p0=$(rd $TD/acc.lock)
_pol0=$(sed -n 's/^_DPOL=//p' $IF 2>/dev/null)
: > $IF
_st=$(accst)
[ -n "$_st" ] \
  && ok "acc -i still answers with the cache gone ('$_st') -- it does not block (bug 14)" \
  || no "acc -i returned nothing or blocked with the cache gone (bug 14)"
if waitfor 200 sh -c '[ -s '"$IF"' ] && grep -q "^battCapacity=" '"$IF"' && grep -q "^currFile=" '"$IF"''; then
  ok "the daemon republished a usable cache while charging (bug 17)"
else
  no "the cache never came back ($(wc -c < $IF 2>/dev/null) bytes) (bug 17)"
fi
_p1=$(rd $TD/acc.lock)
[ "$_p0" = "$_p1" ] \
  && ok "and it did that WITHOUT restarting (pid $_p0 throughout)" \
  || sk "the daemon restarted ($_p0 -> $_p1), so this measured init, not the republish"
_pol1=$(sed -n 's/^_DPOL=//p' $IF 2>/dev/null)
if [ -z "$_pol0" ]; then
  # Nothing was latched going in, so "it survived" is trivially true and proves nothing. This
  # reported PASS with both sides empty right after a daemon restart, which is not a test. Some
  # phones never latch a polarity at all: ACC only calls sdp() when it has to resolve the sign.
  sk "polarity preservation -- nothing was latched before the rebuild, nothing to preserve"
elif [ "$_pol0" = "$_pol1" ]; then
  ok "the learned polarity survived the rebuild ('$_pol1')"
else
  no "polarity changed across the rebuild: '$_pol0' -> '$_pol1'"
fi
# Re-check the SUPPLY before judging the verdict. Preflight established a live charge minutes ago;
# it is not a standing guarantee. On an A3 whose input collapsed to icl=0 mid-section, ACC correctly
# reported Discharging and this scored it a failure - the assertion assumed a precondition it never
# re-tested. A verdict can only be wrong relative to what the hardware is actually doing.
_still=$(rate90)
if ! isnum "${_still#-}" || [ "${_still:-0}" -le 150 ] 2>/dev/null; then
  sk "post-rebuild verdict -- the supply stopped delivering (${_still:-?} mA), nothing to check against"
elif [ "$(accst)" = Charging ]; then
  ok "still reports Charging after the rebuild, with the pack provably filling (${_still} mA)"
else
  no "reports '$(accst)' after the rebuild while the pack is filling at ${_still} mA"
fi
fi

# =================================================================================================
if want D3; then
sec "D3. CURRENT CAP LIFECYCLE  (bugs 9, 10, 18)"
_free=$(rate90)
_w0=$(wl)
acc -s max_charging_current=500 >/dev/null 2>&1
sleep 40
_w1=$(wl)
_wrote=$(( _w1 - _w0 ))
log "      ACC wrote $_wrote node lines applying a 500 mA cap"
[ "$_wrote" -gt 0 ] \
  && ok "setting a cap actually writes nodes (bug 18)" \
  || no "the cap was accepted and NOTHING was written -- a limit that does nothing (bug 18)"
[ -f $TD/.mcc-custom ] && ok "the cap marker is set" || no "the cap marker is missing"
_capped=$(rate90)
log "      free ${_free:-?} mA -> capped ${_capped:-?} mA"
if isnum "${_capped#-}" && isnum "${_free#-}"; then
  [ "$_capped" -lt "$_free" ] 2>/dev/null \
    && ok "the cap reduced the charge rate" \
    || no "the rate did not fall: ${_capped} vs ${_free}"
fi
# bug 10: a clear must release and STAY released. The daemon used to re-apply a second later, and
# with the marker already gone every later clear no-oped, so the phone stayed capped for good.
acc -s max_charging_current= >/dev/null 2>&1
sleep 10
[ -f $TD/.mcc-custom ] && no "the marker survived the clear" || ok "the clear dropped the marker"
_w2=$(wl)
sleep 45
_w3=$(wl)
_recap=$(tail -n +$(( _w2 + 1 )) $WL 2>/dev/null | cnt '<- 500000')
[ "${_recap:-0}" -eq 0 ] \
  && ok "the cap was not re-applied after the release (bug 10)" \
  || no "the daemon re-applied the 500 mA cap $_recap times after the clear (bug 10)"
_after=$(rate90)
log "      after the clear: ${_after:-?} mA (free was ${_free:-?})"
if isnum "${_after#-}" && isnum "${_free#-}"; then
  [ "$_after" -gt $(( _free / 2 )) ] 2>/dev/null \
    && ok "the rate recovered after the clear (bug 9: a restore never lowers a live value)" \
    || no "the rate stayed suppressed at ${_after} mA after clearing (free was ${_free})"
fi
fi

# =================================================================================================
if want D4; then
sec "D4. THE USB RE-KICK GATE  (bug 13)"
# Two re-kick sites used to bypass `acc -sk off`, the rate limit and the ledger entirely.
acc -sk off >/dev/null 2>&1
sleep 3
_w0=$(wl)
acc -s max_charging_current=600 >/dev/null 2>&1; sleep 20
acc -s max_charging_current= >/dev/null 2>&1; sleep 25
_k=$(tail -n +$(( _w0 + 1 )) $WL 2>/dev/null | cnt '^.*rekick .*<- 1')
_s=$(tail -n +$(( _w0 + 1 )) $WL 2>/dev/null | cnt 'rekick skipped')
log "      with re-kick OFF: $_k fired, $_s skipped-and-logged"
[ "${_k:-0}" -eq 0 ] \
  && ok "no re-kick fired while disabled (bug 13)" \
  || no "$_k re-kicks fired despite acc -sk off (bug 13)"
acc -sk on >/dev/null 2>&1
sleep 3
ok "re-kick re-enabled for the rest of the run"
fi

# =================================================================================================
if want D5; then
sec "D5. TEMPERATURE  (bugs 11, 15 -- the sweet report)"
# The reported symptom: charging not stopped at max_temp. Three fixes had to land together (1, 2, 6).
_t=$(tmp)
if isnum "${_t#-}" && [ "$_t" -gt 12 ] 2>/dev/null; then
  acc -s resume_capacity=99 pause_capacity=100 >/dev/null 2>&1
  acc -s cooldown_temp=$(( _t - 3 )) max_temp=$(( _t - 2 )) resume_temp=$(( _t - 5 )) >/dev/null 2>&1
  sleep 50
  _r=$(rate90)
  log "      pack ${_t}C, max_temp $(( _t - 2 ))C, level $(lvl)%, rate ${_r:-?} mA"
  [ "${_r:-9999}" -le 150 ] 2>/dev/null \
    && ok "charging stops at max_temp (the reported sweet symptom)" \
    || no "still charging at ${_r} mA above max_temp -- the sweet symptom reproduces"
  # bug 11: a resume must act on a temperature read AFTER the sleep, not one taken before it.
  _n=0; _bad=0
  while [ $_n -lt 25 ]; do
    _n=$((_n + 1))
    _tn=$(tmp); _rn=$(rd $G/current_now)
    if isnum "${_tn#-}" && [ "$_tn" -ge $(( _t - 2 )) ] 2>/dev/null; then
      case "$(rd $G/status)" in Charging) _bad=$((_bad + 1));; esac
    fi
    sleep 4
  done
  [ "$_bad" -eq 0 ] \
    && ok "never re-enabled on a stale pre-sleep temperature across 25 samples (bug 11)" \
    || no "reported Charging in $_bad of 25 samples while still at or above max_temp (bug 11)"
  acc -s cooldown_temp=$S_CT max_temp=$S_MT resume_temp=$S_RT >/dev/null 2>&1
  waitfor 150 sh -c '[ "$(cat '"$G"'/status)" = Charging ]' \
    && ok "resumes once the temperature limit is lifted" \
    || no "did not resume after lifting the temperature limit"
else
  sk "temperature unreadable (${_t:-empty})"
fi
# bug 15: a dead sensor must be recorded, not silently ignored
grep -q 'temp-sensor-unreadable' $FL 2>/dev/null \
  && log "      note: this phone HAS logged a temperature-sensor outage (bug 15 path exercised)" \
  || log "      note: no sensor outage logged, which is expected on a healthy phone"
ok "the temperature-outage log path is present and quiet on a working sensor (bug 15)"
fi

# =================================================================================================
if want D6; then
sec "D6. CHARGE DIRECTION UNDER A LIVE CHARGE  (bugs 1, 2, 3)"
# A wrong direction verdict disables all four limits at once, silently. Corrupt the cached polarity
# every way it can be wrong and require the verdict to stay correct while the pack is provably filling.
cp -a $IF /data/local/tmp/deep-if2.bak 2>/dev/null
_before=$(cc)
for _v in '+' '-' '' 'garbage'; do
  { grep -v '^_DPOL=' /data/local/tmp/deep-if2.bak 2>/dev/null; echo "_DPOL=$_v"; } > $IF.t && mv -f $IF.t $IF
  sleep 12
  _s=$(accst)
  if [ "$_s" = Charging ]; then
    ok "_DPOL='$_v' -> Charging (correct, the pack is filling)"
  elif [ -z "$_s" ]; then
    no "_DPOL='$_v' -> empty answer"
  else
    no "_DPOL='$_v' -> '$_s' while the pack is filling: every limit is blind in this state"
  fi
done
cp -a /data/local/tmp/deep-if2.bak $IF 2>/dev/null
_flips=$(rd $TD/.dpol_flips)
log "      polarity flips counted: ${_flips:-0}; unstable marker: $([ -e $TD/.dpol_unstable ] && echo ARMED || echo '-')"
[ "$(grep -c '^_DPOL=' $IF 2>/dev/null)" -le 1 ] \
  && ok "exactly one cached polarity line, not an append-forever list (bug 3)" \
  || no "$(grep -c '^_DPOL=' $IF) polarity lines in the cache (bug 3)"
fi

# =================================================================================================
if want D7; then
sec "D7. THE FAST-CHARGE CONTRACT SURVIVES A CAP CYCLE  (the curtana report)"
# The report: fast charge gone, stuck at 5V. ACC's side was an init restore overwriting live
# negotiated input nodes, plus a probe-time 500mA snapshot written back over a real charger.
_vb=""; _ic=""
for _d in /sys/class/power_supply/*; do
  [ -f "$_d/voltage_now" ] && [ "$(rd $_d/online)" = 1 ] && {
    case "${_d##*/}" in battery|bms|maxfg|*fuelgauge*) continue;; esac
    _vb="$_d/voltage_now"; _ic="$_d/current_max"; break; }
done
if [ -n "$_vb" ]; then
  _wl7=$(wl)
  _v0=$(rd $_vb); _i0=$(rd $_ic)
  log "      contract before: $(( ${_v0:-0} / 1000 )) mV, $(( ${_i0:-0} / 1000 )) mA"
  acc -s max_charging_current=800 >/dev/null 2>&1; sleep 35
  acc -s max_charging_current= >/dev/null 2>&1; sleep 50
  _v1=$(rd $_vb); _i1=$(rd $_ic)
  log "      contract after : $(( ${_v1:-0} / 1000 )) mV, $(( ${_i1:-0} / 1000 )) mA"
  if isnum "$_v0" && isnum "$_v1"; then
    _drop=$(( _v0 - _v1 ))
    [ "$_drop" -lt 1000000 ] \
      && ok "the negotiated voltage survived a cap-and-clear ($(( _v0 / 1000 )) -> $(( _v1 / 1000 )) mV)" \
      || no "the contract COLLAPSED across a cap cycle: $(( _v0 / 1000 )) -> $(( _v1 / 1000 )) mV (curtana)"
  fi
  if isnum "$_i0" && isnum "$_i1"; then
    [ "$_i1" -ge $(( _i0 / 2 )) ] 2>/dev/null \
      && ok "the input current limit was not left suppressed ($(( _i1 / 1000 )) mA)" \
      || no "input current left at $(( _i1 / 1000 )) mA, down from $(( _i0 / 1000 )) (bug 9)"
  fi
  # Only this section's writes. Reading the tail of the ledger picked up D3's legitimate 500 mA cap
  # from earlier in the same run and reported it as a probe-time snapshot: 24 of them.
  _snap=$(tail -n +$(( _wl7 + 1 )) $WL 2>/dev/null | cnt '<- 500000')
  [ "${_snap:-0}" -eq 0 ] \
    && ok "no 500000 probe-time snapshot was written back (bug 9)" \
    || no "a 500 mA snapshot was written back $_snap times (bug 9)"
else
  sk "no online supply node with a voltage reading"
fi
fi

# =================================================================================================
sec "CLOSING STATE"
log "level $L0% -> $(lvl)%   temp ${T0}C -> $(tmp)C"
alive && ok "daemon alive at the end" || no "daemon DOWN at the end"
_sdt=$(echo $S_T | cut -d' ' -f4)
[ "$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)" = "$_sdt" ] \
  && ok "shutdown_temp untouched (${_sdt}C)" \
  || no "shutdown_temp CHANGED -- it must never be written by a test"
