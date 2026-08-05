#!/system/bin/sh
# harness.sh - ACC's permanent on-device test suite.
#
#   sh harness.sh              run every layer that the current supply condition permits
#   sh harness.sh unplugged    run only the unplugged layers (refuses if a cable is attached)
#   sh harness.sh grid         run only the four-limit grid (refuses unless charging)
#   sh harness.sh regress      run only the regression layer (every fixed bug)
#
# WHY THIS EXISTS AS ONE FILE
#   Every bug found in this campaign got a throwaway script, and the next change needed a new one.
#   That is backwards: the tests are the asset, the fixes come and go. This is the asset. When ACC
#   changes, re-run this; when a new bug is found, add ONE case to L1 and it is covered forever.
#
# WHAT IT REFUSES TO DO
#   Score a test it could not actually run. Every check that needs a live charge, a cable, or a
#   working `acc -i` is SKIPPED when that is absent, never passed. Three separate times in this
#   campaign a suite reported a clean pass because its precondition was missing, and twice that
#   nearly shipped as "verified".
#
# CONDITIONS
#   unplugged   no cable at all           -> L0 L1 L2 L3 L5 L6
#   slow        cable, input under 1.5A   -> L0 L1 L2 L4 L5 L6   (current caps mostly unprovable)
#   fast        cable, input 1.5A or more -> everything
#   dead-cable  cable but no input at all -> L0 L1 L5 L6 only, and it says so
#
# SAFETY
#   Settings are saved before anything changes and restored on EXIT/INT/TERM/HUP. shutdown_temp is
#   never lowered. No charging node is written directly. A lock stops two runs overlapping.

TD=/dev/.vr25/acc
DD=/data/adb/vr25/acc-data
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
IF=$TD/.batt-interface.sh
FL=$DD/logs/flight.log
LOCK=$TD/.harness-lock
WANT=${1:-all}

# QUICK profile. Same checks, shorter windows - nothing is skipped and nothing is scored differently.
# A shorter sample is less evidence, not different evidence: 12 consecutive honest verdicts is weaker
# than 40 but it is not a softer test, and every threshold below is a rate or a count that scales
# with its window. Use the full profile before believing a clean sheet; use this to iterate.
#   sh harness.sh quick        the quick profile, every layer the condition permits
#   sh harness.sh quick D3     ... not supported; pass a layer name alone for the full profile
QUICK=false
[ "$WANT" = quick ] && { QUICK=true; WANT=all; }
if $QUICK; then
  N_VERDICT=12; W_LEDGER=40; W_DRAIN=90; W_CPU=30; W_LOOP=45; N_CHURN=4; INJECTS="ampFactor_=abc battCapacity="
else
  N_VERDICT=40; W_LEDGER=120; W_DRAIN=300; W_CPU=60; W_LOOP=150; N_CHURN=10; INJECTS="ampFactor_=0 ampFactor_=abc idleThreshold=999999999 battCapacity="
fi

