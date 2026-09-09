#!/system/bin/sh
# Fairphone 5, bundle acc-diag-FP5-20260909-174239: plugged at 9V, status=Charging, the pack at
# -305180 uA and the level walking 54 -> 53%. state.json published
#
#     "sensing":{"polarity":"unstable","polaritySource":"unstable","ccDir":"flat"}
#     "switch":{"measuredClass":"charging"}
#     "charge":{"watts":1.144,"class":"slow","approx":true}
#
# The pack was emptying with the cable in and ACC said "slow charge". That is the flapping the
# owner reported: whenever the kernel status word blinked to Discharging the same daemon said
# "draining", and it blinked back a few seconds later.
#
# Replaying his own flight.log through _se_polarity shows the sign on this phone is HONEST -
# positive while the level climbs, negative while it falls, 1506 samples, no contradiction - and
# the replay ends at confirmed=normal. The "unstable" his phone carries was latched by an older
# window and it can never leave, because:
#
#   1. the plugged physics test compares the level against an anchor up to 3600s old while taking
#      the current sign from THIS sample. A phone that drains and is then put back on the charger
#      inside that hour is measured as "level fell" against a sample whose sign says "charging",
#      so it reports inverted on a phone that is not. Two of those latch unstable for good.
#   2. once confirmed=unstable the whole learning block is skipped, so nothing can ever revise it.
#   3. the cache-version reset clears confirmed/cand/n/ac/ats but leaves fl, so a phone that has
#      already banked two flips re-latches unstable on the first flip after an upgrade.
#
# unstable disables the sign, which is the only arbiter that works here: the coulomb counter is
# coarse (ccDir flat) and the status word lies. _se_class is then left with the liar.
#
# Cases 1-3 pin the anchor. 4-5 pin the self-heal and that a genuine dual-path phone (curtana,
# whose sign really does follow the engaged charge path) is NOT healed by it. 6 pins the fl reset.
# 7 replays the field log end to end.

ID=t-polarity-unstable-latch
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

# The suites run from three shapes of tree: the repo (install/ beside suites/), a flat working
# copy where every shipped file sits next to suites/, and the installed module. Take the first
# that exists, so a sweep never silently grades a DIFFERENT build than the one under test.
if [ -z "${SRC:-}" ]; then
  for c in "$(dirname "$0")/../../install/state-export.sh"            "$(dirname "$0")/../../state-export.sh"            "${execDir:-/data/local/tmp/wt}/state-export.sh"            /data/adb/vr25/acc/state-export.sh; do
    [ -f "$c" ] && { SRC=$c; break; }
  done
fi
[ -f "${SRC:-}" ] || { no "no state-export.sh"; fin; }
echo "  ..   grading $SRC"

W=${W:-/data/local/tmp/t-pol-latch}
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null
sed -n '/^_se_polarity() {/,/^}/p' "$SRC" > $W/pol.sh
[ -s $W/pol.sh ] || { no "could not cut _se_polarity out of $SRC"; fin; }
. $W/pol.sh
command -v _se_polarity >/dev/null || { no "_se_polarity did not load"; fin; }

SE_POLCACHE=$W/cache
reset(){ rm -f "$SE_POLCACHE"; }
cache(){ cat "$SE_POLCACHE" 2>/dev/null; }
field(){ f=$1; for kv in $(cache); do case "$kv" in $f=*) echo "${kv#*=}"; return;; esac; done; }
eq(){ [ ".$2" = ".$3" ] && ok "$1" || no "$1  (expected '$3', got '$2')"; }

T=1788968553

# The cache carries a schema version and a stale one is discarded wholesale. Ask the code itself
# what version it writes, so a seeded cache below is READ rather than thrown away.
reset; _se_polarity Discharging -500000 false uA 60 $T >/dev/null
SV=$(field sv)
[ -n "$SV" ] || { no "the cache carries no sv= field"; fin; }
seed(){ echo "sv=$SV confirmed=$1 cand= n=0 ac= ats= fl=$2" > "$SE_POLCACHE"; }

echo "--- 1. a drain then a charge inside the anchor window is not a polarity verdict"
reset
# plugged, level 88, draining at -456244 (his 11:57 sample): stamps the anchor
_se_polarity Discharging -456244 true uA 88 $((T-3000)) >/dev/null
# 50 minutes later, plugged, level 86, now genuinely charging at +2780494 (his 12:06 sample).
# The level is 2 lower than the anchor, but that fall happened while the sign was negative.
r=$(_se_polarity Charging 2780494 true uA 86 $((T-100)))
# No physics verdict is available, so the answer falls through to the bootstrap status cross-
# check, which reads Charging + positive current as normal. What must never happen is "inverted".
[ ".$r" = .inverted ] && no "it read the phone as inverted" || ok "it did not read the phone as inverted"
[ "$(field cand)" = inverted ] && no "it banked 'inverted' as a candidate" || ok "nothing was banked"

echo "--- 2. a constant-sign drain while plugged still resolves normal"
reset
_se_polarity Charging -400000 true uA 88 $((T-900)) >/dev/null
r=$(_se_polarity Charging -305180 true uA 86 $((T-100)))
eq "level fell 2 with the sign negative throughout -> normal" "$r" normal

