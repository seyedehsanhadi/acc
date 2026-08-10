#!/system/bin/sh
# t55 - the battery-interface cache: the only thing that writes it, and the only thing that heals it.
#
#   _cache_write      builds the published cache file
#   _cache_usable     decides whether what is on disk can be trusted
#   _cache_republish  puts the daemon's in-memory truth back on disk without re-probing
#
# WHY THIS SUITE EXISTS
#   These three arrived after rc21 and had no unit coverage at all. T-DAEMON exercises them on
#   hardware - truncate the cache, watch the daemon heal it - but that is one path through them on
#   one phone, and it cannot reach the cases that matter most:
#
#     - The cache is what EVERYTHING ELSE on the phone reads. The daemon itself sources it once at
#       init and then works from its own variables, so losing the file costs the daemon nothing and
#       it never notices. Measured on both test phones: truncate it with the daemon running and it
#       stayed empty indefinitely. Every other reader was blind for as long as that lasted.
#     - _DPOL is the learned charge-direction polarity. A republish that drops it throws away that
#       learning, and a wrong direction verdict is the single failure that blinds all four limits
#       at once - capacity, temperature, current and voltage all only evaluate while ACC believes
#       it is charging.
#     - accd runs under `set -eu`, where an assignment takes the exit status of its command
#       substitution. A bare `cat` of a missing .dpol file therefore ABORTS THE DAEMON AT INIT.
#       That one was caught in a sandbox before it reached a phone; the `|| :` that prevents it
#       looks removable to anyone tidying up, so it is asserted here.
#
# NO HARDWARE. Everything below runs against a temporary directory.

