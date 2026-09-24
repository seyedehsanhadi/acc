#!/system/bin/sh
# t147 - shutdown_temp as the user asked for it.
#
# FIELD REPORT: "47C and shutdown_temp 45 did not fire". There was no cutoff at 45. `acc -s
# shutdown_temp=45` against the default max_temp of 50 printed the success tick, stored 55, and
# said nothing - the setter rejected any shutdown_temp below max_temp and replaced it with a
# default. Device-proven on laurus and bluejay before the fix: asked 45, stored 55; asked 42,
# stored 55.
#
# The daemon never had that restriction: _temp_shutdown_check band-checks 40..70 and carries no
# max_temp term, so a hand-edited 45 has always worked and only the write path refused it. Both
# ends are graded here - what the setter stores, and what the cutoff does with it.
#
# SAFETY: the cutoff arms run a LIFTED copy of _temp_shutdown_check with shutdown() stubbed to a
# recorder. The setter arms are NOT inert: they put shutdown_temp 42 and 45 into the LIVE config, and
# the running daemon acts on it within a second. laurus 2026-09-23, under AnTuTu at 42.1C: the daemon
# powered the phone off mid-suite and the restore trap never ran. The setter arms therefore refuse
# to run unless the battery is at least 5C under the lowest value they write.

ID=t147
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed${S:+, $S skipped}"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
TMPDIR=${TMPDIR:-/dev/.vr25/acc}
CFG=${config:-/data/adb/vr25/acc-data/config.txt}
ACC=$TMPDIR/acc
# $TMPDIR/acc is not there on every root manager - on bluejay it is absent and the whole live half
# of this suite skipped itself, leaving the setter ungraded. Fall back to the installed command.
[ -x "$ACC" ] || ACC=$(command -v acc 2>/dev/null) || ACC=$TMPDIR/acc
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AWKF=${AWKF:-$SELF/../xf.awk}
[ -f "$AWKF" ] || AWKF=$execDir/suites/xf.awk
D=$execDir/accd.sh

echo "  -- phone: $(getprop ro.product.device)  uid=$(id -u)"

# ---- 0: the harness can fail -------------------------------------------------------------------
[ "1" = "2" ] && no "harness: 1 equals 2" || ok "harness: the assertions discriminate"

# ================================================================= the cutoff
# _temp_shutdown_check is lifted and driven with a stubbed sensor and a stubbed shutdown, so the
# matrix below grades the decision and nothing reaches the power manager.
if [ ! -f "$AWKF" ] || [ ! -f "$D" ]; then
  sk "cannot lift _temp_shutdown_check (missing $AWKF or $D)"
else
  _TSC=$(awk -v fn=_temp_shutdown_check -f "$AWKF" "$D" 2>/dev/null)
  if [ -z "$_TSC" ]; then
    no "could not lift _temp_shutdown_check from $D - no verdict on the cutoff"
  else
    # $1 = shutdown_temp, $2 = max_temp, $3 = raw deci-C reading -> FIRED | HELD
    tsc(){ ( eval "$_TSC"
             temperature[0]=35; temperature[1]=$2; temperature[2]=30; temperature[3]=$1
             # $3 INSIDE the stub is the stub's own argument, not tsc's. Read it out here or every
             # arm reads an empty sensor, which _temp_shutdown_check correctly refuses to act on -
             # so the whole matrix answers HELD and the suite grades its own wiring.
             _rd=$3; temperature_now(){ echo "$_rd"; }
             shutdown(){ echo FIRED; exit 0; }
             _temp_shutdown_check
             echo HELD ) 2>/dev/null; }

    # A cutoff BELOW max_temp is the reported setting, and it must act on its own number.
    [ "$(tsc 45 50 450)" = FIRED ] && ok "cutoff 45 under max_temp 50 fires at 45.0C" \
                                   || no "cutoff 45 under max_temp 50 did NOT fire at 45.0C - the field report"
    [ "$(tsc 45 50 470)" = FIRED ] && ok "cutoff 45 under max_temp 50 fires at 47.0C" \
                                   || no "cutoff 45 under max_temp 50 did NOT fire at 47.0C - the field report"
    [ "$(tsc 45 50 449)" = HELD ]  && ok "cutoff 45 holds at 44.9C" \
                                   || no "cutoff 45 fired below its own threshold at 44.9C"
    [ "$(tsc 55 50 540)" = HELD ]  && ok "cutoff 55 holds at 54.0C" \
                                   || no "cutoff 55 fired at 54.0C"
    # The band, and the reason it exists: a numeric 9 is a number and would fire at room temperature.
    [ "$(tsc 9 50 260)" = HELD ]   && ok "a numeric shutdown_temp of 9 does not fire at 26.0C" \
                                   || no "shutdown_temp 9 fired at 26.0C - the rc20 band check is gone"
    # No reading means no shutdown. An unreadable thermometer must never be read as an overheat.
    [ "$(tsc 45 50 '')" = HELD ]   && ok "an unreadable sensor holds instead of firing" \
                                   || no "an unreadable sensor FIRED the cutoff - the check fails open"
    # The source-level half: a max_temp term here would re-break what the setter fix allows.
    case "$_TSC" in
      *'temperature[1]'*) no "_temp_shutdown_check consults max_temp - a cutoff below it can never fire";;
      *) ok "_temp_shutdown_check has no max_temp term";;
    esac
  fi
