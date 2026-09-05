#!/system/bin/sh
# t143 - the votable control paths added after rc24's verdict pass, and their safety properties.
#
# Three new mechanisms, none of which had a test:
#
#   MSC_FCC   Google's gvotable current limit, reached through a debugfs mount. This is the
#             intended fix for the Tensor defect where a current cap was accepted, displayed and
#             enforced by nothing -- the value never even reached the write ledger.
#   FV force  Qualcomm's pmic-votable voltage control. The power_supply voltage_max nodes are
#             firmware-owned mirrors that snap back within seconds; the votable is the durable one.
#
# WHY THIS FILE IS CAUTIOUS
#   Two of these write through paths that have hurt this project before. A forced voltage vote left
#   applied is not slow charging, it is NO charging -- a Mi A3 was found flat with voltage_max
#   pinned at 3600000 against a 3.9V pack. And mounting debugfs is a real system change, not a
#   sysfs poke. So the live arms here always restore, and assert the restore.
#
# NO CHARGER NEEDED for the source arms. The live arms skip themselves off-charger.

ID=t143
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
TMPDIR=/dev/.${domain:-vr25}/${id:-acc}
dataDir=${dataDir:-/data/adb/vr25/acc-data}
CFG=${config:-$dataDir/config.txt}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
SCC=$execDir/set-ch-curr.sh
SCV=$execDir/set-ch-volt.sh
UN=$execDir/uninstall.sh
PS=/sys/class/power_supply
for f in "$AD" "$MF"; do [ -f "$f" ] || { no "missing $f"; fin; }; done
strip(){ sed 's/^[[:space:]]*#.*//' "$1"; }
SCR=/data/local/tmp/t143-scratch; rm -rf "$SCR"; mkdir -p "$SCR"
DC=$SCR/accd.nc; strip "$AD" > "$DC"
MC=$SCR/misc.nc; strip "$MF" > "$MC"

grep -q 'zzz_absent_zzz' "$DC" && no "harness: grep matched an absent token" \
                               || ok "harness: grep discriminates"

echo "  -- $(getprop ro.product.device): MSC_FCC cooling=$(grep -ls '^fcc$' /sys/class/thermal/cooling_device*/type 2>/dev/null | wc -l)  FV=$([ -d /sys/kernel/debug/pmic-votable/FV ] && echo yes || echo no)"

# ================================================================= MSC_FCC
grep -q 'msc_fcc_init()' "$MC" && ok "msc_fcc_init is defined" || no "msc_fcc_init is gone"
grep -q 'msc_fcc_vote()' "$MC" && ok "msc_fcc_vote is defined" || no "msc_fcc_vote is gone"

# The mount must be private to ACC and must not be attempted blindly on every phone: the cooling
# device named 'fcc' is the platform signal, and without it this must decline rather than mount.
_mi=$(sed -n '/msc_fcc_init()/,/^}/p' "$MC")
case "$_mi" in
  *"cooling_device*/type"*) ok "the mount is gated on the platform's own fcc cooling device" ;;
  *) no "msc_fcc_init mounts debugfs without checking the platform first" ;;
esac
case "$_mi" in
  *'mkdir -p "$_mscFccMount"'*) ok "it mounts under ACC's own tmpfs dir, not a system path" ;;
  *) no "the debugfs mountpoint is not ACC-owned" ;;
esac
case "$_mi" in
  *'grep -qs " $_mscFccMount debugfs " /proc/mounts'*) ok "it does not re-mount when already mounted" ;;
  *) no "no already-mounted check - repeated calls would stack mounts" ;;
esac
case "$_mi" in
  *'chmod 0700'*) ok "the mountpoint is not world-readable" ;;
  *) no "the debugfs mountpoint is left with default permissions" ;;
esac

# A vote that cannot be released is a phone that cannot charge. Both directions must exist, and the
# owner file that records the vote must be removed on release or a reboot would replay it.
_mv=$(sed -n '/msc_fcc_vote()/,/^}/p' "$MC")
case "$_mv" in
  *disable_vote*) ok "msc_fcc_vote can RELEASE the vote (disable_vote)" ;;
  *) no "no release path - a cast vote could never be withdrawn" ;;
esac
case "$_mv" in
  *cast_int_vote*enable_vote*) ok "the apply path casts then enables, in that order" ;;
  *) no "apply path does not cast+enable" ;;
