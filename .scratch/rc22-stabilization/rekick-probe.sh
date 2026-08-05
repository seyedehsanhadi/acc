#!/system/bin/sh
# rekick-probe.sh - does clearing a current limit collapse a negotiated fast-charge contract?
#
# THE QUESTION
#   set_ch_curr's clear path restores the current-control nodes to values snapshotted at probe time,
#   then asks the charger to re-run input detection (apsd_rerun/rerun_aicl) so those values re-settle
#   to what the charger can really deliver. On a phone holding a USB-PD or QC contract, that request
#   renegotiates it -- and PD/QC land back at 5V and STAY there, because only a physical replug
#   restores a contract. Field report on curtana: 4.83V/5.84W with ACC running, 8.66V/15.3W a minute
#   after a replug.
#
# WHAT IT DOES
#   Records vbus, then sets a current limit, then clears it (which is what fires the re-kick), then
#   records vbus again. If the contract collapsed across the clear AND a rekick line appears in the
#   ledger at that moment, the re-kick is the cause.
#
# SAFETY
#   Only ACC settings are written; no charging node is touched directly. The original
#   max_charging_current is saved first and restored on EXIT/INT/TERM/HUP. Refuses to run without a
#   high-voltage contract, because a 5V source has nothing to lose and the run would prove nothing.

OUT=/sdcard/Download/acc-rekick-$(date +%Y%m%d-%H%M%S).txt
[ -d /sdcard/Download ] && [ -w /sdcard/Download ] || OUT=/data/local/tmp/acc-rekick-$(date +%Y%m%d-%H%M%S).txt
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
TD=/dev/.vr25/acc
CFG=/data/adb/vr25/acc-data/config.txt

log(){ echo "$*"; echo "$*" >> "$OUT"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
mv_(){ _v=$(rd "$1"); isnum "$_v" && echo $((_v / 1000)) || echo ""; }
vbus(){ mv_ $U/voltage_now; }
snap(){ echo "vbus=$(vbus)mV pd_active=$(rd $U/pd_active) real_type=$(rd $U/real_type) icl=$(rd $U/current_max) online=$(rd $U/online) cur=$(rd $B/current_now)"; }

S_MCC=$(sed -n 's/^maxChargingCurrent=//p' "$CFG" 2>/dev/null | tr -d '()' | cut -d' ' -f1)
restore(){ acc -s max_charging_current="$S_MCC" >/dev/null 2>&1; }
finish(){ trap - EXIT INT TERM HUP; restore; log ""; log "restored max_charging_current=($S_MCC)"; log "saved: $OUT"; exit 0; }
trap finish EXIT INT TERM HUP

log "=== rekick probe $(date) ==="
log "device=$(getprop ro.product.device) build=$(sed -n 's/^label=//p' /data/adb/vr25/acc/.build-id 2>/dev/null)"
log "saved max_charging_current=($S_MCC)"
log "BEFORE   $(snap)"

V0=$(vbus)
if ! isnum "$V0" || [ "$V0" -lt 6000 ]; then
  log ""
  log "vbus is ${V0:-unreadable}mV. That is not a high-voltage contract, so there is nothing here to"
  log "collapse and this probe cannot answer the question. Use a QC or PD wall charger."
  exit 0
fi
log "high-voltage contract confirmed at ${V0}mV"

LN=$(wc -l < $TD/.write-ledger 2>/dev/null); isnum "$LN" || LN=0

# A cap low enough to actually engage the control nodes, so the clear has something to restore.
log ""
log "--- setting a 1000mA cap ---"
acc -s max_charging_current=1000 >/dev/null 2>&1
sleep 40
log "CAPPED   $(snap)"
log "         config=$(sed -n 's/^maxChargingCurrent=//p' "$CFG" | tr -d '()' | cut -d' ' -f1)"
V1=$(vbus)

log ""
log "--- clearing the cap (this is what fires the re-kick) ---"
acc -s max_charging_current= >/dev/null 2>&1
sleep 50
log "CLEARED  $(snap)"
V2=$(vbus)

log ""
log "--- ledger written during this run ---"
NOW=$(wc -l < $TD/.write-ledger 2>/dev/null); isnum "$NOW" || NOW=$LN
if [ "$NOW" -gt "$LN" ]; then
  sed -n "$((LN + 1)),${NOW}p" $TD/.write-ledger 2>/dev/null > $TD/.rp.tmp
  while IFS= read -r l; do log "  $l"; done < $TD/.rp.tmp
  rm -f $TD/.rp.tmp
else
  log "  (nothing new)"
fi

log ""
log "vbus: before=${V0}mV capped=${V1:-?}mV cleared=${V2:-?}mV"
if isnum "$V2" && [ "$V2" -lt $(( V0 * 3 / 4 )) ]; then
  log "VERDICT: COLLAPSED. ${V0}mV -> ${V2}mV across the clear."
  log "         If a 'rekick' line appears above at that moment, the re-kick is the cause and the"
  log "         fix is to skip it while a contract is already negotiated."
elif isnum "$V2"; then
  log "VERDICT: HELD at ${V2}mV (was ${V0}mV). The clear did NOT collapse this contract."
  log "         The re-kick is not the cause of the field report; look at the current restore"
  log "         writing a probe-time snapshot over the driver's live value instead."
else
  log "VERDICT: INCONCLUSIVE - vbus unreadable at the end."
fi
finish
