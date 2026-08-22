#!/system/bin/sh
# t99 - aim-high must not touch charger-negotiation nodes, and must not run while paused.
ID=t99; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
# mkfake.sh lives beside this suite in the repo, and suites/ is not shipped inside an installed
# module - so resolving it through $execDir aborts the run on any phone where ACC is actually
# installed, which is every phone this suite matters on. Look next to this file first.
_t99d=$(dirname "$0")
if [ -f "$_t99d/../fakeps/mkfake.sh" ]; then . "$_t99d/../fakeps/mkfake.sh"
elif [ -f "$execDir/suites/fakeps/mkfake.sh" ]; then . "$execDir/suites/fakeps/mkfake.sh"
else echo "  SKIP  mkfake.sh not found beside the suite or under \$execDir"; exit 0
fi
W=/data/local/tmp/t99; rm -rf $W; mkdir -p $W; mkfake $W/ps

_blk=$(sed -n '/if { { \$freshPlug && \${sawUnplug:-false}; } || \${_aimStall:-false}; }/,/^      fi$/p' $execDir/accd.sh)
[ -n "$_blk" ] || { no "aim-high block not found"; fin; }

case "$_blk" in
  *'echo 5000000 > "$_mcf"'*) no "aim-high still writes with a raw echo (no blacklist, no ledger)";;
  *) ok "aim-high no longer uses a raw echo";;
esac
case "$_blk" in
  *'case "${_mcf%/*}" in main|main-charger|mainchg|charger|gccd|bbc)'*) ok "aim-high uses the charger allow-list";;
  *) no "aim-high still uses a battery/gauge DENY-list, so usb/, dc/ and tcpm-* are written";;
esac
case "$_blk" in
  *'chDisabledByAcc'*) ok "aim-high yields while ACC is holding a pause";;
  *) no "aim-high runs with no chDisabledByAcc check - it undoes a current-cap pause";;
esac
case "$_blk" in
  *'_lt_pause_cap'*) ok "aim-high yields at/above the pause level";;
  *) no "aim-high has no pause-level check - up to 17s of unenforced limit after a replug";;
esac

# Executable: run the node loop in the fake tree and assert which files changed.
cat > $W/loop.sh <<EOF
cd $W/ps || exit 1
for _mcf in */current_max */input_current_limit */input_current_settled; do
  [ -w "\$_mcf" ] || continue
  case "\${_mcf%/*}" in main|main-charger|mainchg|charger|gccd|bbc) :;; *) continue;; esac
  echo 5000000 > "\$_mcf"
done
EOF
/system/bin/sh $W/loop.sh
[ "$(cat $W/ps/main/current_max)" = 5000000 ] && ok "main/current_max was lifted" || no "main/current_max was not lifted - the capability is gone"
[ "$(cat $W/ps/usb/current_max)" = 0 ] && ok "usb/current_max untouched" || no "usb/current_max was written (measured: drops a port to 100mA)"
fin