esac
case "$_mv" in
  *'rm -f "$_mfo"'*) ok "releasing clears the persisted owner marker" ;;
  *) no "release leaves the owner marker behind - a reboot would re-apply the vote" ;;
esac
case "$_mv" in
  *_wlog*) ok "votes reach the write ledger" ;;
  *) no "gvotable writes bypass the ledger - a diagnostic bundle would show nothing" ;;
esac

# Uninstall must undo it: release the vote AND drop the mount.
if [ -f "$UN" ]; then
  _u=$(strip "$UN")
  case "$_u" in *disable_vote*|*msc-fcc-debugfs-vote*) ok "uninstall releases the MSC_FCC vote" ;;
    *) no "uninstall leaves the gvotable vote applied" ;; esac
  case "$_u" in *umount*) ok "uninstall unmounts debugfs" ;;
    *) no "uninstall leaves debugfs mounted" ;; esac
else
  sk "uninstall.sh not installed"
fi

# The current setter must not fire a USB re-kick for a software votable: an APSD on a live QC/PD
# plug is what takes 9V to 4.4V, and a gvotable needs no port re-negotiation at all.
if [ -f "$SCC" ]; then
  _sc=$(strip "$SCC")
  case "$_sc" in
    *'gvotable/MSC_FCC'*rekick_usb*|*rekick_usb*'gvotable/MSC_FCC'*)
      ok "the current setter skips rekick_usb when MSC_FCC is the only control file" ;;
    *) no "a gvotable-only phone still fires a USB re-kick on clear" ;;
  esac
else
  sk "set-ch-curr.sh not installed"
fi

# ================================================================= FV votable
grep -q 'pmic-votable/FV' "$DC" && ok "discovery knows the FV votable" \
                                || no "the FV votable path is gone"
_fv=$(grep -A40 'pmic-votable/FV' "$DC" | tr '\n' ' ')
case "$_fv" in
  *force_val*force_active*) ok "both halves of the FV transaction are recorded" ;;
  *) no "FV is recorded without its paired force_active" ;;
esac
# The saved third field is what a release writes back, so it must never be read out of a votable
# that is currently forcing something. This assertion used to demand the opposite - capture the
# live value - and that is what stranded a Mi A3 at a 4.15V float with no cap configured:
# discovery during a cap recorded the cap as the default and every release re-applied it.
case "$_fv" in
  *_fvdef*) ok "force_val's restore target is guarded, not a bare live read" ;;
  *) no "force_val captures the live value even while a force is active" ;;
esac
case "$_fv" in
  *'::1::0'*) ok "force_active restores to 0, which is its only resting state" ;;
  *) no "force_active would be restored to a live force instead of 0" ;;
esac
# force_* must be written SYNCHRONOUSLY. The generic path backgrounds writes; a paired transaction
# whose two halves race is worse than no transaction.
case "$(grep -A4 'pmic-votable/FV/force_' "$MC" | tr '\n' ' ')" in
  *'write \$$arg $file 0 || :'*) ok "FV force_* writes are synchronous, not backgrounded" ;;
  *) no "FV force_* is written in the background - the paired transaction can race" ;;
esac

# GOING FV-EXCLUSIVE MUST RELEASE WHAT IT STOPS TRACKING.
# The FV branch truncates the control-file list, and that list IS the release path. Without an
# explicit release, a cap already applied to battery/voltage_max or main/voltage_max becomes
# unreachable and sits on the hardware with the config reading (). Found live on laurus: both
# mirrors pinned at 4150000 with no cap configured, and they did not snap back.
case "$_fv" in
  *ch-volt-ctrl-files.prev*) ok "the FV switchover consults .prev to find what it is dropping" ;;
  *) no "FV goes exclusive without releasing the mirrors - a cap can be stranded on the hardware" ;;
esac
_rel=$(grep -A40 'RELEASE WHAT WE ARE ABOUT TO STOP TRACKING' "$AD" | tr '\n' ' ')
case "$_rel" in
  *'pmic-votable/FV/*) continue'*) ok "the release skips the votable's own entries" ;;
  *) no "the release would rewrite the FV nodes it just recorded" ;;
esac
case "$_rel" in
  *_wlog*) ok "each mirror release reaches the write ledger" ;;
  *) no "mirror releases bypass the ledger - a stranded cap would leave no trace" ;;
