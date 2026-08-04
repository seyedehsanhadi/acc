#!/system/bin/sh
# t39 - the native thermal pause must actually pause, at any state of charge.
#
# sync_native_limit forced a thermal pause by clamping charge_stop_level down to charge_start_level.
# But the firmware only holds when level >= charge_stop_level, so that clamp does nothing at all
# whenever the pack sits BELOW the start level -- which is most of a charge.
#
# Measured on a Pixel 6a: pack 38C against a 37C limit, stop=82, start=70, level=63, still drawing
# 1.2A with the temperature limit supposedly in force. The limit was silently absent.
#
# The hold now sits AT the present level, with start one point under it so the firmware does not
# resume immediately. Recomputed every loop, so it follows the pack down as it drains and lifts on
# its own once the temperature falls back under max_temp.
#
# Pure unit test: the computation is reproduced against fake values. No node is read or written.

ID=t39
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/accd.sh
[ -f "$SRC" ] || { no "accd.sh not found"; fin; }

_fn=$(sed -n '/^  sync_native_limit() {/,/^  }/p' "$SRC")
[ -n "$_fn" ] || { no "could not isolate sync_native_limit"; fin; }

# ---- source level ------------------------------------------------------------------------------
printf '%s' "$_fn" | grep -q 'batt_cap' \
  && ok "the thermal force consults the live level" \
  || no "the thermal force never reads the level - it cannot know whether it actually pauses"

printf '%s' "$_fn" | grep -q 'start=$(( start - 1 ))' \
  && ok "start is put below the hold point so the firmware does not resume at once" \
  || no "start is not lowered - the firmware would resume immediately"

grep -q 'local stop=${capacity\[3\]:-80} start=${capacity\[2\]:-75} t _tl=' "$SRC" \
  && ok "the level variable is declared local" \
  || no "_tl is not local - it would leak across loops"

# ---- behavioural: reproduce the computation ------------------------------------------------------
# $1 pack temp (deci-C), $2 max_temp (C), $3 level, $4 pause_capacity, $5 resume_capacity
# echoes "stop start"
calc() {
  _t=$1; _mt=$2; _lv=$3; stop=$4; start=$5
  if [ "$_t" -ge $(( _mt * 10 )) ]; then
    if [ "$_lv" -lt "$start" ]; then
      stop=$_lv; start=$_lv
      [ "$start" -le 0 ] || start=$(( start - 1 ))
    else
      stop=$start
      [ "$start" -le 0 ] || start=$(( start - 1 ))
    fi
  fi
  echo "$stop $start"
}
# does the firmware hold, given "stop start" and a level?
holds() { _lvl=$2; set -- $1; [ "$_lvl" -ge "$1" ]; }

# THE BUG: hot pack, battery well below the resume level.
_r=$(calc 380 37 63 87 82)
holds "$_r" 63 && ok "hot pack at 63% with resume 82 -> holds (stop $(echo $_r | cut -d' ' -f1))" \
              || no "hot pack at 63% does NOT hold: stop/start = $_r -- the Pixel 6a case"

_r=$(calc 380 37 20 87 82)
holds "$_r" 20 && ok "hot pack at 20% -> holds" || no "hot pack at 20% does not hold ($_r)"

_r=$(calc 380 37 1 87 82)
holds "$_r" 1 && ok "hot pack at 1% -> holds, without going negative" || no "hot pack at 1% ($_r)"

# The case the old clamp DID cover must keep working.
_r=$(calc 380 37 85 87 82)
holds "$_r" 85 && ok "hot pack already above resume -> still holds" || no "regression above resume ($_r)"
_b=$(echo $_r | cut -d' ' -f2); _s=$(echo $_r | cut -d' ' -f1)
[ "$_b" -lt "$_s" ] \
  && ok "above resume: start ($_b) below stop ($_s), so it does not resume while still hot" \
  || no "above resume: start equals stop, it resumes on a 1% drop while hot"

# A cool pack must be left completely alone.
_r=$(calc 300 37 63 87 82)
[ "$_r" = "87 82" ] && ok "cool pack -> the user's own levels, untouched" \
                    || no "a cool pack was altered: $_r"
holds "$_r" 63 && no "a cool pack was put into a hold" || ok "cool pack at 63% keeps charging"

# Exactly at max_temp counts as reached.
_r=$(calc 370 37 63 87 82)
holds "$_r" 63 && ok "exactly at max_temp -> holds" || no "the max_temp boundary does not hold ($_r)"

# One tenth under must not.
_r=$(calc 369 37 63 87 82)
[ "$_r" = "87 82" ] && ok "one tenth under max_temp -> untouched" || no "fired below max_temp ($_r)"

# start must always stay under stop, or the firmware resumes the instant it pauses.
for lv in 63 20 5 1; do
  _r=$(calc 380 37 $lv 87 82)
  _s=$(echo $_r | cut -d' ' -f1); _b=$(echo $_r | cut -d' ' -f2)
  [ "$_b" -lt "$_s" ] || [ "$_s" -le 0 ] \
    && ok "at ${lv}%: start ($_b) is below stop ($_s)" \
    || no "at ${lv}%: start ($_b) is not below stop ($_s) - it would resume immediately"
done

fin
