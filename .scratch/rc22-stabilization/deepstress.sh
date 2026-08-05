#!/system/bin/sh
# deepstress.sh - the full adversarial pass over everything found in this campaign.
#
# Charge direction gates every limit ACC has, so most of this attacks that: the cached polarity,
# the marker that freezes it, the cache file it lives in, and the verdict's stability under noise.
# The rest re-checks each field report and then churns the config hard enough to shake out anything
# that only breaks under load.
#
# SAFETY
#   Every file touched is backed up and restored on EXIT/INT/TERM/HUP, including a daemon restart.
#   Only ACC settings and ACC's own tmpfs state are written. No charging node is written directly,
#   and shutdown_temp is never lowered.
#
# HONESTY
#   Anything that cannot be exercised in the current state is SKIPPED, never passed. A check that
#   silently passes because its precondition was absent is worse than no check.

TD=/dev/.vr25/acc
DD=/data/adb/vr25/acc-data
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
IF=$TD/.batt-interface.sh
F=$DD/logs/flight.log
BK=/data/local/tmp/ds-bk.$$
P=0; FA=0; SK=0

ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ FA=$((FA+1)); echo "  FAIL  $*"; }
sk(){ SK=$((SK+1)); echo "  skip  $*"; }
sec(){ echo; echo "===== $* ====="; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
accst(){ acc -i 2>/dev/null | sed -n 's/^status //p' | head -1; }
alive(){ _p=$(rd $TD/acc.lock); [ -n "$_p" ] && [ -d "/proc/$_p" ]; }
looping(){ _a=$(wc -l < $F 2>/dev/null); sleep 22; _b=$(wc -l < $F 2>/dev/null); [ "${_b:-0}" -gt "${_a:-0}" ]; }
restart(){ acc -D restart >/dev/null 2>&1 & sleep 38; }
kst(){ rd $B/status; }
setdpol(){ { grep -v '^_DPOL=' $IF 2>/dev/null; echo "_DPOL=$1"; } > $IF.t && mv -f $IF.t $IF; }

mkdir -p $BK
# The cache is what section C corrupts and restores, and what acc -i needs to answer at all. It is
# rebuilt by the daemon a few loops after a restart, and ab.sh now clears it between builds -- so a
# run started too soon has nothing to back up, every "restore" silently does nothing, and the cache
# is destroyed for the rest of the suite. Wait for it rather than proceeding on a lie.
_w=0
while [ $_w -lt 120 ]; do
  [ -s "$IF" ] && grep -q '^battCapacity=' "$IF" 2>/dev/null && break
  _w=$((_w + 10)); sleep 10
done
if [ ! -s "$IF" ] || ! grep -q '^battCapacity=' "$IF" 2>/dev/null; then
  echo "ABORT: no usable interface cache after ${_w}s. Nothing below could be trusted."
  exit 1
fi
cp -a $IF $BK/if || { echo "ABORT: could not back up the interface cache"; exit 1; }
echo "cache backed up: $(wc -l < $BK/if) lines"
cp -a $DD/config.txt $BK/cfg 2>/dev/null || :
S_MCC=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
S_T=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
S_C=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')

cleanup(){
  trap - EXIT INT TERM HUP
  echo; echo "--- restoring ---"
  cp -a $BK/if $IF 2>/dev/null || :
  cp -a $BK/cfg $DD/config.txt 2>/dev/null || :
  rm -f $TD/.dpol_unstable $TD/.dpol_flips 2>/dev/null || :
  rm -rf $BK 2>/dev/null || :
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  acc -s cooldown_temp=$(echo $S_T|cut -d' ' -f1) max_temp=$(echo $S_T|cut -d' ' -f2) \
         resume_temp=$(echo $S_T|cut -d' ' -f3) >/dev/null 2>&1
  acc -s resume_capacity=$(echo $S_C|cut -d' ' -f3) pause_capacity=$(echo $S_C|cut -d' ' -f4) >/dev/null 2>&1
  restart
  echo "daemon: $(alive && echo alive || echo DOWN)"
  echo "config: $(sed -n 's/^capacity=//p' $DD/config.txt) $(sed -n 's/^temperature=//p' $DD/config.txt) mcc=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt)"
  echo
  echo "===== $P passed, $FA failed, $SK skipped ====="
  exit 0
}
trap cleanup EXIT INT TERM HUP

echo "=== ACC deep stress $(date) ==="
echo "build : $(sed -n 's/^commit=//p' /data/adb/vr25/acc/.build-id 2>/dev/null)"
echo "device: $(getprop ro.product.device)  level=$(rd $B/capacity)%  temp=$(( $(rd $B/temp) / 10 ))C"
echo "state : kernel=$(kst) acc=$(accst) online=$(rd $U/online) icl=$(rd $U/current_max)"

CHG=no; [ "$(kst)" = Charging ] && CHG=yes
# Which of the three supply conditions is this? Results are only comparable within a condition:
# a slow port cannot demonstrate a current cap, and an unplugged phone cannot demonstrate any limit.
COND=unknown
_plug=no
for _f in /sys/class/power_supply/*/online; do [ "$(rd "$_f")" = 1 ] && _plug=yes; done
for _f in /sys/class/power_supply/*/present; do [ "$(rd "$_f")" = 1 ] && _plug=yes; done
_icl=$(rd $U/current_max); isnum "$_icl" || _icl=0
if [ "$_plug" = no ]; then COND=unplugged
elif [ "$_icl" -ge 1500000 ]; then COND=fast
elif [ "$_icl" -gt 0 ]; then COND=slow
else COND=plugged-but-no-input; fi
echo "condition: $COND (icl=$_icl plugged=$_plug)"
echo "charging: $CHG"
ACCOK=yes; [ -n "$(accst)" ] || ACCOK=no
echo "acc -i answering: $ACCOK"
[ "$ACCOK" = yes ] || echo "NOTE: acc -i returns nothing, so every verdict check will be SKIPPED, not passed."
[ "$CHG" = yes ] || echo "NOTE: not charging -- every check that needs a live charge will be SKIPPED, not passed."

# =================================================================================================
sec "A. POLARITY MATRIX - every cached state, is the verdict still right?"
# The verdict must be right whatever the cache says, because the cache is a learned guess and the
# kernel status plus the coulomb counter are there to overrule it.
for dp in '+' '-' '' 'garbage'; do
  for unst in no yes; do
    setdpol "$dp"
    [ "$unst" = yes ] && touch $TD/.dpol_unstable || rm -f $TD/.dpol_unstable
    restart
    _st=$(accst); _k=$(kst)
    _lbl="_DPOL='${dp:-empty}' unstable=$unst"
    if [ "$CHG" != yes ]; then
      sk "A $_lbl -- not charging"
    elif [ -z "$_st" ]; then
      sk "A $_lbl -- acc -i returned nothing, the verdict cannot be read"
    elif [ "$_st" = Discharging ]; then
      no "A $_lbl -> acc=Discharging while kernel=$_k: every limit is skipped"
    else
      ok "A $_lbl -> acc=$_st (kernel=$_k)"
    fi
    alive || no "A $_lbl -> DAEMON DIED"
  done
done
cp -a $BK/if $IF 2>/dev/null || :; rm -f $TD/.dpol_unstable

# =================================================================================================
sec "B. SENSITIVITY - does the verdict flutter on noise?"
# A verdict that flips sample to sample is as bad as a wrong one: limits would engage and release
# at random. Sample fast and count changes.
restart
_prev=; _flip=0; _n=0; _dis=0
i=0
while [ $i -lt 24 ]; do
  _s=$(accst); _n=$((_n+1))
  # Count a Discharging claim only when the KERNEL says it is charging at that moment. On a slow
  # supply the phone genuinely stops and starts, and a flag read minutes ago cannot tell the
  # difference between a wrong verdict and a phone that really is not charging.
  [ "$(kst)" = Charging ] && _chg=$(( ${_chg:-0} + 1 ))
  [ -n "$_prev" ] && [ "$_s" != "$_prev" ] && _flip=$((_flip+1))
  [ "$_s" = Discharging ] && [ "$(kst)" = Charging ] && _dis=$((_dis+1))
  _prev=$_s; i=$((i+1)); sleep 3
done
echo "      $_n samples, $_flip changes, ${_chg:-0} taken while the kernel said Charging, $_dis of those said Discharging"
_empty=0
[ -z "$_prev" ] && _empty=1
if [ "$CHG" != yes ]; then
  sk "B -- not charging"
elif [ "$_empty" = 1 ]; then
  sk "B -- acc -i returned nothing; an empty verdict is not stability"
else
  [ "$_flip" -le 2 ] && ok "B verdict is stable ($_flip changes in $_n samples)" \
                     || no "B verdict fluttered $_flip times in $_n samples"
  if [ "${_chg:-0}" -lt 5 ]; then
    sk "B -- the phone was only charging on ${_chg:-0} of $_n samples, too few to judge the verdict"
  elif [ "$_dis" -eq 0 ]; then
    ok "B never claimed Discharging while the kernel said Charging (${_chg} such samples)"
  else
    no "B claimed Discharging on $_dis of ${_chg} samples taken while the kernel said Charging"
  fi
fi

# =================================================================================================
sec "C. EDGE CASES - garbage in the learned facts"
_c=0
for inject in "ampFactor_=0" "ampFactor_=abc" "idleThreshold=999999999" "battCapacity=" "_STI=0"; do
  cp -a $BK/if $IF
  echo "$inject" >> $IF
  restart
  if alive; then ok "C survived $inject"; else no "C DIED on $inject"; fi
  _c=$((_c+1))
done
# a cache that is not shell at all
cp -a $BK/if $IF; printf 'this is not shell ((( \n' >> $IF
restart
alive && ok "C survived a cache that is not valid shell" || no "C DIED on an unparseable cache"
# empty cache
: > $IF; restart
alive && ok "C survived an empty cache" || no "C DIED on an empty cache"
# missing cache
rm -f $IF; restart
alive && ok "C survived a missing cache" || no "C DIED on a missing cache"
# Put the cache back and RESTART, or the daemon keeps the facts it derived from a broken cache
# while the file on disk says something else -- which is what made the temperature section fail on
# both phones last run (temp_now fell back to its 25C default and no limit could ever trip).
cp -a $BK/if $IF || no "C could not restore the cache"
restart
_dp=$(grep -c '^_DPOL=' $IF 2>/dev/null)
_bc=$(sed -n 's/^battCapacity=//p' $IF 2>/dev/null)
echo "      after restore: ${_dp:-0} polarity line(s), battCapacity=${_bc:-MISSING}"
[ -n "$_bc" ] && ok "C the cache is intact again after the abuse" || no "C the cache did not survive"
[ -n "$(accst)" ] && ok "C acc -i answers again" || no "C acc -i still returns nothing"
looping && ok "C loop still running after the cache abuse" || no "C loop stopped"

# =================================================================================================
sec "D. CONFIG CHURN - 12 rapid set/clear cycles"
# Field bug: clearing a current cap released the nodes and the daemon re-applied it a second later,
# and with the marker gone every later restore no-oped. Churn hard and check the end state is clean.
_L=$TD/.write-ledger
_n0=$(wc -l < $_L 2>/dev/null); isnum "$_n0" || _n0=0
i=0
while [ $i -lt 12 ]; do
  acc -s max_charging_current=$(( 700 + i * 50 )) >/dev/null 2>&1
  sleep 4
  acc -s max_charging_current= >/dev/null 2>&1
  sleep 4
  i=$((i+1))
done
sleep 25
_cfg=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt)
_mk=$([ -f $TD/.mcc-custom ] && echo present || echo absent)
echo "      after 12 cycles: config=$_cfg marker=$_mk icl=$(rd $U/current_max)"
[ "$_cfg" = "()" ] && ok "D the config ends cleared" || no "D the config ends as '$_cfg'"
[ "$_mk" = absent ] && ok "D the marker ends cleared" || no "D the marker survived the final clear"
alive && ok "D daemon survived the churn" || no "D daemon DIED during the churn"
looping && ok "D loop still running after the churn" || no "D loop stopped after the churn"
# the last write to an input node must be a release, not a cap
_n1=$(wc -l < $_L 2>/dev/null); isnum "$_n1" || _n1=$_n0
_last=$(sed -n "$(( _n0 + 1 )),${_n1}p" $_L 2>/dev/null | grep 'current_max <-' | tail -1)
echo "      last input-node write: ${_last:-none}"
case "${_last:-}" in
  *"<- 5000000"*) ok "D the churn ends on a release";;
  '') sk "D no input-node writes recorded";;
  *) no "D the churn ends on a cap, not a release: $_last";;
