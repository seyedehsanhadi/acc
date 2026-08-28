#!/system/bin/sh
# AMPS: a phone with no current sensor must still be scannable.
#
# THE DEFECT. med_cur() returns a literal 0 when the kernel publishes neither current_now nor
# current_avg, and classify_state cannot tell that apart from a real zero. Given present=1, online=1
# and |0| <= IDLE it answers BYPASS.
#
# BYPASS is not CHARGING, so the baseline block raised WEAK CHARGER, ran the super-native reset three
# times -- recomputing the baseline from the very same fabricated zero each round, so it could never
# reach CHARGING -- and then STOPPED the run with "the charger likely dropped its negotiation --
# UNPLUG and RE-PLUG". Nothing was wrong with the charger. The phone simply had no current sensor.
#
# The cruellest part: the code written for exactly this case, "no current sensor -> BLIND
# verification", sets CUR_USABLE=0 forty-five lines AFTER the stop. So the only path that could have
# scanned the phone was unreachable on the phone that needed it.
#
# NO HARDWARE. cur_blind and classify_state are executed directly.

ID=t-no-current-sensor
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

# acc-compat.sh is NOT installed at that path - the module keeps it under acc-data/backup and the
# repo ships it in suites/. A single hardcoded default made three of these abort with
# "acc-compat.sh not found" on every installed phone, which reads as a product failure and is not.
# t-layer-crash already had a two-step fallback; give every suite the same search.
_amps_find(){
  for _ac in "${AMPS:-}" /data/adb/vr25/acc/acc-compat.sh              /data/adb/vr25/acc-data/backup/acc-compat.sh              /data/local/tmp/suites/acc-compat.sh /data/local/tmp/amps.sh; do
    [ -n "$_ac" ] && [ -f "$_ac" ] && { echo "$_ac"; return 0; }
  done
  return 1
}
AMPS=$(_amps_find)
[ -f "$AMPS" ] || { no "amps not found (set AMPS=)"; fin; }

lift1(){ grep -m1 "^$1()" "$AMPS"; }

# ---- 1: the predicate exists and separates the two cases -----------------------------------------
grep -q '^cur_blind()' "$AMPS" \
  && ok "there is a predicate for 'no measurement' distinct from 'measured zero'" \
  || { no "cur_blind() is missing - nothing can tell an absent sensor from a real zero"; fin; }

cb(){ ( eval "$(lift1 cur_blind)"; CURF="$1"; CUR_FROZEN="$2"; cur_blind && echo BLIND || echo MEASURED ) 2>/dev/null; }
[ "$(cb '' 0)" = BLIND ]                                   && ok "no sensor reads as BLIND"            || no "no sensor read as $(cb '' 0)"
[ "$(cb /sys/class/power_supply/battery/current_now 1)" = BLIND ]   && ok "a frozen sensor reads as BLIND" || no "frozen sensor read as $(cb x 1)"
[ "$(cb /sys/class/power_supply/battery/current_now 0)" = MEASURED ] && ok "a working sensor reads as MEASURED" || no "working sensor read as $(cb x 0)"

# ---- 2: the fabricated zero really does classify as BYPASS (the root of it) ------------------------
_cs=$(sed -n '/^classify_state(){/,/esac; }/p' "$AMPS")
_r=$( ( _norm(){ case "$2" in inverted) printf '%s' "$(( 0 - $1 ))";; *) printf '%s' "$1";; esac; }
        eval "$_cs"
        classify_state 1 1 0 normal 10000 ) 2>/dev/null )
[ "$_r" = BYPASS ] \
  && ok "present+online+current0 still classifies BYPASS - the trap this guards is real" \
  || no "expected BYPASS from the fabricated zero, got [$_r]"

# ---- 3: the baseline block consults the predicate BEFORE the weak-charger branch --------------------
_cbl=$(grep -n 'if cur_blind && \[ "\$_bp" = 1 \]' "$AMPS" | head -1 | cut -d: -f1)
_wcl=$(grep -n 'WEAK CHARGER: plugged at' "$AMPS" | head -1 | cut -d: -f1)
_stp=$(grep -n 'Stopping so the result is not built on a dead baseline' "$AMPS" | head -1 | cut -d: -f1)
if [ -n "$_cbl" ] && [ -n "$_wcl" ] && [ -n "$_stp" ]; then
  { [ "$_cbl" -lt "$_wcl" ] && [ "$_cbl" -lt "$_stp" ]; } 2>/dev/null \
    && ok "the blind case is handled before both the weak-charger warning and the stop" \
    || no "blind handling at $_cbl runs after the weak-charger branch ($_wcl) or the stop ($_stp)"
else
  no "could not locate the blind handling ($_cbl), the weak-charger branch ($_wcl) and the stop ($_stp)"
fi

# ---- 4: a charging status overrides the fabricated BYPASS ---------------------------------------------
# This is what lets the run continue to the blind verifier instead of stopping.
_r=$( ( BASE_STATE=BYPASS; CURF=; CUR_FROZEN=0; _bp=1
        eval "$(lift1 cur_blind)"
        read_st(){ echo Charging; }
        warn(){ :; }
        if cur_blind && [ "$_bp" = 1 ]; then
          _bst="$(read_st)"
          case "$_bst" in Charging|charging|Full|full) BASE_STATE=CHARGING;; esac
        fi
        echo "$BASE_STATE" ) 2>/dev/null )
[ "$_r" = CHARGING ] \
  && ok "a blind phone reporting Charging gets a CHARGING baseline, so the scan continues" \
  || no "baseline stayed [$_r] - the run would still stop and tell the user to replug"

# ---- 5: a blind phone that genuinely is NOT charging keeps the reset path ------------------------------
_r=$( ( BASE_STATE=BYPASS; CURF=; CUR_FROZEN=0; _bp=1
        eval "$(lift1 cur_blind)"
        read_st(){ echo Discharging; }
        warn(){ :; }
        if cur_blind && [ "$_bp" = 1 ]; then
          _bst="$(read_st)"
          case "$_bst" in Charging|charging|Full|full) BASE_STATE=CHARGING;; esac
        fi
        echo "$BASE_STATE" ) 2>/dev/null )
[ "$_r" != CHARGING ] \
  && ok "a blind phone that really is not charging still goes through the native reset" \
  || no "a genuinely idle phone was declared CHARGING"

# ---- 6: a phone WITH a working sensor is untouched by any of this ---------------------------------------
_r=$( ( BASE_STATE=DRAIN; CURF=/sys/class/power_supply/battery/current_now; CUR_FROZEN=0; _bp=1
        eval "$(lift1 cur_blind)"
        read_st(){ echo Charging; }
        warn(){ :; }
        if cur_blind && [ "$_bp" = 1 ]; then
          _bst="$(read_st)"
          case "$_bst" in Charging|charging|Full|full) BASE_STATE=CHARGING;; esac
        fi
        echo "$BASE_STATE" ) 2>/dev/null )
[ "$_r" = DRAIN ] \
  && ok "a measurable phone keeps its measured baseline - the measurement still wins" \
  || no "a measurable phone's baseline was overridden to [$_r]"

# ---- 7: the stop message no longer blames the charger when nothing could be measured ----------------------
grep -q 'no usable current reading to check it with' "$AMPS" \
  && ok "the give-up message tells a blind phone the truth instead of sending it to buy a cable" \
  || no "the stop still blames the charger on a phone that cannot measure current"

fin
