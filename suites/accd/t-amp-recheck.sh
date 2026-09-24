#!/system/bin/sh
# amp_recheck must self-heal auto-detected current units without overriding an explicit user choice.

P=0; F=0
ok(){ P=$((P+1)); echo "PASS $*"; }
no(){ F=$((F+1)); echo "FAIL $*"; }
fin(){ echo "t-amp-recheck: $P passed, $F failed"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
fn=$(sed -n '/^  amp_recheck() {/,/^  }/p' "$execDir/accd.sh")
[ -n "$fn" ] || { no "amp_recheck is missing"; fin; exit $?; }
eval "$fn"

T=/data/local/tmp/t-amp-recheck.$$
mkdir -p "$T" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

seq_set(){ printf '%s\n' "$@" > "$T/seq"; : > "$T/warn"; : > "$T/cache"; }
current_factor(){
  sed -n '1p' "$T/seq"
  sed '1d' "$T/seq" > "$T/next" && mv -f "$T/next" "$T/seq"
}
warn_once_per(){ printf '%s\n' "$*" >> "$T/warn"; }
_cache_write(){ echo write >> "$T/cache"; }

seq_set 1000000 1000000 1000000
ampFactor=1000; ampFactor_=1000
amp_recheck
[ "$ampFactor" = 1000 ] && [ "$ampFactor_" = 1000 ] && [ -s "$T/warn" ] && [ ! -s "$T/cache" ] \
  && ok "stable contradiction warns but preserves explicit ampFactor" \
  || no "explicit ampFactor was changed, silently contradicted, or persisted"

seq_set 1000000 1000
ampFactor=1000; ampFactor_=1000
amp_recheck
[ ! -s "$T/warn" ] && [ "$ampFactor_" = 1000 ] \
  && ok "transient explicit contradiction is ignored" \
  || no "transient explicit contradiction warned or changed state"

seq_set 1000000 1000000 1000000
ampFactor=; ampFactor_=1000
amp_recheck
[ "$ampFactor_" = 1000000 ] && [ "$(wc -l < "$T/cache")" -eq 1 ] \
  && ok "stable auto-detected change is latched and persisted once" \
  || no "stable auto-detected change was not persisted exactly once"

seq_set 1000000 1000
ampFactor=; ampFactor_=1000
amp_recheck
[ "$ampFactor_" = 1000 ] && [ ! -s "$T/cache" ] \
  && ok "transient auto-detected change is ignored" \
  || no "transient auto-detected change was latched"

seq_set 1000
ampFactor=; ampFactor_=1000
amp_recheck
[ "$ampFactor_" = 1000 ] && [ ! -s "$T/cache" ] \
  && ok "matching auto factor performs no write" \
  || no "matching auto factor caused churn"

seq_set ''
ampFactor=1000; ampFactor_=1000
amp_recheck
[ ! -s "$T/warn" ] && [ ! -s "$T/cache" ] \
  && ok "missing sensor evidence changes nothing" \
  || no "missing sensor evidence changed state"

fin