esac

# =================================================================================================
sec "E. TEMPERATURE - the limit must act, and must not act early"
if [ "$CHG" != yes ]; then
  sk "E -- not charging"
else
  _t=$(( $(rd $B/temp) / 10 ))
  if [ $(( _t - 8 )) -lt 15 ]; then
    sk "E -- pack at ${_t}C is too cool to place a limit under it"
  else
    # Lift the capacity limit clear of the level first. This section takes minutes on a charging
    # phone and the level drifts up into pause_capacity while it runs, which then pauses charging
    # for a reason that has nothing to do with temperature and reads as a thermal latch. Measured on
    # a Mi A3: it charged 58% -> 76% across the run, and 76 was its pause_capacity exactly.
    _lv0=$(rd $B/capacity); isnum "$_lv0" || _lv0=0
    acc -s resume_capacity=$(( _lv0 + 15 )) pause_capacity=$(( _lv0 + 20 )) >/dev/null 2>&1
    sleep 10
    # well ABOVE the pack: must keep charging
    acc -s cooldown_temp=$(( _t + 8 )) max_temp=$(( _t + 10 )) resume_temp=$(( _t + 5 )) >/dev/null 2>&1
    sleep 45
    [ "$(kst)" = Charging ] && ok "E limit 10C above the pack -> still charging" \
                            || no "E limit 10C above the pack -> stopped charging anyway"
    # BELOW the pack: must stop. Re-read the temperature first -- the steps above take a minute and
    # a pack on a slow supply cools while they run, so a limit derived from the old reading can land
    # ABOVE the pack and correctly not trip. Measured on a Pixel 6a at 500mA.
    _t2=$(rd $B/temp); isnum "$_t2" && _t2=$(( _t2 / 10 )) || _t2=$_t
    acc -s cooldown_temp=$(( _t2 - 4 )) max_temp=$(( _t2 - 2 )) resume_temp=$(( _t2 - 8 )) >/dev/null 2>&1
    sleep 50
    _k=$(kst); _sw=$(rd $B/input_suspend)
    [ "$_k" != Charging ] || [ "$_sw" = 1 ] && ok "E limit 2C below the pack -> stopped (kernel=$_k switch=$_sw)" \
                                            || no "E limit 2C below the pack -> STILL CHARGING"
    # back above: must resume
    acc -s cooldown_temp=$(( _t + 8 )) max_temp=$(( _t + 10 )) resume_temp=$(( _t + 5 )) >/dev/null 2>&1
    sleep 55
    _lvE=$(rd $B/capacity)
    if [ "$(kst)" = Charging ]; then
      ok "E raising the limit resumed charging"
    elif [ "${_lvE:-0}" -ge "$(( _lv0 + 20 ))" ] 2>/dev/null; then
      sk "E the level reached the capacity limit during the run (${_lvE}%), so this cannot be judged"
    else
      no "E raising the limit did NOT resume charging (a latch)"
    fi
    acc -s resume_capacity=$(echo $S_C | cut -d' ' -f3) pause_capacity=$(echo $S_C | cut -d' ' -f4) >/dev/null 2>&1
    sleep 10
  fi