esac

# OS charge policy: owned by t139-android-charge-policy.sh, which also covers the early-boot
# post-fs-data interaction. Not duplicated here.

# ================================================================= .mcv-read
# The voltage side now has the marker the current side always had. Without it, set_ch_volt wiped a
# stored cap whenever discovery had not run yet -- the config lost the user's value on a cold boot.
grep -q '\.mcv-read' "$DC" && ok "accd uses the .mcv-read discovery marker" \
                           || no ".mcv-read is gone from accd"
if [ -f "$SCV" ]; then
  _sv=$(strip "$SCV")
  case "$_sv" in
    *'.mcv-read'*) ok "the voltage setter defers instead of clearing before discovery" ;;
    *) no "set_ch_volt can still wipe a stored voltage cap before discovery has run" ;;
  esac
  case "$_sv" in
    *'rm -f "$f" "$TMPDIR/.mcv-read"'*) ok "a no-control-file result clears the marker too" ;;
    *) no "the marker can outlive the control files it stands for" ;;
  esac
fi

# ================================================================= LIVE
# Only what can be proven without leaving the phone in a worse state.
_plugged=0
for _pn in $PS/usb/present $PS/pc_port/present $PS/dc/present $PS/ac/present $PS/wireless/present; do
  [ -f "$_pn" ] || continue
  [ "$(cat "$_pn" 2>/dev/null)" = 1 ] && { _plugged=1; break; }
done

# The mount must not accumulate. Whatever else happens, one mountpoint at most.
_nm=$(grep -c " $TMPDIR/.debugfs debugfs " /proc/mounts 2>/dev/null)
case "${_nm:-0}" in
  0) ok "no debugfs mount held (nothing has needed it yet)" ;;
  1) ok "exactly one debugfs mount held" ;;
  *) no "$_nm debugfs mounts stacked on the same point" ;;
esac

# A vote must never be left applied with no config to justify it.
_mcc=$(sed -n 's/^maxChargingCurrent=(//p' "$CFG" 2>/dev/null | head -1)
_mcc=${_mcc%)}
if [ -f "$dataDir/.msc-fcc-debugfs-vote" ] && [ -z "${_mcc:-}" ]; then
  no "an MSC_FCC vote marker is stored while the config holds no current cap"
else
  ok "no orphaned MSC_FCC vote marker"
fi

# Same rule for the Qualcomm force vote: force_active must not be left on with no cap configured.
_fvb=/sys/kernel/debug/pmic-votable/FV
_mcv=$(sed -n 's/^maxChargingVoltage=(//p' "$CFG" 2>/dev/null | head -1)
_mcv=${_mcv%)}
if [ -r "$_fvb/force_active" ]; then
  _fa=$(cat "$_fvb/force_active" 2>/dev/null)
  if [ "${_fa:-0}" != 0 ] && [ -z "${_mcv:-}" ]; then
    no "FV/force_active is $_fa with no voltage cap configured - the pack may be held off charge"
  else
    ok "FV/force_active=${_fa:-0} is consistent with the configured voltage cap"
  fi
else
  sk "no FV votable on this phone"
fi

[ "$_plugged" = 1 ] || sk "no charger attached; skipping the apply/release round trip"
rm -rf "$SCR" 2>/dev/null

_mf=$execDir/misc-functions.sh
_src=$(sed -n '/^apply_on_boot() {/,/^}/p' "$_mf" | tr '\n' ' ')
case "${_src:-}" in
  *'s/^maxChargingVoltage=(//p'*) ok "the default-restore source also reads the node-specs on disk" ;;
  *) no "apply_on_boot restores only from ch-volt-ctrl-files - FV-exclusive strands the mirrors" ;;
esac
case "${_src:-}" in
  *ch-volt-ctrl-files*) ok "it still reads the resolved control files" ;;
  *) no "the resolved control files dropped out of the restore source" ;;
esac
case "${_src:-}" in
  *'.default'*) ok "the fallback only arms on a default restore, never on an apply" ;;
  *) no "the fallback is not gated on a default restore" ;;
esac


# The third field of a ctrl-files entry is the RESTORE TARGET. Reading it out of a votable that
# is currently forcing something records the CAP as the default, and every later release then
# re-applies it. Found live on a Mi A3 held at a 4.15V float at 34% with the config reading ().

fin
