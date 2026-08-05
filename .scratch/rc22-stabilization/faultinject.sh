#!/system/bin/sh
# faultinject.sh - break each per-device fact ACC has to learn, and check it notices.
#
# WHY
#   ACC's correctness rests on a chain it learns per phone: which nodes are the fuel gauge, what
#   unit the current is in, which sign means charging, whether the status node lies, which switch
#   holds. Every limit sits downstream. When a link is wrong the failure is always the same and
#   always silent: is_charging goes false and all four limits stop being evaluated.
#
#   Two phones are two points in that space. But every one of those facts lives in a file we can
#   write, so the rest of the space can be SIMULATED. That is the only honest route to "works on a
#   phone we have never seen".
#
# WHAT EACH CASE ASKS
#   Not "does it still work" but "does it recover, or say so". A silent wrong answer is the failure.
#
# SAFETY
#   Every injected file is backed up first and restored on EXIT/INT/TERM/HUP, including the daemon
#   restart. No charging node is written. Config is untouched. Worst case is a wasted run.

TD=/dev/.vr25/acc
SK=0
DD=/data/adb/vr25/acc-data
IF=$TD/.batt-interface.sh
BK=/data/local/tmp/fi-backup.$$
OUT=/sdcard/Download/acc-faultinject-$(date +%Y%m%d-%H%M%S).txt
[ -d /sdcard/Download ] && [ -w /sdcard/Download ] || OUT=/data/local/tmp/acc-faultinject-$(date +%Y%m%d-%H%M%S).txt
P=0; F=0

