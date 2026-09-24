#!/system/bin/sh
# t158 - the 600 s unplugged nap must not delay the thermal cutoff.
#
# rc25 raised idleDelay from 120 to 600 s to save battery. shutdown_temp is only checked once per
# loop, so an unplugged phone heating up while awake could run 10 minutes past its cutoff where
# rc24 ran at most 2. The nap now reads the temperature on its present() cadence (builtin read, no
# fork) and ends early at shutdown_temp so the loop can act.
ID=t158
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; exit $?; }

execDir=${execDir:-/data/adb/vr25/acc}
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AD=${AD:-$execDir/accd.sh}
SE=${SE:-$execDir/state-export.sh}
AWKF=${AWKF:-$SELF/../xf.awk}
[ -f "$AWKF" ] || AWKF=$execDir/suites/xf.awk
for f in "$AD" "$SE" "$AWKF"; do [ -f "$f" ] || { no "missing $f"; fin; }; done
W=${TMPDIR:-/data/local/tmp}/t158-$$; rm -rf "$W"; mkdir -p "$W"
NAP=$(awk -v fn=_nap_idle -f "$AWKF" "$AD")
[ -n "$NAP" ] || { no "harness: _nap_idle not lifted"; fin; }

# Runs the nap for up to 40 ticks; prints how many ticks it consumed.
run(){ # $1 = raw temp, $2 = nap source
  ( xf(){ awk -v fn="$1" -f "$AWKF" "$2"; }
    eval "$(xf _se_rd "$SE")"; eval "$(xf _se_int "$SE")"; eval "$(xf _se_temp_decic "$SE")"
    eval "$2"
    TMPDIR=$W; temp=$W/temp; tempFactor=; temperature=(40 45 38 50); presentEvery=5
    echo "$1" > $temp
    n=0; present(){ return 1; }; _tick(){ n=$((n+1)); [ $n -lt 40 ]; }
    _nap_idle 600 2>/dev/null
    echo $n ) 2>/dev/null
}
cool=$(run 350 "$NAP"); hot=$(run 520 "$NAP")
[ "$cool" -ge 39 ] 2>/dev/null && ok "35.0C: nap runs its course ($cool ticks)" || no "35.0C: nap ended early ($cool ticks)"
[ "$hot" -le 5 ] 2>/dev/null && ok "52.0C with shutdown_temp 50: nap ends within one poll ($hot ticks)" || no "52.0C: nap ignored the cutoff ($hot ticks)"
unk=$(run garbage "$NAP")
[ "$unk" -ge 39 ] 2>/dev/null && ok "unreadable temperature never wakes the nap ($unk ticks)" || no "unreadable temp woke the nap ($unk ticks)"

MUT=$(printf '%s
' "$NAP" | grep -v -e _setemp -e _se_temp_decic)
mh=$(run 520 "$MUT")
[ "$mh" -ge 39 ] 2>/dev/null && ok "mutant without the check sleeps through 52C ($mh ticks) - assertion can fail" || no "mutant not caught ($mh)"
rm -rf "$W"
fin
