#!/system/bin/sh
# Installer regression gate for the VoltageOS "UI broke / OS wiped" report.

ID=t140
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

ROOT=${ROOT:-${1:-.}}
I=$ROOT/install.sh
C=$ROOT/customize.sh
U=$ROOT/META-INF/com/google/android/update-binary
for _f in "$I" "$C" "$U"; do [ -f "$_f" ] || { no "missing $_f"; fin; exit $?; }; done

_h1=$(sha256sum "$I" | awk '{print $1}')
_h2=$(sha256sum "$C" | awk '{print $1}')
_h3=$(sha256sum "$U" | awk '{print $1}')
[ -n "$_h1" ] && [ "$_h1" = "$_h2" ] && [ "$_h1" = "$_h3" ] \
  && ok "all three installer entry points carry identical safety logic" \
  || no "installer copies differ; one entry point can ship stale safety logic"

for _f in "$I" "$C" "$U"; do
  _n=$(basename "$_f")
  grep -Eq 'rm -rf[[:space:]]+"?/(system|data)"?([[:space:];]|$)' "$_f" \
    && no "$_n contains a broad /system or /data recursive delete" \
    || ok "$_n has no broad /system or /data recursive delete"
  grep -Eq '(^|[[:space:]])(wipe|wipe_data|--wipe_data|factory_reset)([[:space:]]|$)' "$_f" \
    && no "$_n can request a factory/data wipe" \
    || ok "$_n contains no factory/data wipe command"
done

_mod=$(grep 'rm -rf.*MODPATH.*/system' "$I")
case "$_mod" in
  *'[ -n "${MODPATH:-}" ]'*) ok "MODPATH system-overlay removal refuses an empty path" ;;
  *) no "an empty MODPATH can collapse system-overlay removal to /system" ;;
esac

_rescue=$(sed -n '/for d in \$installDir \${MODPATH:-}/,/^  done/p' "$I")
case "$_rescue" in
  *'[ -n "$d" ]'*'[ -d "$d" ]'*) ok "overlay rescue only removes system/ below a real non-empty directory" ;;
  *) no "overlay rescue accepts an empty or non-directory base" ;;
esac

_first_true=$(grep -n '^overlayMount=true' "$I" | head -1 | cut -d: -f1)
_first_false=$(grep -n '^  overlayMount=false' "$I" | head -1 | cut -d: -f1)
case "${_first_true:-x}:${_first_false:-x}" in
  *[!0-9:]*|x:*|*:x) no "overlay fail-safe initialisation is missing" ;;
  *) [ "$_first_true" -lt "$_first_false" ] \
       && ok "unknown root managers default to overlay-safe mode" \
       || no "unsafe magic-mount mode is selected before the fail-safe default" ;;
esac

fin