fi

# =================================================================================================
sec "F. CAPACITY - pause and resume"
if [ "$CHG" != yes ]; then
  sk "F -- not charging"
else
  _lv=$(rd $B/capacity)
  acc -s resume_capacity=$(( _lv - 3 )) pause_capacity=$(( _lv - 1 )) >/dev/null 2>&1
  sleep 50
  _k=$(kst); _sw=$(rd $B/input_suspend)
  [ "$_k" != Charging ] || [ "$_sw" = 1 ] && ok "F pause below the level -> stopped" \
                                          || no "F pause below the level -> STILL CHARGING"
  acc -s resume_capacity=$(( _lv + 10 )) pause_capacity=$(( _lv + 15 )) >/dev/null 2>&1
  sleep 55
  [ "$(kst)" = Charging ] && ok "F raising the limit resumed charging" \
                          || no "F raising the limit did NOT resume (a latch)"
fi

# =================================================================================================
sec "H. UNPLUGGED - no cable, no charging"
# All three arbiters are inferences and all three failed together here before rc22: opposite current
# signs on two phones, opposite cached polarities, both reported as Charging with nothing attached.
if [ "$COND" != unplugged ]; then
  sk "H -- a cable is attached ($COND)"
else
  _bad=0; _n=0
  i=0
  while [ $i -lt 8 ]; do
    _s=$(accst); _n=$((_n+1))
    [ "$_s" = Charging ] && _bad=$((_bad+1))
    i=$((i+1)); sleep 5
  done
  echo "      $_n samples with no cable, $_bad said Charging"
  [ "$_bad" -eq 0 ] && ok "H never claimed Charging with no cable"                     || no "H claimed Charging on $_bad of $_n samples with no cable"
  # And with the polarity deliberately inverted, which is what made it wrong on both phones.
  _cur=$(sed -n 's/^_DPOL=//p' $IF 2>/dev/null | tail -1)
  case "$_cur" in +) _bad2=-;; -) _bad2=+;; *) _bad2=+;; esac
  setdpol "$_bad2"; restart
  _s=$(accst)
  echo "      with _DPOL forced to '$_bad2': acc=$_s"
  [ "$_s" = Charging ] && no "H an inverted polarity makes it claim Charging with no cable"                        || ok "H still correct with an inverted polarity ($_s)"
  cp -a $BK/if $IF 2>/dev/null || :
fi

# =================================================================================================
sec "G. INVARIANTS - things that must be true at the end"
_l=$(grep -c '^_DPOL=' $IF 2>/dev/null)
case "${_l:-x}" in ''|*[!0-9]*|0) sk "G no polarity latched";; 1) ok "G exactly one cached polarity";; *) no "G $_l contradictory _DPOL lines";; esac
_st=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')' | cut -d' ' -f4)
isnum "$_st" && [ "$_st" -ge 40 ] && ok "G shutdown_temp is sane (${_st}C)" || no "G shutdown_temp is ${_st}C"
alive && ok "G daemon alive at the end" || no "G daemon DOWN at the end"
looping && ok "G loop running at the end" || no "G loop stopped at the end"
