#!/system/bin/sh
# Google/Tensor current caps must use the charger's independent FCC election, not transient mirrors.

ID=t142
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

ROOT=${ROOT:-${1:-.}}
[ -d "$ROOT/install" ] && I=$ROOT/install || I=$ROOT
MF=$I/misc-functions.sh
RC=$I/read-ch-curr-ctrl-files-p2.sh
AD=$I/accd.sh
UN=$I/uninstall.sh
for _f in "$MF" "$RC" "$AD" "$UN"; do [ -f "$_f" ] || { no "missing $_f"; fin; exit $?; }; done

W=/data/local/tmp/.t142.$$
mkdir -p "$W/fcc" "$W/tmp" "$W/data"
trap 'rm -rf "$W"' EXIT
: > "$W/fcc/cast_int_vote"
: > "$W/fcc/enable_vote"
: > "$W/fcc/disable_vote"
sed -n '/^msc_fcc_init()/,/^at()/p' "$MF" | sed '$d' > "$W/functions.sh"
[ -s "$W/functions.sh" ] || { no "could not isolate FCC functions"; fin; exit $?; }

(
  TMPDIR=$W/tmp; dataDir=$W/data; ACC_MSC_FCC_DIR=$W/fcc; MSC_FCC_OWNER=$W/data/owner
  maxChargingVoltage=(); maxChargingCurrent=(500 gvotable/MSC_FCC::500000::-1); applyOnPlug=()
  touch "$TMPDIR/.mcc-custom"
  . "$W/functions.sh"
  apply_on_plug
  [ "$(cat "$W/fcc/cast_int_vote")" = 500000 ] \
    && [ "$(cat "$W/fcc/enable_vote")" = DEBUGFS ] \
    && [ "$(cat "$W/data/owner")" = 500000 ]
) && ok "500 mA becomes an enabled independent 500000 uA FCC ballot" \
  || no "FCC ballot apply is not exact or durable"

(
  TMPDIR=$W/tmp; dataDir=$W/data; ACC_MSC_FCC_DIR=$W/fcc; MSC_FCC_OWNER=$W/data/owner
  maxChargingVoltage=(); maxChargingCurrent=(); applyOnPlug=()
  echo 'gvotable/MSC_FCC::v000::-1' > "$TMPDIR/ch-curr-ctrl-files"
  . "$W/functions.sh"
  apply_on_plug default
  [ "$(cat "$W/fcc/disable_vote")" = DEBUGFS ] && [ ! -e "$W/data/owner" ]
) && ok "clear disables only ACC's DEBUGFS ballot" \
  || no "clear leaves the FCC ballot or ownership marker behind"

(
  TMPDIR=$W/tmp; dataDir=$W/data; ACC_MSC_FCC_DIR=$W/fcc; MSC_FCC_OWNER=$W/data/owner
  echo untouched > "$W/fcc/cast_int_vote"
  rm -f "$TMPDIR/.mcc-custom"
  maxChargingVoltage=(); maxChargingCurrent=(500 gvotable/MSC_FCC::500000::-1); applyOnPlug=()
  . "$W/functions.sh"
  apply_on_plug
  [ "$(cat "$W/fcc/cast_int_vote")" = untouched ]
) && ok "a stale daemon loop cannot recreate a cleared vote" \
  || no "the marker guard allows a stale FCC re-apply"

grep -q "gvotable/MSC_FCC::v000::-1" "$RC" \
  && ok "discovery prefers MSC_FCC over firmware-owned mirrors" \
  || no "current discovery does not publish the FCC backend"

_mig=$(sed -n '/Persist during init/,/unset _mcm/p' "$AD")
grep -q 'maxChargingCurrent=(.*_mcm' "$AD" \
  && case "$_mig" in *set_ch_curr*write-config.sh*) :;; *) false;; esac \
  && grep -q '.msc-fcc-debugfs-vote' "$AD" \
  && ok "daemon startup migrates old entries and cleans an orphaned owned vote" \
  || no "restart can retain old mirror entries or an orphaned vote"

grep -q 'printf DEBUGFS.*disable_vote' "$UN" \
  && ok "no-reboot uninstall drops only ACC's FCC ballot" \
  || no "uninstall can leave the Pixel current-capped"

fin
