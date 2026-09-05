#!/system/bin/sh
# A voltage set can arrive after current/switch discovery but before voltage discovery is published.

ID=t141
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ]; }

ROOT=${ROOT:-${1:-.}}
[ -d "$ROOT/install" ] && I=$ROOT/install || I=$ROOT
SCV=$I/set-ch-volt.sh
AD=$I/accd.sh
SP=$I/set-prop.sh
for _f in "$SCV" "$AD" "$SP"; do [ -f "$_f" ] || { no "missing $_f"; fin; exit $?; }; done

W=/data/local/tmp/.t141.$$
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT

# Reproduce the live Mi A3 race: current controls and switches exist, voltage output does not yet.
D=$W/race; mkdir -p "$D"; : > "$D/ch-curr-ctrl-files"; : > "$D/ch-switches"
(
  TMPDIR=$D; dataDir=$D; config=$D/config; isAccd=true
  maxChargingVoltage=()
  . "$SCV"
  set_ch_volt 4150
  [ "${maxChargingVoltage[*]}" = 4150 ]
) && ok "an in-flight voltage probe keeps the bare 4150 mV intent" \
  || no "the discovery race still discards the requested voltage"

# Once discovery is explicitly complete, no voltage file means unsupported hardware, not a race.
D=$W/done; mkdir -p "$D"; : > "$D/.mcv-read"
(
  TMPDIR=$D; dataDir=$D; config=$D/config; isAccd=true
  maxChargingVoltage=(4150)
  . "$SCV"
  set_ch_volt 4150 && exit 1
  [ -z "${maxChargingVoltage[0]-}" ]
) && ok "a completed empty probe rejects and clears an unsupported cap" \
  || no "completed discovery leaves a fake voltage cap behind"

_loop=$(grep -n 'for file in \$TMPDIR/ch-\*_' "$AD" | head -1 | cut -d: -f1)
_mark=$(grep -n 'touch \$TMPDIR/.mcv-read' "$AD" | head -1 | cut -d: -f1)
case "${_loop:-x}:${_mark:-x}" in
  *[!0-9:]*|x:*|*:x) no "daemon voltage-completion marker is missing" ;;
  *) [ "$_mark" -gt "$_loop" ] \
       && ok "accd publishes completion after final voltage-file filtering" \
       || no "accd publishes voltage discovery complete too early" ;;
esac

_gates=$(grep -c '\[ -f \$TMPDIR/.mcv-read \]' "$AD")
[ "$_gates" -ge 2 ] \
  && ok "both charging branches wait for completed voltage discovery" \
  || no "a charging branch can consume voltage intent before discovery completes"

grep -q '\$initDaemon.*current_workaround' "$SP" \
  && grep -q 'mcv-read.*initDaemon=true' "$SP" \
  && ok "a queued voltage set forces the discovery init that can consume it" \
  || no "warm restart can leave queued voltage intent undiscovered"

_nc=$(sed -n '/Voltage nodes can drift back/,/rc6 (L1 self-heal)/p' "$AD")
case "$_nc" in
  *'set_ch_volt ${maxChargingVoltage[0]}'*'write-config.sh'*)
    ok "the not-charging branch re-enforces and persists voltage caps" ;;
  *) no "a false Discharging verdict can still leave the voltage cap unapplied" ;;
esac

grep -q 'pmic-votable/FV' "$AD" \
  && grep -q 'pmic-votable/FV/force_' "$I/misc-functions.sh" \
  && grep -q '_mcvm=.*awk' "$SCV" \
  && ok "Qualcomm FV uses an ordered durable pair and preserves both target markers" \
  || no "Qualcomm voltage control can fall back to transient voltage_max mirrors"

fin