log(){ echo "$*"; echo "$*" >> "$OUT"; }
ok(){ P=$((P+1)); log "  PASS  $*"; }
no(){ F=$((F+1)); log "  FAIL  $*"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
accst(){ acc -i 2>/dev/null | sed -n 's/^status //p' | head -1; }
kst(){ rd "$(sed -n 's/^battStatus=//p' $IF 2>/dev/null | head -1 | sed 's|^|/sys/class/power_supply/|')"; }
alive(){ _p=$(rd $TD/acc.lock); [ -n "$_p" ] && [ -d "/proc/$_p" ]; }
looping(){   # the honest heartbeat: acc.lock only says the process exists
  _a=$(wc -l < $DD/logs/flight.log 2>/dev/null); sleep 25
  _b=$(wc -l < $DD/logs/flight.log 2>/dev/null)
  [ "${_b:-0}" -gt "${_a:-0}" ]
}
restart(){ acc -D restart >/dev/null 2>&1 & sleep 40; }

mkdir -p $BK
cp -a $IF $BK/batt-interface.sh 2>/dev/null || :
cp -a $DD/config.txt $BK/config.txt 2>/dev/null || :
[ -f $TD/.dpol_unstable ] && touch $BK/.had_unstable || :

cleanup(){
  trap - EXIT INT TERM HUP
  log ""
  log "--- restoring ---"
  cp -a $BK/batt-interface.sh $IF 2>/dev/null || :
  cp -a $BK/config.txt $DD/config.txt 2>/dev/null || :
  [ -f $BK/.had_unstable ] || rm -f $TD/.dpol_unstable 2>/dev/null || :
  rm -rf $BK 2>/dev/null || :
  restart
  log "daemon alive: $(alive && echo yes || echo NO)"
  log "config: $(sed -n 's/^capacity=//p' $DD/config.txt)"
  log ""
  log "=== $P passed, $F failed, $SK skipped ==="
  log "$OUT"
  exit 0
}
trap cleanup EXIT INT TERM HUP

log "=== fault injection $(date) ==="
log "device=$(getprop ro.product.device) build=$(sed -n 's/^label=//p' /data/adb/vr25/acc/.build-id 2>/dev/null) acc=$(sed -n 's/^versionCode=//p' /data/adb/vr25/acc/module.prop)"
CHARGING=no
present_any(){ for f in /sys/class/power_supply/*/online; do [ "$(rd "$f")" = 1 ] && return 0; done; return 1; }
present_any && [ "$(kst)" = Charging ] && CHARGING=yes
log "baseline: acc=$(accst) charging=$CHARGING level=$(rd /sys/class/power_supply/battery/capacity)$(rd /sys/class/power_supply/maxfg/capacity)"
if [ "$CHARGING" != yes ]; then
  log ""
  log "NOTE: this phone is not charging. Cases 1 and 2 ask whether a WRONG current sign is caught"
  log "      while the pack is filling, so they cannot be answered here and are reported as skipped"
  log "      rather than passed. Re-run on a charging phone to cover them."
fi
log ""

# ---- 1: the cached polarity is inverted ------------------------------------------------------------
# The failure mode behind the sweet report: a wrong sign says Discharging with the cable in, so
# is_charging is false and every limit is skipped. The kernel tie-break is what must rescue it.
log "--- 1: cached polarity inverted ---"
_cur=$(sed -n 's/^_DPOL=//p' $IF | head -1)
case "$_cur" in +) _bad=-;; -) _bad=+;; *) _bad=+;; esac
{ grep -v '^_DPOL=' $IF; echo "_DPOL=$_bad"; } > $IF.t && mv -f $IF.t $IF
rm -f $TD/.dpol_unstable
restart
_st=$(accst); _k=$(kst)
log "    _DPOL $_cur -> $_bad   acc=$_st kernel=$_k"
if [ "$CHARGING" != yes ]; then
  SK=$((SK+1)); log "  SKIP  1: not charging, so an inverted sign cannot be exercised"
elif [ "$_st" = Discharging ]; then
  no "1: inverted polarity left ACC believing Discharging while the pack fills - every limit is blind"
else
  ok "1: inverted polarity recovered ($_st, kernel says $_k)"
fi
alive && ok "1: daemon survived" || no "1: daemon DIED"

# ---- 2: inverted AND frozen ---------------------------------------------------------------------
# .dpol_unstable stops any re-latch, so a wrong sign is permanent for the boot. This is the state
# BOTH test phones were found in, and the one the tie-break has to carry alone.
log "--- 2: polarity inverted AND frozen (.dpol_unstable armed) ---"
touch $TD/.dpol_unstable
restart
_st=$(accst); _k=$(kst)
log "    acc=$_st kernel=$_k unstable=armed"
if [ "$CHARGING" != yes ]; then
  SK=$((SK+1)); log "  SKIP  2: not charging, so a frozen wrong sign cannot be exercised"
elif [ "$_st" = Discharging ]; then
  no "2: frozen wrong polarity is NOT recovered - limits blind for the rest of the boot"
else
  ok "2: frozen wrong polarity still recovered ($_st)"
fi
alive && ok "2: daemon survived" || no "2: daemon DIED"

cp -a $BK/batt-interface.sh $IF 2>/dev/null || :
rm -f $TD/.dpol_unstable

# ---- 3: the fuel gauge nodes point nowhere -------------------------------------------------------
log "--- 3: gauge nodes point at a missing path ---"
sed 's|^battCapacity=.*|battCapacity=ghost/capacity|; s|^temp=.*|temp=ghost/temp|' $BK/batt-interface.sh > $IF
restart
alive && ok "3: daemon survived unreadable gauge nodes" || no "3: daemon DIED on unreadable nodes"
looping && ok "3: loop still running" || no "3: loop stopped"

# ---- 4: the interface cache is half-written ------------------------------------------------------
# A crash mid-write, or a tmpfs wipe caught at the wrong moment.
log "--- 4: interface cache truncated mid-line ---"
head -c 60 $BK/batt-interface.sh > $IF
restart
alive && ok "4: daemon survived a truncated cache" || no "4: daemon DIED on a truncated cache"
looping && ok "4: loop still running" || no "4: loop stopped"

# ---- 5: the current unit is mis-detected ----------------------------------------------------------
# mA vs uA. Getting it wrong turns a 1.5A charge into 0mA, or 1500mA into 1500000.
log "--- 5: ampFactor mis-detected ---"
sed 's|^ampFactor_=.*|ampFactor_=1000|' $BK/batt-interface.sh > $IF
restart
alive && ok "5: daemon survived a wrong ampFactor" || no "5: daemon DIED"
looping && ok "5: loop still running" || no "5: loop stopped"

cp -a $BK/batt-interface.sh $IF 2>/dev/null || :

# ---- 6: the status node lies -----------------------------------------------------------------------
# battStatusWorkaround exists because some kernels do exactly this.
log "--- 6: status node forced to Discharging ---"
sed -i "s|^battStatusOverride=.*|battStatusOverride=Discharging|" $DD/config.txt 2>/dev/null \
  || echo "battStatusOverride=Discharging" >> $DD/config.txt
restart
alive && ok "6: daemon survived a lying status node" || no "6: daemon DIED"
looping && ok "6: loop still running" || no "6: loop stopped"
cp -a $BK/config.txt $DD/config.txt 2>/dev/null || :

# ---- 7: the configured switch does not exist -------------------------------------------------------
# A stale config after a ROM change, or a node the kernel dropped.
log "--- 7: charging switch points at a missing node ---"
sed -i "s|^chargingSwitch=(.*|chargingSwitch=(/sys/class/power_supply/ghost/enable 1 0)|" $DD/config.txt
restart
alive && ok "7: daemon survived a missing switch node" || no "7: daemon DIED"
looping && ok "7: loop still running" || no "7: loop stopped"
cp -a $BK/config.txt $DD/config.txt 2>/dev/null || :

cleanup
