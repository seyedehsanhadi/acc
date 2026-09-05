#!/system/bin/sh
# t-restore-safety - the paths that decide whether a phone charges again after a scan.
#
# WHY THIS EXISTS. The A/B that plants each 7.2.4 defect back found 23 fixes with no test behind
# them, identically on both test phones. This suite closes the six where the consequence lands on
# the battery rather than on a report: the scan finishes, says it restored cleanly, and the phone is
# left throttled, cut, or lied to about what was written.
#
#   L950   restore never re-checked the charger input votes after everything settled, so the
#          firmware's level-limit pause re-armed main-charger/current_max to the USB default
#          (500000 instead of 3200000, 478 mA instead of 1418 mA) SECONDS after the replay had read
#          it back correctly -- and the run still reported a clean restore.
#   L987   restore did not mark itself as restoring, so wr() applied the crash blacklist to the
#          REPLAY and refused to write recorded original values back to blacklisted nodes.
#   L1055  restore reported readback failures collected BEFORE icl_repair ran, so a value the repair
#          had already fixed was still announced as a failure.
#   L1148  the SAFE MODE banner claimed unknown/vendor/learned nodes are NEVER written. They are --
#          that is how a switch is found on a phone nobody has scanned before. The banner was a lie
#          to the one person who most needed the truth.
#   L1495  apsd_rerun / rerun_aicl were written RAW, bypassing the blacklist and the crash journal.
#          This is the recurring class in this codebase: a new writer that skips wr().
#   L2485  LAYER 4d's deferred input-cut was skipped when a level node merely ACCEPTED a value
#          without enforcing it, so a phone with a read-only level node never got the cut tested.
#
# NO HARDWARE. Source assertions paired with the exact mutation that reinstates each defect.

ID=t-restore-safety
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

# acc-compat.sh is NOT installed at that path - the module keeps it under acc-data/backup and the
# repo ships it in suites/. A single hardcoded default made three of these abort with
# "acc-compat.sh not found" on every installed phone, which reads as a product failure and is not.
# t-layer-crash already had a two-step fallback; give every suite the same search.
_amps_find(){
  for _ac in "${AMPS:-}" /data/adb/vr25/acc/acc-compat.sh              /data/adb/vr25/acc-data/backup/acc-compat.sh              /data/local/tmp/suites/acc-compat.sh /data/local/tmp/amps.sh; do
    [ -n "$_ac" ] && [ -f "$_ac" ] && { echo "$_ac"; return 0; }
  done
  return 1
}
AMPS=$(_amps_find)
[ -f "$AMPS" ] || { no "acc-compat.sh not found (set AMPS=)"; fin; }

# ---- L950: the late input-current re-check ---------------------------------------------------------
grep -q '&& icl_repair' "$AMPS" \
  && ok "restore re-checks the charger input votes after everything has settled (icl_repair)" \
  || no "icl_repair is no longer called - a firmware pause can leave charging collapsed and the run still reports a clean restore"
_ir=$(grep -n '&& icl_repair' "$AMPS" | head -1 | cut -d: -f1)
_rp=$(grep -n 'RESTORING (replaying snapshot' "$AMPS" | head -1 | cut -d: -f1)
{ [ -n "$_ir" ] && [ -n "$_rp" ] && [ "$_ir" -gt "$_rp" ]; } 2>/dev/null \
  && ok "  and it runs AFTER the replay ($_ir > $_rp), which is the whole point of a LATE re-check" \
  || no "  icl_repair at ${_ir:-?} does not follow the replay at ${_rp:-?}"
grep -qi 'charge speed re-armed' "$AMPS" \
  && ok "  and a repair is announced rather than done silently" \
  || no "  a repaired input current is not announced"
sed -n '/^icl_repair(){/,/^}/p' "$AMPS" | grep -q '\*/usb' \
  && ok "  and Pixel usb/current_max is eligible for late repair" \
  || no "icl_repair skips usb/current_max after the Pixel group collapses it"