ID=t55
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
chk(){ [ "$3" = "$2" ] && ok "$1" || no "$1  (expected '$2', got '$3')"; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=$execDir/batt-interface.sh
[ -f "$BI" ] || { no "batt-interface.sh not found at $BI"; fin; }

W=${TMPDIR:-/data/local/tmp}/.t55
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

# No \| alternation: it is a GNU sed extension and neither test phone has it (BSD sed on the
# A3, toybox on the Pixel), so the range matched nothing and every assertion below failed at
# once. `/^name()/` matches both `name(){` and `name() {` without needing alternation.
# Comments are stripped. Every content check below looks for CODE, and the comments in these
# functions describe the very things being checked for - _cache_republish's comment contains
# the word "probing" while the function does no probing at all, which failed the assertion
# against correct code. Third time a suite has read a defect's own obituary and reported it
# as the defect; strip once, here, rather than per assertion.
body(){ sed -n "/^$1()/,/^}/p" "$BI" | sed "s/#.*//"; }

# ---- source-level guarantees ---------------------------------------------------------------------
_w=$(body _cache_write)
[ -n "$_w" ] || { no "could not extract _cache_write"; fin; }

# Temp file then rename. A reader must never see a half-built cache, and two writers must not
# interleave; rename is the only atomic option available to a shell script here.
printf '%s' "$_w" | grep -q 'mv -f' \
  && ok "writes to a temp file and renames - a reader never sees it half-built" \
  || no "_cache_write writes the cache in place; a reader can catch it mid-write"

printf '%s' "$_w" | grep -q 'rm -f' \
  && ok "cleans up its temp file when the write fails" \
  || no "a failed write leaves its temp file behind"

# The set -eu trap described in the header.
printf '%s' "$_w" | grep -q 'cat $TMPDIR/.dpol 2>/dev/null || :' \
  && ok "the .dpol read cannot abort the daemon under set -eu (the || : is load-bearing)" \
  || no "the .dpol read has no || : guard - a missing file aborts accd at init"

printf '%s' "$_w" | grep -q '_DPOL' \
  && ok "carries the learned polarity across a republish" \
  || no "_cache_write drops _DPOL - the next reader re-derives the charge direction"

# Every key a reader needs. _cache_usable checks two of these; the rest are what the daemon and
# acc -i actually consume.
for k in battCapacity currFile battStatus temp voltNow idleThreshold ampFactor_; do
  printf '%s' "$_w" | grep -q "$k=" \
    && ok "publishes $k" \
    || no "$k is missing from the published cache"
done

_r=$(body _cache_republish)
[ -n "$_r" ] || { no "could not extract _cache_republish"; fin; }

printf '%s' "$_r" | grep -q '_cache_usable && return 0' \
  && ok "republish is a no-op when the cache is already good" \
  || no "republish rewrites a healthy cache on every call"

printf '%s' "$_r" | grep -qE '\[ -n "\$\{batt-\}" \]' \
  && ok "refuses to publish when the daemon has nothing to publish" \
  || no "republish can write a cache with no battery path in it"

# It must NOT re-probe. Re-probing from a running daemon would re-enter discovery on a loop that
# is only trying to rewrite a file, which is how a cache heal turns into a switch scan.
printf '%s' "$_r" | grep -qE 'probe|scan|ctrl-files' \
  && no "republish re-probes; it should only write down what is already known" \
  || ok "republish does not re-probe - it only writes down what the daemon already holds"

# ---- live behaviour, against a real temp dir -------------------------------------------------------
TMPDIR=$W
ampFactor_=1000000
batt=battery
battStatus=battery/status
currFile=battery/current_now
curThen=$W/.mcc
idleThreshold=10
temp=battery/temp
voltNow=battery/voltage_now

eval "$(body _cache_write)"  2>/dev/null || :
eval "$(body _cache_usable)" 2>/dev/null || :
eval "$(body _cache_republish)" 2>/dev/null || :

if ! command -v _cache_write >/dev/null 2>&1; then
  no "could not evaluate the cache functions in this shell"
  fin
fi

# An absent cache is not usable.
rm -f $W/.batt-interface.sh
if _cache_usable; then no "an absent cache reported usable"; else ok "an absent cache is not usable"; fi

# An empty one is not either - this is the exact state the field report produced.
: > $W/.batt-interface.sh
if _cache_usable; then no "an EMPTY cache reported usable - the reported failure state"; else ok "an empty cache is not usable"; fi

# A truncated one, holding some keys but not the ones that matter.
printf 'ampFactor_=1000000\n' > $W/.batt-interface.sh
if _cache_usable; then no "a cache missing battCapacity/currFile reported usable"; else ok "a partial cache is not usable"; fi

# Now write one properly.
rm -f $W/.batt-interface.sh
_DPOL=-
_cache_write
if [ -s $W/.batt-interface.sh ]; then ok "_cache_write produced a non-empty cache"; else no "_cache_write wrote nothing"; fi
if _cache_usable; then ok "and the result reads back as usable"; else no "the freshly written cache is not usable"; fi

chk "battCapacity is the composed path" "battery/capacity" "$(sed -n 's/^battCapacity=//p' $W/.batt-interface.sh)"
chk "currFile round-trips"              "battery/current_now" "$(sed -n 's/^currFile=//p' $W/.batt-interface.sh)"
chk "the learned polarity is carried"   "-" "$(sed -n 's/^_DPOL=//p' $W/.batt-interface.sh)"

# No temp file may survive a successful write.
_leftover=$(ls $W/.batt-interface.sh.* 2>/dev/null | wc -l)
chk "no temp file left behind" "0" "$(printf '%s' "${_leftover:-0}" | tr -d ' ')"

# The file must be sourceable: it is eval'd by every reader, so a quoting error here breaks them all.
if ( set -eu; . $W/.batt-interface.sh ) 2>/dev/null; then
  ok "the published cache can be sourced under set -eu"
else
  no "the published cache does not source cleanly - every reader would break"
fi

# _DPOL from the file rather than the variable: the daemon's main shell does not always hold it.
rm -f $W/.batt-interface.sh
unset _DPOL
printf '+' > $W/.dpol
_cache_write
chk "polarity is recovered from .dpol when the variable is unset" "+" "$(sed -n 's/^_DPOL=//p' $W/.batt-interface.sh)"

# Neither present: the cache is still written, just without a polarity line, and nothing aborts.
rm -f $W/.batt-interface.sh $W/.dpol
unset _DPOL
if ( set -eu; _cache_write ) 2>/dev/null; then
  ok "a missing .dpol with _DPOL unset does not abort under set -eu"
else
  no "_cache_write aborts under set -eu with no .dpol - this kills accd at init"
fi
[ -s $W/.batt-interface.sh ] && ok "and the cache is still written without a polarity line" \
                             || no "no cache written when the polarity is unknown"

# republish: no-op when healthy, rebuild when empty, refusal when there is nothing to say.
_before=$(cat $W/.batt-interface.sh 2>/dev/null)
_cache_republish >/dev/null 2>&1
chk "republish left a healthy cache untouched" "$_before" "$(cat $W/.batt-interface.sh 2>/dev/null)"

: > $W/.batt-interface.sh
if _cache_republish >/dev/null 2>&1 && _cache_usable; then
  ok "republish rebuilt an emptied cache"
else
  no "republish did not rebuild an emptied cache - the reported failure state persists"
fi

: > $W/.batt-interface.sh
_savedbatt=$batt; batt=
if _cache_republish >/dev/null 2>&1; then
  no "republish wrote a cache with no battery path"
else
  ok "republish refuses when the daemon holds nothing to publish"
fi
batt=$_savedbatt

rm -rf "$W" 2>/dev/null
fin
