#!/system/bin/sh
# t77 - busybox must reach PATH no matter what the caller already put there.
#
# THE DEFECT, and why it was invisible for six releases.
#
# setup-busybox.sh installs the applets into $busybox_dir (/dev/.vr25/busybox) and then guarded
# against prepending twice with:
#
#     case $PATH in
#       $bin_dir:*) ;;                                    # /data/adb/vr25/bin
#       *) export PATH="$bin_dir:$busybox_dir:$PATH";;
#     esac
#
# It tested $bin_dir and added $busybox_dir. $bin_dir is only where a user MAY drop a static
# busybox; it is EMPTY on a normal install. So any caller that had already prepended $bin_dir made
# the whole block a no-op, and $busybox_dir was never put on PATH at all.
#
# acc-switch-scan.sh does exactly that, deliberately, to pick up a user-supplied busybox:
#     PATH=/data/adb/$domain/bin:$PATH
#
# The consequence lands three files away. service.sh starts the daemon with
#     exec start-stop-daemon -bx $execDir/accd.sh -S -- "$@" || exit 12
# start-stop-daemon is a BUSYBOX APPLET. With $busybox_dir off PATH it is not found, service.sh
# exits 127, and the scan finishes having left the phone with no daemon and charging uncapped.
#
# Measured on a Mi A3, three interleaved rounds, nothing else differing:
#     plain PATH                 -> daemon back in 1s
#     PATH with $bin_dir first   -> no daemon after 20s, three times out of three
#     service.sh by hand, same PATH:
#         /dev/.vr25/acc/accd[48]: start-stop-daemon: inaccessible or not found
#
# NO HARDWARE. The resolved guard is extracted and executed against hostile PATH values.

ID=t77
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SB=$execDir/setup-busybox.sh
[ -f "$SB" ] || { no "setup-busybox.sh not found at $SB"; fin; }

# ---- 1: the guard tests the directory that actually holds the applets ------------------------------
_g=$(sed -n '/^case .*PATH.* in$/,/^esac$/p' "$SB" | tail -20)
[ -n "$_g" ] || { no "could not find the PATH guard"; fin; }
printf '%s' "$_g" | grep -q 'busybox_dir' \
  && ok "the guard tests \$busybox_dir, where the applets are" \
  || no "the guard still tests \$bin_dir - a caller that prepends it loses every applet"
printf '%s' "$_g" | grep -q '\$bin_dir:\*)' \
  && no "the old \$bin_dir:* case is still present" \
  || ok "the old \$bin_dir-leading test is gone"
printf '%s' "$_g" | grep -q '":\$PATH:"' \
  && ok "the match is colon-anchored, so one directory name cannot satisfy another" \
  || no "the match is not colon-anchored - a substring could false-positive"

# ---- 2: EXECUTE the guard against the PATH the scanner really builds --------------------------------
guard() {   # $1 = incoming PATH -> resulting PATH
  ( bin_dir=/data/adb/vr25/bin
    busybox_dir=/dev/.vr25/busybox
    PATH=$1
    case ":$PATH:" in
      *":$busybox_dir:"*) ;;
      *) PATH="$bin_dir:$busybox_dir:$PATH";;
    esac
    printf '%s' "$PATH" )
}
has() { case ":$1:" in *":/dev/.vr25/busybox:"*) return 0;; esac; return 1; }

BASE=/product/bin:/system/bin:/system/xbin:/vendor/bin
# THE regression: exactly what acc-switch-scan.sh line 28 produces.
has "$(guard "/data/adb/vr25/bin:$BASE")" \
  && ok "with \$bin_dir already leading PATH, busybox is STILL added (the scanner's case)" \
  || no "the scanner's PATH still loses busybox - start-stop-daemon will not resolve and the daemon will not start"
has "$(guard "$BASE")" \
  && ok "an ordinary PATH gets busybox added" \
  || no "an ordinary PATH did not get busybox"
# idempotent: sourcing twice must not stack duplicates
_1=$(guard "$BASE"); _2=$(guard "$_1")
[ "$_1" = "$_2" ] && ok "sourcing it twice does not prepend twice" || no "not idempotent: [$_2]"
has "$_2" && ok "and busybox is still reachable after the second pass" || no "the second pass dropped busybox"
# a directory whose name merely contains the target must not satisfy the guard
has "$(guard "/dev/.vr25/busybox-old:$BASE")" \
  && ok "a similarly-named directory does not count as busybox being present" \
  || no "/dev/.vr25/busybox-old satisfied the guard - the anchor is missing"
# already correctly present -> left alone
_p="/dev/.vr25/busybox:$BASE"
[ "$(guard "$_p")" = "$_p" ] && ok "a PATH that already has busybox is left untouched" || no "an already-correct PATH was rewritten"

# ---- 3: the applet the daemon start depends on -------------------------------------------------------
SV=$execDir/service.sh
if [ -f "$SV" ]; then
  grep -q 'start-stop-daemon' "$SV" \
    && ok "service.sh still starts the daemon through start-stop-daemon (a busybox applet)" \
    || ok "service.sh no longer depends on start-stop-daemon"
  _o=$(grep -n 'setup-busybox.sh' "$SV" | head -1 | cut -d: -f1)
  _s=$(grep -n 'start-stop-daemon' "$SV" | head -1 | cut -d: -f1)
  { [ -n "$_o" ] && [ -n "$_s" ] && [ "$_o" -lt "$_s" ]; } 2>/dev/null \
    && ok "busybox is set up before the applet is used ($_o < $_s)" \
    || no "service.sh uses start-stop-daemon at ${_s:-?} but sets up busybox at ${_o:-?}"
else
  no "service.sh not found - cannot check the daemon start path"
fi

# ---- 4: live, where the tools exist ------------------------------------------------------------------
if [ -d /dev/.vr25/busybox ]; then
  [ -x /dev/.vr25/busybox/start-stop-daemon ] || [ -e /dev/.vr25/busybox/start-stop-daemon ] \
    && ok "start-stop-daemon is present in $([ -e /dev/.vr25/busybox/start-stop-daemon ] && echo /dev/.vr25/busybox)" \
    || no "start-stop-daemon is missing from /dev/.vr25/busybox - the daemon cannot be started by service.sh"
  _r=$(PATH="/data/adb/vr25/bin:/product/bin:/system/bin" sh -c '. '"$SB"' >/dev/null 2>&1; command -v start-stop-daemon' 2>/dev/null)
  [ -n "$_r" ] \
    && ok "sourcing it under the scanner's PATH resolves start-stop-daemon ($_r)" \
    || no "under the scanner's PATH start-stop-daemon still does not resolve - the scan will lose the daemon"
else
  ok "(no /dev/.vr25/busybox on this host; live check skipped)"
fi

# ---- 5: every generated copy carries the same fix -----------------------------------------------------
# build.sh syncs this block into the installers and the uninstaller. A fix in one copy only is a fix
# that ships broken to anyone who installs.
_bad=
for _f in $execDir/uninstall.sh $execDir/customize.sh $execDir/install.sh; do
  [ -f "$_f" ] || continue
  grep -q '\$bin_dir:\*)' "$_f" && _bad="$_bad $(basename $_f)"
done
[ -z "$_bad" ] && ok "no shipped copy still carries the old guard" \
               || no "the old guard survives in:$_bad"

fin