# ---- L987: the replay must be exempt from the crash blacklist ---------------------------------------
grep -q '^  _RESTORING=1' "$AMPS" \
  && ok "restore marks itself as restoring, exempting the replay from the crash blacklist" \
  || no "_RESTORING is not set to 1 - the replay cannot write back to a blacklisted node and the phone stays cut"
sed -n '/^wr()/,/^}/p' "$AMPS" | grep -q '_RESTORING' \
  && ok "  and wr() honours that flag" \
  || no "  wr() does not consult _RESTORING, so the flag is decorative"

# ---- L1055: do not report failures the repair already fixed -------------------------------------------
grep -qE '\-gt 0 \] && \[ -s "\$SNAP" \]' "$AMPS" \
  && ok "the readback-failure report is gated on there being failures AND a snapshot" \
  || no "the stale-failure gate is gone - a value icl_repair already fixed can still be announced as a failure"

# ---- L1148: the SAFE MODE banner must tell the truth ---------------------------------------------------
# The fix reworded it: unknown/vendor/learned nodes ARE written, behind the safety deny-list.
# PIPE, never capture. `_sm=$(sed -n '/SAFE MODE/,/NEVER WRITTEN/p')` spans a large block and
# `printf '%s' "$_sm"` then died with "Argument list too long" on Android -- and a printf that
# ERRORS takes whichever branch the && / || lands on, which here produced one false FAIL and one
# false PASS from the same line. Locally, with a bigger ARG_MAX, both looked fine.
sed -n '/SAFE MODE/,/NEVER WRITTEN/p' "$AMPS" | grep -q . \
  || { no "could not find the SAFE MODE banner"; fin; }
sed -n '/SAFE MODE/,/NEVER WRITTEN/p' "$AMPS" | grep -qi 'unknown vendor nodes that pass the safety deny-list' \
  && ok "the SAFE MODE banner admits unknown/vendor nodes are written behind the deny-list" \
  || no "the banner does not say unknown/vendor nodes get written - it is claiming a guarantee AMPS does not make"
sed -n '/SAFE MODE/,/NEVER WRITTEN/p' "$AMPS" | grep -qi 'NEVER WRITTEN: unknown, vendor and learned nodes' \
  && no "the banner still lists unknown/vendor/learned under NEVER WRITTEN - that is the lie the fix removed" \
  || ok "  and it does not list them under NEVER WRITTEN"

# Pixel 6a exposes its fuel gauge as power_supply/maxfg. Generic discovery wrote
# maxfg/rc_switch_enable live even though the banner promises fuel-gauge nodes are never written.
_sdeny=$(sed -n "s/^SUPERDENY_RE='\(.*\)'/\1/p" "$AMPS" | head -1)
printf '%s' '/sys/class/power_supply/maxfg/rc_switch_enable' | grep -Eiq "$_sdeny" \
  && ok "Google maxfg fuel-gauge controls are protected from generic probes" \
  || no "maxfg/rc_switch_enable bypasses the fuel-gauge deny-list"

# Highest-accuracy name-agnostic scans on Pixel and Mi attempted maintenance, battery-aging and
# USB-negotiation controls. One (`adapter_cc_mode`) was even falsely promoted as a bypass; Pixel's
# aact_state changed the Aged Adjusted Charge Table and did not restore in the report window.
_shdeny=$(sed -n "s/^SHAPEDENY_RE='\(.*\)'/\1/p" "$AMPS" | head -1)
_miss=
for _unsafe in \
  /sys/class/power_supply/battery/force_fcr_update_ops \
  /sys/class/power_supply/battery/aact_state \
  /sys/class/power_supply/battery/pairing_state \
  /sys/class/power_supply/battery/first_usage_date \
  /sys/devices/platform/google,charger/supplier:i2c:12-0025/supplier/frs \
  /sys/class/power_supply/usb/dp_dm \
  /sys/class/power_supply/main/comp_clamp_level \
  /sys/class/power_supply/main/toggle_stat \
  /sys/class/power_supply/usb/smb_en_reason \
  /sys/class/power_supply/usb/apsd_timeout \
  /sys/class/power_supply/usb/connector_type \
  /sys/class/power_supply/usb/adapter_cc_mode \
  /sys/class/power_supply/usb/hvdcp_opti_allowed \
  /sys/class/power_supply/usb/pe_start \
  /sys/devices/platform/google,charger/charging_status \
  /sys/devices/platform/google,charger/charging_type; do
  printf '%s' "$_unsafe" | grep -Eiq "$_shdeny" || _miss="$_miss ${_unsafe##*/}"
