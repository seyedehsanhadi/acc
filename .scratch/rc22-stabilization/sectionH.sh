#!/system/bin/sh
# sectionH.sh - with NO cable attached, ACC must never claim it is charging.
#
# Before rc22 both test phones failed this, with OPPOSITE current signs and OPPOSITE cached
# polarities, which is what showed the cause was structural rather than device-specific:
#   Mi A3    unplugged, draining 400-980mA, current reads POSITIVE, _DPOL=-  -> "Charging" 5/5
#   Pixel 6a unplugged, draining 450mA,     current reads NEGATIVE, _DPOL=+  -> "Charging" 3/5
#
# All three arbiters are inferences and all three failed together: the sign through a cached
# polarity, a charge counter too coarse to rule, and a kernel status the sign is allowed to
# override. The rc21 tie-break is one-way (Discharging -> Charging) by design, so a wrong
# "Charging" had nothing to correct it. rc22 gives the last word to a fact: no cable, no charging.
#
# This walks every cached state the phone can be in and samples each. Read-mostly: it writes only
# ACC's own tmpfs polarity cache and restores it.

TD=/dev/.vr25/acc
IF=$TD/.batt-interface.sh
B=/sys/class/power_supply/battery
BK=/data/local/tmp/hbk.$$
P=0; F=0; SK=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ SK=$((SK+1)); echo "  skip  $*"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
accst(){ acc -i 2>/dev/null | sed -n 's/^status //p' | head -1; }
setdpol(){ { grep -v '^_DPOL=' $IF 2>/dev/null; echo "_DPOL=$1"; } > $IF.t && mv -f $IF.t $IF; }
restart(){ acc -D restart >/dev/null 2>&1 & sleep 42; }

mkdir -p $BK
[ -s "$IF" ] && grep -q '^battCapacity=' "$IF" || { echo "ABORT: no usable interface cache"; exit 1; }
cp -a $IF $BK/if || { echo "ABORT: could not back up the cache"; exit 1; }
cleanup(){ trap - EXIT INT TERM HUP; cp -a $BK/if $IF 2>/dev/null || :; rm -f $TD/.dpol_unstable; rm -rf $BK
  restart; echo; echo "daemon: $([ -d /proc/$(rd $TD/acc.lock) ] && echo alive || echo DOWN)"
  echo "===== $P passed, $F failed, $SK skipped ====="; exit 0; }
trap cleanup EXIT INT TERM HUP

echo "=== section H: no cable, no charging  $(date) ==="
echo "build : $(sed -n 's/^commit=//p' /data/adb/vr25/acc/.build-id 2>/dev/null)"
echo "device: $(getprop ro.product.device)"

# Only CHARGER paths count. battery/present and maxfg/present mean "a battery is installed", not
# "a cable is attached" -- reading them unfiltered made this abort on a genuinely unplugged phone.
# ACC's own present() filters the same way, which is why it gets this right.
_plug=no
for f in /sys/class/power_supply/*/online /sys/class/power_supply/*/present; do
  case "$f" in
    */battery/*|*/bms/*|*/maxfg/*|*/*fuelgauge*/*|*/*-bms/*) continue;;
  esac
  [ "$(rd "$f")" = 1 ] && { _plug=yes; echo "  still attached: $f"; }
done
echo "cable attached: $_plug   level=$(rd $B/capacity)%  current=$(rd $B/current_now)  kernel=$(rd $B/status)"
if [ "$_plug" = yes ]; then
  echo "ABORT: a cable is still attached. This only means anything with nothing plugged in."
  exit 0
fi

# How many samples must agree. A single sample can be luck; the pre-rc22 Pixel was wrong on only
# 3 of 5, so anything less than a run of samples would have called it fixed when it was not.
N=10
sample_run(){   # $1 = label -> counts Charging claims
  _bad=0; _seen=""
  _i=0
  while [ $_i -lt $N ]; do
    _s=$(accst)
    [ "$_s" = Charging ] && _bad=$((_bad + 1))
    case "$_seen" in *"$_s"*) : ;; *) _seen="$_seen $_s";; esac
    _i=$((_i + 1)); sleep 3
  done
  echo "      $1: $_bad of $N said Charging   verdicts seen:$_seen   current=$(rd $B/current_now)"
  [ "$_bad" -eq 0 ]
}

# ---- every cached polarity, with and without the freeze marker ------------------------------------
for dp in '+' '-' '' 'garbage'; do
  for unst in no yes; do
    setdpol "$dp"
    [ "$unst" = yes ] && touch $TD/.dpol_unstable || rm -f $TD/.dpol_unstable
    restart
    _lbl="_DPOL='${dp:-empty}' frozen=$unst"
    if [ -z "$(accst)" ]; then
      sk "H $_lbl -- acc -i returned nothing"
    elif sample_run "$_lbl"; then
      ok "H $_lbl -> never claimed Charging"
    else
      no "H $_lbl -> claimed Charging with no cable"
    fi
  done
done

# ---- the cache gone entirely: the gate must still hold --------------------------------------------
rm -f $IF; restart
if [ -z "$(accst)" ]; then
  sk "H no cache -- acc -i returned nothing"
elif sample_run "no cache at all"; then
  ok "H with no cache at all -> never claimed Charging"
else
  no "H with no cache at all -> claimed Charging with no cable"
fi

# ---- and that it did not overshoot into calling a real charge a drain -----------------------------
# The gate is one-way by design: it may only ever remove a Charging claim. Confirm the verdict is
# still a sane value rather than empty or nonsense.
cp -a $BK/if $IF; rm -f $TD/.dpol_unstable; restart
_s=$(accst)
case "$_s" in
  Discharging|Idle) ok "H the resting verdict is sane ($_s)";;
  '') no "H the verdict is empty";;
  Charging) no "H claimed Charging with no cable after restore";;
  *) no "H unexpected verdict '$_s'";;
esac