echo "--- 3. a constant-sign fill while plugged still resolves normal"
reset
_se_polarity Charging 2316621 true uA 79 $((T-900)) >/dev/null
r=$(_se_polarity Charging 2079191 true uA 81 $((T-100)))
eq "level rose 2 with the sign positive throughout -> normal" "$r" normal

echo "--- 4. a latched 'unstable' heals when the physics agrees five times running"
reset
seed unstable 2
i=0
while [ $i -lt 6 ]; do
  _se_polarity Discharging -500000 false uA 60 $((T - 600 + i * 60)) >/dev/null
  i=$((i + 1))
done
eq "five agreeing unplugged samples clear the latch" "$(field confirmed)" normal

echo "--- 5. a genuine dual-path phone is not healed"
reset
seed unstable 2
i=0
while [ $i -lt 12 ]; do
  case $((i % 2)) in
    0) _se_polarity Discharging -500000 false uA 60 $((T - 1200 + i * 60)) >/dev/null;;
    1) _se_polarity Discharging  500000 false uA 60 $((T - 1200 + i * 60)) >/dev/null;;
  esac
  i=$((i + 1))
done
eq "an alternating sign keeps the latch" "$(field confirmed)" unstable

echo "--- 6. the cache-version reset clears the flip counter too"
reset
echo "sv=1 confirmed=normal cand= n=0 ac= ats= fl=2" > "$SE_POLCACHE"
_se_polarity Discharging -500000 false uA 60 $T >/dev/null
eq "fl does not survive a version bump" "$(field fl)" 0

echo "--- 7. his own flight.log ends at normal, not unstable"
LOG=${LOG:-/data/local/tmp/t-pol-fixture/flight.log}
if [ -f "$LOG" ]; then
  reset
  # a fresh phone: no cache at all
  while IFS=, read -r ts cap cur st on pres rest; do
    case "$cur" in ''|*[!0-9-]*) continue;; esac
    case "$cap" in ''|*[!0-9]*) continue;; esac
    [ "$pres" = 1 ] && pl=true || pl=false
    _se_polarity "$st" "$cur" "$pl" uA "$cap" "$ts" >/dev/null
  done < "$LOG"
  eq "1506 field samples resolve to normal" "$(field confirmed)" normal
  [ "$(field fl)" = 0 ] && ok "no false flip was banked over the whole log" \
    || no "banked $(field fl) false flips over the whole log"
else
  ok "no flight.log fixture present, section skipped"
  ok "no flight.log fixture present, section skipped"
fi

echo "--- 8. end to end on his published sample: the pack is emptying, so nothing is charging it"
# state.json, 2026-09-09 17:42:33, Fairphone 5 on a 9V DCP contract:
#   current_raw -305180 uA, voltage_raw 3754, level 53 and falling, status "Charging",
#   input voltageMv 8998 with currentMa null (usb/current_now is a mirrored register there and
#   the ICL guard drops it, so there is no input reading to compute watts from).
# It published measuredClass "charging" and charge {"watts":1.144,"class":"slow","approx":true}.
for fn in _se_int _se_ma _se_voltage_mv _se_watts _se_class _se_charge; do
  sed -n "/^$fn() {/,/^}/p" "$SRC" >> $W/cls.sh
done
. $W/cls.sh
if command -v _se_class >/dev/null && command -v _se_charge >/dev/null; then
  reset
  # his phone as it actually is: carrying the dead "unstable" latch and its two banked flips
  seed unstable 2
  # six plugged samples, cable in, the level walking down 2 points at a time with the sign
  # negative throughout - what his flight.log shows between 17:15 and 17:42
  i=0
  while [ $i -lt 6 ]; do
    _se_polarity Charging -305180 true uA $((63 - i * 2)) $((T - 1800 + i * 300)) >/dev/null
    i=$((i + 1))
  done
  pol=$(_se_polarity Charging -305180 true uA 53 $T)
  eq "the sign is trusted again" "$pol" normal
  mc=$(_se_class -305180 true uA "$pol" flat Charging)
  eq "a negative pack on a normal-polarity phone, plugged, is a drain" "$mc" drain
  ch=$(_se_charge 8998 null -305180 3754 Charging 270 53 "$mc")
  case "$ch" in
    *'"watts":null'*) ok "no wattage is published for a pack that is emptying";;
    *) no "it still published a wattage: $ch";;
  esac
  case "$ch" in
    *'"class":null'*) ok "no charge class is published either";;
    *) no "it still published a charge class: $ch";;
  esac
  # and the other direction still works: the same phone actually filling
  ch2=$(_se_charge 8998 2000 2316621 3754 Charging 270 79 charging)
  case "$ch2" in
    *'"watts":null'*) no "a genuinely charging phone lost its wattage: $ch2";;
    *) ok "a genuinely charging phone still reports its wattage";;
  esac
else
  no "could not cut _se_class/_se_charge out of $SRC"
fi

fin