done
[ -z "$_miss" ] && ok "live-found maintenance/aging/USB-negotiation nodes are read-only to generic discovery" \
                 || no "generic discovery can still write protected live nodes:$_miss"

# The speed diagnosis must sample after icl_repair, not before it. Both phones ended their deep pass
# at 500mA, printed weak-cable advice, and only then restored the negotiated current.
_spr=$(grep -n '_spr_restore=.*_RESTORING' "$AMPS" | head -1 | cut -d: -f1)
_box=$(grep -n '^_csr()' "$AMPS" | head -1 | cut -d: -f1)
[ -n "$_spr" ] && [ -n "$_box" ] && [ "$_spr" -lt "$_box" ] 2>/dev/null \
  && ok "collapsed input votes are repaired before charger-speed sampling" \
  || no "charger speed is still diagnosed before AMPS repairs its own post-probe current collapse"

# ---- L1495: no raw writers. Everything goes through wr(). ------------------------------------------------
# The recurring class in this codebase. A raw `echo x > node` skips the blacklist, the journal and
# the write ledger, so a node that took the phone down can be written again on the next run.
grep -q 'wr "$_n" 1' "$AMPS" \
  && ok "apsd_rerun/rerun_aicl go through wr(), so the blacklist and journal apply" \
  || no "the re-run pokes no longer use wr() - they bypass the blacklist and the crash journal"
_raw=$(grep -nE '^[[:space:]]*echo [^|]*> *"\$_n"' "$AMPS" | grep -v 'wr ' | wc -l)
[ "${_raw:-0}" -eq 0 ] \
  && ok "  and no raw 'echo ... > \$_n' writer has crept back in" \
  || no "  ${_raw} raw node writer(s) bypassing wr() - each one skips the blacklist"

# ---- L2485: an accepted-but-unenforced level must not skip the deferred cut ------------------------------
# Scope this to the 4d skip specifically. LEVELOK legitimately gates SUPER_RUN elsewhere, so a
# file-wide search for it fails on correct source -- which it did, on the first run of this suite.
_4d=$(grep -nF 'if [ -z "$BYPASS$CUT$DRAIN' "$AMPS" | head -1)
[ -n "$_4d" ] || { no "could not find LAYER 4d's skip condition"; fin; }
case "$_4d" in
  *'$_le_enf$BYPASS_HELD'*)
    ok "LAYER 4d's skip uses the ENFORCED level list (line ${_4d%%:*})" ;;
  *'$LEVELOK$BYPASS_HELD'*)
    no "LAYER 4d's skip uses LEVELOK, the merely-ACCEPTED list - a phone whose level node only accepts values never gets the input cut tested" ;;
  *)
    no "LAYER 4d's skip condition is neither form: $_4d" ;;
esac

# recover_online can run before the known-switch layer snapshots charge_disable. If it writes that
# node first, the later snapshot records AMPS's value instead of the user's original and restore
# faithfully leaves the phone changed. Snapshot this otherwise-uncovered recovery write in place.
sed -n '/^recover_online(){/,/^}/p' "$AMPS" | grep -q 'snap_add "\$_rcd"; wr "\$_rcd" 0' \
  && ok "recover_online snapshots charge_disable before changing it" \
  || no "recover_online writes charge_disable before it is snapshotted - restore can preserve AMPS's value instead of the original"

fin
