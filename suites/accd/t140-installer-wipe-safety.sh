#!/system/bin/sh
# Installer regression gate for the VoltageOS "UI broke / OS wiped" report.

ID=t140
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
S=0
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed${S:+, $S skipped}"; [ "$F" -eq 0 ]; }

# This gate reads the three INSTALLER entry points, which live only in the source tree - the
# installed module carries the flattened install/ scripts and none of install.sh, customize.sh or
# META-INF. Run from a phone it could only ever report "missing ./install.sh", which reads as a
# product failure and is not one. Find the repo if it is reachable; otherwise skip and say so.
ROOT=${ROOT:-${1:-}}
if [ -z "${ROOT:-}" ]; then
  for _r in . .. ../.. ../../.. "${execDir:-}/.."; do
    [ -n "$_r" ] && [ -f "$_r/install.sh" ] && [ -f "$_r/customize.sh" ] && { ROOT=$_r; break; }
  done
  unset _r
fi
I=${ROOT:-.}/install.sh
C=${ROOT:-.}/customize.sh
U=${ROOT:-.}/META-INF/com/google/android/update-binary
for _f in "$I" "$C" "$U"; do
  [ -f "$_f" ] || { sk "the installer entry points are not reachable from here ($_f) - this gate reads the source tree, which an installed module does not contain"; fin; exit $?; }
done

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