fi

# ================================================================= the setter
if [ ! -x "$ACC" ] || [ ! -f "$CFG" ]; then
  sk "no live acc/config - setter arms need an installed ACC"
  fin; exit $?
fi
_lt=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
case "$_lt" in ''|*[!0-9]*) _lt=999;; esac
if [ "$_lt" -ge 370 ]; then
  sk "battery at $_lt deci-C: the setter arms would write shutdown_temp 42 into the live config and the daemon would power the phone off - rerun below 37.0C"
  fin; exit $?
fi
ORIG_T=$(grep -m1 '^temperature=' "$CFG")
ORIG_C=$(grep -m1 '^capacity=' "$CFG")
restore(){ [ -n "$ORIG_T" ] && sed -i "s|^temperature=.*|$ORIG_T|" "$CFG" 2>/dev/null || :
           [ -n "$ORIG_C" ] && sed -i "s|^capacity=.*|$ORIG_C|" "$CFG" 2>/dev/null || :
           $ACC -D restart >/dev/null 2>&1 || :; }
trap 'restore' EXIT INT TERM

band(){ grep -m1 '^temperature=' "$CFG" | sed 's/temperature=//'; }
stored(){ _b=$(band); _b=${_b%)}; echo "${_b##* }"; }
base(){ $ACC -s cooldown_temp=45 max_temp=50 resume_temp=40 shutdown_temp=55 >/dev/null 2>&1 || :; }
set_t(){ want=$1; shift; base; out=$($ACC -s "$@" 2>&1); got=$(stored)
  [ "$got" = "$want" ] && ok "acc -s $* stored shutdown_temp $got" \
                       || no "acc -s $* stored shutdown_temp $got, asked for $want (band $(band))"
  _said=$out; }

set_t 45 shutdown_temp=45
set_t 42 shutdown_temp=42
# Out of band is still refused - and now it SAYS so. The silence is what made the report unanswerable.
set_t 55 shutdown_temp=38
case "$_said" in *"shutdown_temp was stored as 55, not 38"*) ok "a refused shutdown_temp is reported";;
  *) no "shutdown_temp 38 was replaced silently - the original defect, moved";; esac
set_t 55 shutdown_temp=75
# rc6 stays: raising max_temp drags a DEFAULTED cutoff up with it, or the phone powers off before
# it ever pauses.
set_t 62 max_temp=57

# It has to SURVIVE. The daemon re-persists this config with neither name set, and validating it
# the old way on every write bent a stored value straight back to the default.
base; $ACC -s shutdown_temp=45 >/dev/null 2>&1 || :
$ACC -s pause_capacity=75 >/dev/null 2>&1 || :
[ "$(stored)" = 45 ] && ok "a write naming neither temperature keeps shutdown_temp 45" \
                     || no "an unrelated write bent shutdown_temp to $(stored)"
$ACC -D restart >/dev/null 2>&1 || :
sleep 12
[ "$(stored)" = 45 ] && ok "shutdown_temp 45 survives a daemon re-persist" \
                     || no "the daemon re-persist bent shutdown_temp to $(stored)"

restore
fin
