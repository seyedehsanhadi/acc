#!/system/bin/sh
# The parts of the 2026-09-10 change set the other new suites do not reach.
#
# 1. A caller's owned-key list is data. A malformed key must stop the write, not be published.
# 2. enable_charging restores the idle-avoidance switch from $TMPDIR/.sw. An exhausted scan
#    writes that file with NO selection, and the release then had no switch to flip back on.
# 3. `acc -r` replaces the config wholesale. When it cannot take the lock, it must report the
#    failure and still leave a daemon running rather than exit quietly.
#
# Private files only: no live config, no sysfs node, no daemon signalled.

ID=t-gap-0910b
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
WC=$execDir/write-config.sh
MF=$execDir/misc-functions.sh
DC=$execDir/default-config.txt
for f in "$WC" "$MF" "$DC"; do [ -f "$f" ] || { no "missing $f"; fin; }; done

W=${TMPDIR_T:-/data/local/tmp}/gap-b-$$
rm -rf "$W"; mkdir -p "$W/tmp" "$W/data" 2>/dev/null

echo "--- 1. a malformed owned key stops the write"
mkcfg(){ cp "$DC" "$W/data/config.txt"; sed -i 's/^temperature=.*/temperature=(31 32 33 55)/' "$W/data/config.txt"; }
run(){ # run <mode-arg> <assignments>
  ( set +e
    TMPDIR=$W/tmp; dataDir=$W/data; config=$dataDir/config.txt
    execDir=$execDir
    . "$DC" 2>/dev/null || :
    isAccd=true
    eval "$2"
    . "$WC" "$1"
    echo "rc=$?" ) 2>/dev/null | tail -1
}
mkcfg
before=$(md5sum "$W/data/config.txt" | cut -d' ' -f1)
r=$(run 'own:mcc;rm -rf /data/local/tmp/NOPE' 'maxChargingCurrent=(900)')
after=$(md5sum "$W/data/config.txt" | cut -d' ' -f1)
case "$r" in
  rc=2) ok "a key carrying shell punctuation is refused ($r)" ;;
  *) no "a malformed key was not refused: $r" ;;
esac
[ ".$before" = ".$after" ] && ok "the config is untouched by the refused write" \
  || no "the config changed on a refused write"
# ...and a well-formed key still writes, so the check above is not refusing everything. The disk
# has to carry the same user intent: an expansion may elaborate a cap, never reinstate a cleared one.
mkcfg
run set:mcc 'mcc=900' >/dev/null
r=$(run own:mcc 'maxChargingCurrent=(900 battery/current_max::900000::3000000)')
m=$(sed -n 's/^maxChargingCurrent=//p' "$W/data/config.txt")
case "$r:$m" in
  rc=0:*900*current_max*) ok "a well-formed owned key still publishes its expansion: $m" ;;
  *) no "a well-formed owned key did not publish: $r $m" ;;
esac

echo "--- 2. an exhausted idle-avoidance scan keeps the switch it must release"
# The shipped block, cut out of the file rather than restated here.
blk=$(sed -n '/^      local _resumeSwitch;/,/^      flip_sw on/p' "$MF" | sed 's/^      //')
if [ -z "$blk" ]; then
  no "could not locate the idle-avoidance restore block in misc-functions.sh"
  no "block not located"
else
  probe(){ # probe <contents of .sw>   -> echoes the switch after the restore
    ( TMPDIR=$W/tmp
      mkdir -p "$TMPDIR" 2>/dev/null
      printf '%s\n' "$1" > "$TMPDIR/.sw"
      chargingSwitch=(battery/input_suspend 0 1 --)
      flip_sw(){ :; }
      local(){ :; }
      eval "$blk"
      echo "${chargingSwitch[*]-}" )
  }
  r=$(probe 'chargingSwitch=()')
  [ ".$r" = ".battery/input_suspend 0 1 --" ] \
    && ok "an empty selection leaves the resume switch in place: $r" \
    || no "an empty selection lost the switch to release: <$r>"
  r=$(probe 'chargingSwitch=(battery/charging_enabled 1 0)')
  [ ".$r" = ".battery/charging_enabled 1 0" ] \
    && ok "a real selection is still adopted: $r" \
    || no "a real selection was discarded: <$r>"
fi

echo "--- 3. a reset that cannot take the lock reports it and leaves the daemon running"
SP=$execDir/set-prop.sh
if grep -q 'cfg_lock "$config" || exit 1' "$SP"; then
  ok "the reset path takes the config lock"
  grep -q 'restartDaemon || \$TMPDIR/accd "\$config"' "$SP" \
    && ok "a failed reset still restarts the daemon" \
    || no "a failed reset returns without restarting the daemon"
else
  no "the reset path does not take the config lock"
  no "reset lock absent"
fi

rm -rf "$W" 2>/dev/null
fin