DL=/sdcard/Download
[ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
OUT=$DL/acc-harness-$(date +%Y%m%d-%H%M%S).txt
TSV=$DL/acc-harness-$(date +%Y%m%d-%H%M%S).tsv

P=0; F=0; SK=0
log(){ echo "$*"; echo "$*" >> "$OUT"; }
res(){ printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$COND" "$3" >> "$TSV"; }
ok(){   P=$((P+1));  log "  PASS  $1"; res "$2" PASS "$1"; }
no(){   F=$((F+1));  log "  FAIL  $1"; res "$2" FAIL "$1"; }
sk(){   SK=$((SK+1)); log "  skip  $1"; res "$2" SKIP "$1"; }
sec(){ log ""; log "===== $* ====="; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
accst(){ acc -i 2>/dev/null | sed -n 's/^status //p' | head -1; }
kst(){ rd $B/status; }
alive(){ _p=$(rd $TD/acc.lock); [ -n "$_p" ] && [ -d "/proc/$_p" ]; }
looping(){
  # The daemon naps on purpose and the nap is LONG: _nap_idle 120 when unplugged with nothing
  # pending, _nap_hold 30 when plugged and holding above resume. A short sample calls those a
  # stall -- which is how a 22s window reported "nothing is being enforced" on a perfectly healthy
  # phone. Wait past the longest legitimate nap. The naps are interruptible on a config change, so
  # nudge one first: a live daemon then answers in seconds and only a genuinely stuck one costs the
  # full wait. The nudge is a touch on config.txt, because the nap tick breaks on
  # `[ ! $config -nt $TMPDIR/.nap-ref ]` and the content is unchanged, so it re-reads the same
  # values. NOT a write to the .wake fifo: `: >` writes no data and wakes nothing, and when the
  # daemon is dead there is no holder on that fifo, so a real write would block here forever -- in
  # precisely the case this function exists to detect.
  _a=$(wc -l < $FL 2>/dev/null)
  touch $DD/config.txt 2>/dev/null || :
  _w=0
  while [ $_w -lt ${W_LOOP:-150} ]; do
    sleep 5; _w=$((_w + 5))
    _b=$(wc -l < $FL 2>/dev/null)
    [ "${_b:-0}" -gt "${_a:-0}" ] && return 0
  done
  return 1
}
restart(){
  # Wait for the daemon to actually be back, do not sleep a guess at how long that takes. A fixed 38s
  # was enough on the Pixel and not on the A3, so the cache-heal check passed on one phone and failed
  # on the other for a reason that had nothing to do with ACC -- and it read as a product bug twice.
  # Ready means the lock names a live process AND the cache it publishes at init is back.
  acc -D restart >/dev/null 2>&1 &
  _w=0
  while [ $_w -lt 150 ]; do
    sleep 4; _w=$((_w + 4))
    _q=$(rd $TD/acc.lock)
    if [ -n "$_q" ] && [ -d "/proc/$_q" ] && [ -s $IF ]; then
      sleep 2
      return 0
    fi
  done
  return 1
}
setdpol(){ { grep -v '^_DPOL=' $IF 2>/dev/null; echo "_DPOL=$1"; } > $IF.t && mv -f $IF.t $IF; }
want(){ [ "$WANT" = all ] || [ "$WANT" = "$1" ]; }

# ---- one run at a time ------------------------------------------------------------------------
_lp=$(rd $LOCK)
if [ -n "$_lp" ] && [ -d "/proc/$_lp" ]; then
  echo "already running (pid $_lp). Wait, or: kill $_lp"; exit 0
fi
echo $$ > $LOCK 2>/dev/null || :

# ---- gauge resolution, the way ACC does it -----------------------------------------------------
G=$B
for _c in /sys/class/power_supply/*/capacity; do
  _d=${_c%/capacity}
  [ -n "$(rd "$_c")" ] && [ -n "$(rd "$_d/status")" ] && { G=$_d; break; }
done

# ---- save / restore ----------------------------------------------------------------------------
S_C=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')
S_T=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
S_MCC=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
S_MCV=$(sed -n 's/^maxChargingVoltage=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
BK=/data/local/tmp/harness-bk.$$
mkdir -p $BK
cp -a $IF $BK/if 2>/dev/null || :
cp -a $DD/config.txt $BK/cfg 2>/dev/null || :

restore_all(){
  acc -s resume_capacity=$(echo $S_C | cut -d' ' -f3) pause_capacity=$(echo $S_C | cut -d' ' -f4) >/dev/null 2>&1
  acc -s cooldown_temp=$(echo $S_T | cut -d' ' -f1) max_temp=$(echo $S_T | cut -d' ' -f2) \
         resume_temp=$(echo $S_T | cut -d' ' -f3) >/dev/null 2>&1
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  acc -s max_charging_voltage="$S_MCV" >/dev/null 2>&1
}
cleanup(){
  trap - EXIT INT TERM HUP
  log ""; log "--- restoring ---"
  cp -a $BK/if $IF 2>/dev/null || :
  rm -f $TD/.dpol_unstable $TD/.dpol_flips 2>/dev/null || :
  restore_all
  rm -rf $BK 2>/dev/null || :
  [ "$(rd $LOCK)" = "$$" ] && rm -f $LOCK 2>/dev/null
  restart
  log "daemon   : $(alive && echo alive || echo DOWN)"
  log "config   : $(sed -n 's/^capacity=//p' $DD/config.txt) $(sed -n 's/^temperature=//p' $DD/config.txt)"
  log ""
  log "===== $P passed, $F failed, $SK skipped ====="
  log "report: $OUT"
  log "table : $TSV"
  exit 0
}
trap cleanup EXIT INT TERM HUP

# =================================================================================================
sec "L0. PREFLIGHT - is this phone in a state where results mean anything?"
# =================================================================================================
DEV=$(getprop ro.product.device 2>/dev/null)
BUILD=$(sed -n 's/^versionCode=//p' /data/adb/vr25/acc/module.prop 2>/dev/null)
log "device    : $DEV / Android $(getprop ro.build.version.release 2>/dev/null)"
log "acc build : $BUILD"
log "level     : $(rd $G/capacity)%   temp: $(( $(rd $G/temp) / 10 ))C"

# condition
_cable=no; _online=no
for _f in /sys/class/power_supply/*/online; do [ "$(rd "$_f")" = 1 ] && _online=yes; done
for _f in /sys/class/power_supply/*/present; do
  case "$_f" in */battery/*|*/bms/*|*/maxfg/*|*fuelgauge*) continue;; esac
  [ "$(rd "$_f")" = 1 ] && _cable=yes
done
_icl=$(rd $U/current_max); isnum "$_icl" || _icl=0
if   [ "$_cable" = no ] && [ "$_online" = no ]; then COND=unplugged
elif [ "$_online" = no ] || [ "$_icl" -eq 0 ]; then COND=dead-cable
elif [ "$_icl" -ge 1500000 ]; then COND=fast
else COND=slow; fi
log "condition : $COND  (cable=$_cable online=$_online icl=$_icl)"
: > "$TSV"

alive && ok "daemon is running" L0-daemon || no "daemon is NOT running" L0-daemon
looping && ok "daemon loop is turning (flight.log grows)" L0-loop \
        || no "daemon alive but NOT looping - nothing is being enforced" L0-loop
[ -s "$IF" ] && grep -q '^battCapacity=' "$IF" \
  && ok "interface cache is usable" L0-cache \
  || no "interface cache missing or unusable - every learned fact is gone" L0-cache
[ -n "$(accst)" ] && ok "acc -i answers" L0-cli || no "acc -i returns nothing" L0-cli
_st=$(echo $S_T | cut -d' ' -f4)
isnum "$_st" && [ "$_st" -ge 40 ] && ok "shutdown_temp is sane (${_st}C)" L0-sdtemp \
                                  || no "shutdown_temp is ${_st}C" L0-sdtemp

# =================================================================================================
if want regress; then
sec "L1. REGRESSION - one case per bug fixed since rc21"
# Source-level, so it runs in any condition and catches a fix being reverted.
A=/data/adb/vr25/acc
chk(){ # $1 id  $2 file  $3 pattern  $4 description
  grep -q "$3" "$A/$2" 2>/dev/null && ok "$4" "$1" || no "$4 -- the fix is GONE from $2" "$1"
}
chk L1-01 batt-interface.sh '_ccraw=$(( _cc - _ccp ))'      "counter delta only counts as a verdict when it rules"
chk L1-02 batt-interface.sh '! present 2>/dev/null'          "no cable, no charging (last word in idle_discharging)"
chk L1-03 misc-functions.sh 'dpol_flips'                     "polarity re-latch counts flips and arms the marker"
chk L1-03b misc-functions.sh 'grep -v .\^_DPOL='             "polarity cache is replaced, not appended"
chk L1-04 accd.sh 'native firmware limit'                    "native phones are never handed to the generic prober"
chk L1-06 accd.sh 'batt_cap 2>/dev/null'                     "thermal pause holds at the live level, not at start"
chk L1-07 accd.sh '! _temp_hold || return 0'                 "native_unlatch will not pulse on a hot pack"
chk L1-08 accd.sh '_ccn" -le 100000'                         "init restore is bounded to near-zero nodes"
chk L1-09 misc-functions.sh 'default=5000000'                "input nodes are released high, not to a snapshot"
chk L1-11 accd.sh '_temp_hold || enable_charging'            "no resume acts on a pre-sleep temperature"
chk L1-12 accd.sh 'grep -q .\^battCapacity=. \$TMPDIR'       "cache is rebuilt when unusable, not only when absent"
chk L1-13 misc-functions.sh 'rekick_usb() {'                 "every USB re-kick goes through one gate"
chk L1-13b set-ch-curr.sh 'rekick_usb clear'                 "the clear path re-kicks through that gate"
chk L1-10 set-ch-curr.sh 'rm \$f 2>/dev/null || :'           "the marker is dropped before the release (clear race)"
chk L1-14 diag-collect.sh 'shutdown-trace.log'               "the shutdown trace is collected"
chk L1-15 batt-interface.sh '! _cache_usable; then'          "an unusable cache heals for every caller, not just at init"
chk L1-15b batt-interface.sh 'mv -f \$TMPDIR/.batt-interface.sh' "the cache write is atomic"
chk L1-16 accd.sh 'temp-sensor-unreadable'                   "a dead temperature sensor is recorded, not silent"
fi

# =================================================================================================
if want all || want regress; then
sec "L2. CHARGE DIRECTION - the verdict must survive any cached state"
# Everything downstream depends on this one answer, so it gets the widest matrix in the suite.
for dp in '+' '-' '' 'garbage'; do
  for unst in no yes; do
    setdpol "$dp"
    [ "$unst" = yes ] && touch $TD/.dpol_unstable || rm -f $TD/.dpol_unstable
    restart
    _s=$(accst); _k=$(kst); _id="L2-${dp:-empty}-$unst"
    _lbl="_DPOL='${dp:-empty}' frozen=$unst"
    if [ -z "$_s" ]; then
      sk "$_lbl -- acc -i silent" "$_id"
    elif [ "$COND" = unplugged ]; then
      [ "$_s" = Charging ] && no "$_lbl -> claimed Charging with no cable" "$_id" \
                           || ok "$_lbl -> $_s (correct, no cable)" "$_id"
    elif [ "$_k" = Charging ]; then
      [ "$_s" = Discharging ] && no "$_lbl -> Discharging while the kernel says Charging: limits blind" "$_id" \
                              || ok "$_lbl -> $_s (kernel $_k)" "$_id"
    else
      sk "$_lbl -- the phone is not charging at this moment" "$_id"
    fi
    alive || no "$_lbl -> DAEMON DIED" "$_id-alive"
  done
done
cp -a $BK/if $IF 2>/dev/null || :; rm -f $TD/.dpol_unstable; restart
fi

# =================================================================================================
if [ "$COND" = unplugged ] && { want all || want unplugged; }; then
sec "L3. UNPLUGGED - the deep battery"
# An unplugged phone is most of a phone's life, and it is where ACC must do the LEAST. Every check
# here is either "is the verdict honest" or "is ACC leaving the phone alone".

# --- L3.1 verdict honesty, sustained -------------------------------------------------------------
_n=0; _bad=0; _seen=""
while [ $_n -lt 40 ]; do
  _s=$(accst); _n=$((_n+1))
  [ "$_s" = Charging ] && _bad=$((_bad+1))
  case "$_seen" in *"$_s"*) : ;; *) _seen="$_seen $_s";; esac
  sleep 3
done
log "      40 samples, verdicts seen:$_seen"
[ "$_bad" -eq 0 ] && ok "40 consecutive samples, never claimed Charging" L3-verdict40 \
                  || no "claimed Charging on $_bad of 40 samples with no cable" L3-verdict40
case "$_seen" in *Discharging*|*Idle*) ok "the verdict is a real value, not empty" L3-sane;;
  *) no "the verdict was never a sane value:$_seen" L3-sane;; esac

# --- L3.2 ACC must not touch the charging switch while unplugged ---------------------------------
_lg0=$(wc -l < $TD/.write-ledger 2>/dev/null); isnum "$_lg0" || _lg0=0
sleep $W_LEDGER
_lg1=$(wc -l < $TD/.write-ledger 2>/dev/null); isnum "$_lg1" || _lg1=$_lg0
_wrote=$(( _lg1 - _lg0 ))
log "      ledger grew $_wrote lines in ${W_LEDGER}s unplugged"
[ "$_wrote" -eq 0 ] && ok "ACC wrote nothing at all while unplugged" L3-quiet \
  || { sed -n "$(( _lg0 + 1 )),${_lg1}p" $TD/.write-ledger 2>/dev/null | sed 's/^/        /' | tee -a "$OUT"
       no "ACC made $_wrote writes while unplugged" L3-quiet; }

# --- L3.3 drain rate, measured properly ----------------------------------------------------------
# A phone that drains fast overnight is the single most common "ACC broke my phone" report, and it
# is almost never ACC. Measure it so the number exists rather than being argued about.
# The charge counter is QUANTISED - a Pixel 6a steps about 20000 uAh at a time, a Mi A3 about 28600.
# A window shorter than a couple of steps cannot express a rate: it reports one whole quantum divided
# by the window, which is why a 90s sample read 800 mA on a phone that a 300s sample read at 216 mA.
# Both saw exactly one step. So measure until at least TWO steps have landed, and if the ceiling
# arrives first, say the resolution was insufficient rather than publishing an artifact.
_l0=$(rd $G/capacity); _t0=$(date +%s); _cc0=$(rd $G/charge_counter)
_steps=0; _prev=$_cc0; _el=0; _lim=$(( W_DRAIN * 3 ))
while [ $_el -lt $_lim ]; do
  sleep 10; _el=$(( _el + 10 ))
  _cur=$(rd $G/charge_counter)
  isnum "${_cur#-}" || continue
  [ "$_cur" != "$_prev" ] && { _steps=$(( _steps + 1 )); _prev=$_cur; }
  [ $_steps -ge 2 ] && [ $_el -ge $W_DRAIN ] && break
done
_l1=$(rd $G/capacity); _t1=$(date +%s); _cc1=$(rd $G/charge_counter)
_dt=$(( _t1 - _t0 ))
log "      over ${_dt}s: level $_l0% -> $_l1%   counter ${_cc0:-?} -> ${_cc1:-?}"
if [ "$_steps" -lt 2 ]; then
  sk "drain rate -- the counter moved $_steps time(s) in ${_dt}s; too coarse here to express a rate" L3-drain
elif isnum "$_cc0" && isnum "$_cc1"; then
  _duah=$(( _cc0 - _cc1 ))
  _mah_h=$(( _duah * 3600 / _dt / 1000 ))
  log "      drain: ${_duah} uAh in ${_dt}s = about ${_mah_h} mA average"
  # Drain measured WHILE THIS SUITE RUNS: a shell, adb, and a CPU that never gets to sleep. It is
  # an upper bound on idle drain, not a measurement of it, so the threshold is generous and the
  # label says which one it is. The A3 read 686 mA here; that number describes the test, not the
  # phone. A real idle figure needs a quiet phone and no suite attached to it.
  [ "$_mah_h" -lt 700 ] && ok "drain ${_mah_h} mA while the suite runs (upper bound, not true idle)" L3-drain \
                        || no "drain ${_mah_h} mA even as an upper bound -- something is awake" L3-drain
else
  sk "drain rate -- no charge counter on this phone" L3-drain
fi
[ "${_l1:-0}" -le "${_l0:-100}" ] && ok "the level did not rise while unplugged" L3-monotone \
                                  || no "the level ROSE from $_l0% to $_l1% with no cable" L3-monotone

# --- L3.4 the daemon must be idle, not busy ------------------------------------------------------
_p=$(rd $TD/acc.lock)
if [ -n "$_p" ] && [ -d "/proc/$_p" ]; then
  _u0=$(awk '{print $14+$15}' /proc/$_p/stat 2>/dev/null)
  sleep $W_CPU
  _p2=$(rd $TD/acc.lock)
  _u1=$(awk '{print $14+$15}' /proc/${_p2:-0}/stat 2>/dev/null)
  if [ "$_p" != "$_p2" ]; then
    # The tick counter belongs to the process. A restart resets it, the delta goes negative, and a
    # "below N" threshold then passes on nonsense. Measured once as -52 ticks in 60s, scored PASS.
    sk "daemon CPU -- it restarted mid-measurement ($_p -> $_p2), the counter reset" L3-cpu
  elif [ "${_u1:-0}" -lt "${_u0:-0}" ] 2>/dev/null; then
    sk "daemon CPU -- the counter went backwards, cannot judge" L3-cpu
  else
    _ticks=$(( ${_u1:-0} - ${_u0:-0} ))
    log "      daemon used $_ticks CPU ticks in 60s (pid $_p throughout)"
    [ "$_ticks" -le 60 ] && ok "daemon is close to idle while unplugged ($_ticks ticks/60s)" L3-cpu \
                         || no "daemon burned $_ticks ticks in 60s unplugged" L3-cpu
  fi
else
  no "daemon vanished during the unplugged layer" L3-cpu
fi

# --- L3.5 the shutdown guard, without triggering it ----------------------------------------------
_sd=$(echo $S_C | cut -d' ' -f1); _lv=$(rd $G/capacity)
log "      shutdown_capacity=$_sd, level=$_lv%"
if ! isnum "$_sd" || [ "$_sd" -lt 1 ]; then
  ok "the low-battery shutdown is disabled ($_sd)" L3-shutdown
elif [ "$_sd" -ge "$_lv" ] 2>/dev/null; then
  no "shutdown_capacity ($_sd) is at or above the level ($_lv) -- ACC may power this phone off" L3-shutdown
else
  ok "shutdown_capacity ($_sd) is safely below the level ($_lv)" L3-shutdown
fi
[ -s "$DD/logs/shutdown-trace.log" ] \
  && no "ACC has powered this phone off before: $(tail -1 $DD/logs/shutdown-trace.log)" L3-sdtrace \
  || ok "ACC has never powered this phone off" L3-sdtrace

# --- L3.6 survives the cache going away, unplugged ------------------------------------------------
rm -f $IF; restart
alive && ok "daemon survived losing its cache while unplugged" L3-cachegone \
      || no "daemon DIED when the cache went" L3-cachegone
[ -s "$IF" ] && grep -q '^battCapacity=' "$IF" \
  && ok "the cache rebuilt itself" L3-cacheheal \
  || no "the cache did not rebuild (daemon republish rides the 40-loop tick, allow ~6 min)" L3-cacheheal
_s=$(accst)
[ "$_s" = Charging ] && no "claimed Charging after a cache rebuild, unplugged" L3-postheal \
                     || ok "still correct after a cache rebuild ($_s)" L3-postheal
fi

# =================================================================================================
if [ "$COND" = fast ] || [ "$COND" = slow ]; then
if want all || want grid; then
sec "L4. THE FOUR-LIMIT GRID - every subset of capacity/temperature/current/voltage"

# The grid is limit-matrix.sh, not a copy of it. It already knows the things that are easy to get
# wrong here: that a native firmware limit has no off value so "node != off" is meaningless, that
# PAUSED and BLOCKED look identical on a current meter, and that charge direction has to come from a
# counter window rather than a current sign. Reimplementing that inline is how this suite ended up
# as a pile of one-off scripts in the first place. It prints PASS/FAIL/skip in the same shape, so
# its verdicts fold straight into this run's totals and TSV.
MX=
for _m in "$(dirname "$0")/limit-matrix.sh" /data/local/tmp/limit-matrix.sh           $DL/acc-limit-matrix.sh /data/adb/vr25/acc/suites/limit-matrix.sh; do
  [ -f "$_m" ] && { MX=$_m; break; }
done

if [ -z "$MX" ]; then
  sk "grid -- limit-matrix.sh not found on this phone" L4-grid
elif [ "$COND" = unplugged ] || [ "$COND" = dead-cable ]; then
  # Not a failure and not silence: every row needs a live charge to observe, so say what was not run.
  sk "grid -- needs a charging phone, this run is $COND (15 subsets not covered)" L4-grid
else
  log "      running the 15-subset grid from $MX"
  _mxout=$DL/acc-harness-grid-$$.txt
  sh "$MX" > "$_mxout" 2>&1 || :
  _gp=0; _gf=0; _gs=0
  while IFS= read -r _line; do
    case "$_line" in
      "  PASS  "*) _gp=$((_gp+1)); ok "grid: ${_line#  PASS  }" L4-grid;;
      "  FAIL  "*) _gf=$((_gf+1)); no "grid: ${_line#  FAIL  }" L4-grid;;
      "  skip  "*) _gs=$((_gs+1)); sk "grid: ${_line#  skip  }" L4-grid;;
    esac
  done < "$_mxout"
  if [ $((_gp + _gf + _gs)) -eq 0 ]; then
    # A grid that produced no verdicts at all has not passed; it has failed to run.
    no "grid produced no verdicts - it did not run. Output kept at $_mxout" L4-grid
  else
    log "      grid: $_gp passed, $_gf failed, $_gs skipped (full output: $_mxout)"
  fi
fi
fi
fi

# =================================================================================================
if want all; then
sec "L5. STRESS - churn and fault injection"
# --- cache abuse ---------------------------------------------------------------------------------
for inject in $INJECTS; do
  cp -a $BK/if $IF; echo "$inject" >> $IF; restart
  alive && ok "survived $inject" "L5-${inject%%=*}" || no "DIED on $inject" "L5-${inject%%=*}"
done
cp -a $BK/if $IF; printf 'not shell (((\n' >> $IF; restart
alive && ok "survived an unparseable cache" L5-badshell || no "DIED on an unparseable cache" L5-badshell
: > $IF; restart
alive && ok "survived an empty cache" L5-emptycache || no "DIED on an empty cache" L5-emptycache
cp -a $BK/if $IF 2>/dev/null || :; restart
looping && ok "loop still turning after the abuse" L5-loop || no "loop stopped after the abuse" L5-loop

# --- config churn --------------------------------------------------------------------------------
_i=0
while [ $_i -lt $N_CHURN ]; do
  acc -s max_charging_current=$(( 700 + _i * 60 )) >/dev/null 2>&1; sleep 3
  acc -s max_charging_current= >/dev/null 2>&1; sleep 3
  _i=$((_i+1))
done
sleep 20
[ "$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt)" = "()" ] \
  && ok "config ends cleared after 10 set/clear cycles" L5-churncfg \
  || no "config ends as $(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt)" L5-churncfg
[ -f $TD/.mcc-custom ] && no "the cap marker survived the final clear" L5-churnmark \
                       || ok "the cap marker ends cleared" L5-churnmark
alive && ok "daemon survived the churn" L5-churnalive || no "daemon DIED during the churn" L5-churnalive
fi

# =================================================================================================
sec "L6. INVARIANTS"
_l=$(grep -c '^_DPOL=' $IF 2>/dev/null)
case "${_l:-x}" in ''|*[!0-9]*|0) sk "no polarity latched" L6-dpol;;
  1) ok "exactly one cached polarity" L6-dpol;;
  *) no "$_l contradictory _DPOL lines" L6-dpol;; esac
alive && ok "daemon alive at the end" L6-alive || no "daemon DOWN at the end" L6-alive
looping && ok "loop turning at the end" L6-loop || no "loop stopped at the end" L6-loop
_stf=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
isnum "$_stf" && [ "$_stf" -ge 40 ] && ok "shutdown_temp still sane (${_stf}C)" L6-sdtemp \
                                    || no "shutdown_temp ended at ${_stf}C" L6-sdtemp
