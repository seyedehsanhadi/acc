#!/system/bin/sh
# t146 - a fallback config must never become the new truth on disk.
#
# WHAT WENT WRONG
#   .config-good exists so the daemon keeps enforcing something when $config will not parse.
#   Two faults turned that safety net into silent data loss.
#
#   1. POISONING. The cache branch excluded $TMPDIR (the daemon temporaries and `acc -f`) but
#      accepted ANY other persistent path, including one carrying the shipped defaults. The
#      snapshot meant to protect the user's config could therefore be taken FROM the defaults.
#
#   2. THE FALLBACK WAS PERSISTED. Once _srcgood loaded .config-good into memory, the next
#      config persist wrote those values back over the real file. A TRANSIENT parse failure
#      became PERMANENT loss of the user's settings.
#
#   Device-proven on a Pixel 6a: .config-good held capacity=(5 101 70 75 false) - the module
#   default - while the user had set 80. After one reboot the live config read 75, the hardware
#   pair followed to stop=75, and nothing was logged. The user's charge limit had been silently
#   replaced by a value they never chose.

ID=t146
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
WC=$execDir/write-config.sh
for f in "$AD" "$MF" "$WC"; do [ -f "$f" ] || { no "missing $f"; fin; }; done

_wc=$(sed 's/^[[:space:]]*#.*//' "$WC")
case "$_wc" in
  *'_cfgFallback'*) ok "write-config knows about the fallback state" ;;
  *) no "write-config persists unconditionally - a fallback overwrites the user's config" ;;
esac
_head=$(head -30 "$WC" | sed 's/^[[:space:]]*#.*//' | tr '\n' ' ')
case "$_head" in
  *'_cfgFallback'*'exit'*) ok "it bails out early, before emitting anything" ;;
  *) no "the fallback guard is not an early exit" ;;
esac

_ad=$(sed 's/^[[:space:]]*#.*//' "$AD")
_sg=$(printf '%s' "$_ad" | grep -A14 '_srcgood() {' | tr '\n' ' ')
case "$_sg" in
  *'_cfgFallback=1'*) ok "_srcgood marks that the daemon is running on the fallback" ;;
  *) no "_srcgood does not mark the fallback state" ;;
esac
_sc=$(printf '%s' "$_ad" | grep -A14 'if cfg_parses \$config; then' | tr '\n' ' ')
case "$_sc" in
  *'_cfgFallback=0'*) ok "a successful real-config load clears the flag again" ;;
  *) no "the flag is never cleared - persisting would stay disabled forever" ;;
esac
_cache=$(printf '%s' "$_ad" | grep -B2 -A6 'config-good 2>/dev/null || :' | tr '\n' ' ')
case "$_cache" in
  *'"$dataDir"/config.txt'*) ok "only the canonical config may become the snapshot" ;;
  *) no "any persistent config path can still poison .config-good" ;;
esac

[ "$(id -u 2>/dev/null)" = 0 ] || { sk "not root"; fin; }

W=/data/local/tmp/.t146
rm -rf $W 2>/dev/null; mkdir -p $W/tmpfs $W/data
_oT=${TMPDIR:-}; _oD=${dataDir:-}; _oC=${config:-}
TMPDIR=$W/tmpfs; dataDir=$W/data; config=$dataDir/config.txt
export TMPDIR dataDir config
trap 'TMPDIR=$_oT; dataDir=$_oD; config=$_oC; rm -rf $W 2>/dev/null' EXIT HUP INT TERM

{
  sed -n '/^  cfg_parses() {/,/^  }/p' "$MF"
  sed -n '/^  _srcsafe() {/,/^  }/p' "$AD"
  sed -n '/^  _srcgood() {/,/^  }/p' "$AD"
  sed -n '/^  _srccfg() {/,/^  }/p' "$AD"
} > $W/fns.sh
[ "$(grep -c '() {' $W/fns.sh)" -ge 4 ] || { sk "could not extract the config loaders"; fin; }
. $W/fns.sh

USER='capacity=(5 101 70 80 false)'
DEF='capacity=(5 101 70 75 false)'

printf '%s\n' "$USER" > $config
rm -f $dataDir/.config-good; unset _cfggood
capacity=(); _cfgFallback=0; _srccfg
[ "${capacity[3]:-}" = 80 ] \
  && ok "live: the user's 80 loads from a healthy config" || no "live: loaded ${capacity[*]}"
[ "$(sed -n 's/^capacity=//p' $dataDir/.config-good 2>/dev/null)" = "$(printf '%s' "${USER#capacity=}")" ] \
  && ok "live: the healthy config is cached as the snapshot" \
  || no "live: snapshot holds $(sed -n 's/^capacity=//p' $dataDir/.config-good 2>/dev/null)"

printf '%s\n' "$DEF" > $W/other.txt
( config=$W/other.txt; unset _cfggood; capacity=(); _cfgFallback=0; _srccfg ) >/dev/null 2>&1
_g=$(sed -n 's/^capacity=//p' $dataDir/.config-good 2>/dev/null)
[ "$_g" = "(5 101 70 80 false)" ] \
  && ok "live: a defaults-bearing config at another path did NOT poison the snapshot" \
  || no "live: snapshot poisoned to $_g by a non-canonical config"

printf '%s\n' "$DEF" > $dataDir/.config-good
printf 'capacity=(5 101 70 80 false\n' > $config
unset _cfggood; capacity=(); _cfgFallback=0
_srccfg
[ "${capacity[3]:-}" = 75 ] \
  && ok "live: the fallback still loads, so enforcement continues" \
  || no "live: fallback did not load (${capacity[*]})"
[ "${_cfgFallback:-0}" = 1 ] \
  && ok "live: the daemon knows it is on the fallback" \
  || no "live: the fallback flag was not set"

_before=$(cat $config)
( . "$WC" ) >/dev/null 2>&1 || :
if [ "$(cat $config)" = "$_before" ]; then
  ok "live: a persist while on the fallback wrote NOTHING - the user's file is untouched"
else
  no "live: the fallback was written over the config: $(sed -n 's/^capacity=//p' $config)"
fi

trap - EXIT HUP INT TERM
TMPDIR=$_oT; dataDir=$_oD; config=$_oC
rm -rf $W 2>/dev/null
fin
