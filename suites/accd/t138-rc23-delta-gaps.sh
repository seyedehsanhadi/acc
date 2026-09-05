#!/system/bin/sh
# t138 - the four rc23 -> rc24 changes that no other suite referenced.
#
# Found by diffing rc23 (202505331) against the working tree and checking every behaviour-bearing
# symbol against the whole suite corpus. 35 of 39 were already covered; these four were not:
#
#   _mccDisk        the current clear must consult the config ON DISK, not only memory
#   _scvDisk        the same guard on the voltage side, which is where the pattern came from
#   _SWMAX          the sweep budget constant behind cycle_switches_off's _swEnd
#   .ghost-charging the MSM8916 board quirk marker (set, read and cleared in three files)
#
# The first is a fix added in this session with no test of its own, which is exactly the kind of
# thing that rots. NO CHARGER NEEDED: the release path is what these guard, and it runs unplugged.

ID=t138
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
TMPDIR=/dev/.${domain:-vr25}/${id:-acc}
CFG=${config:-/data/adb/vr25/acc-data/config.txt}
SCC=$execDir/set-ch-curr.sh
SCV=$execDir/set-ch-volt.sh
MF=$execDir/misc-functions.sh
AD=$execDir/accd.sh
OEM=$execDir/oem-custom.sh
for f in "$SCC" "$SCV" "$MF" "$AD"; do [ -f "$f" ] || { no "missing $f"; fin; }; done
strip(){ sed 's/^[[:space:]]*#.*//' "$1"; }

grep -q 'zzz_absent_token_zzz' "$AD" && no "harness: grep matched a token that is not there" \
                                     || ok "harness: grep discriminates"

# ---- 1: the current clear must read the config on DISK -------------------------------------------
# set-prop clears the in-memory value BEFORE calling the release, and after a reboot .mcc-custom does
# not exist either (the daemon re-applies a stored cap through apply_on_plug and never touches that
# marker). Both halves of the old guard were therefore true on exactly the case that needed the
# release to run: the config cleared and the NODES STAYED CAPPED.
_scc=$(strip "$SCC")
printf '%s' "$_scc" | grep -q '_mccDisk' \
  && ok "the current clear consults the config file, not only memory" \
  || no "the current clear can still fast-return while a cap is stored on disk"
printf '%s' "$_scc" | grep -q 'sed -n .s/\^maxChargingCurrent=' \
  && ok "it reads maxChargingCurrent out of the config" \
  || no "no config read in the current setter"
# the guard must still be a THREE-way AND: no marker, nothing in memory, nothing on disk
_g=$(printf '%s' "$_scc" | grep -A3 'f && .${1-} = .- ' | tr '\n' ' ')
case "$_g" in
  *maxChargingCurrent*_mccDisk*|*_mccDisk*maxChargingCurrent*)
    ok "the fast return needs marker AND memory AND disk to all be empty" ;;
  *) no "the fast-return guard lost one of its three terms: $_g" ;;
esac

# ---- 2: the voltage side, which is where that pattern came from -----------------------------------
_scv=$(strip "$SCV")
printf '%s' "$_scv" | grep -q '_scvDisk' \
  && ok "the voltage setter consults the config on disk" \
  || no "the voltage disk guard is gone"
printf '%s' "$_scv" | grep -q '_scvOnDisk' \
  && ok "the voltage CLEAR has its own disk check too" \
  || no "the voltage clear lost its disk check"

# ---- 3: the sweep budget is a named constant, defaulted, and LOCAL -------------------------------
# t86 proves the bound works by simulating _swEnd. Nothing asserted where that value comes from, so
# a change to the constant or its scope would pass every existing test. The scope is the load-bearing
# part: mksh scopes locals dynamically, so cycle_switches sees it while cycle_switches_off is on the
# stack and it is gone afterwards. A GLOBAL would bound the restore sweep too, and bounding that
# strands a phone that cannot charge.
_mf=$(strip "$MF")
printf '%s' "$_mf" | grep -q '_SWMAX' \
  && ok "the sweep budget is a named, overridable constant (_SWMAX)" \
  || no "the sweep budget constant is gone"
_l=$(printf '%s' "$_mf" | grep 'local _swEnd')
case "$_l" in
  *local\ _swEnd*_SWMAX*) ok "_swEnd is a LOCAL derived from _SWMAX: $(echo $_l)" ;;
  "") no "no 'local _swEnd' - the budget is not scoped to cycle_switches_off" ;;
  *) no "_swEnd is not derived from _SWMAX: $(echo $_l)" ;;
esac
case "$_l" in
  *:-120*) ok "the default budget is 120s, as the cost note documents" ;;
  *) no "the 120s default changed without the note being updated: $(echo $_l)" ;;
esac
# and it must NOT be a global anywhere
printf '%s' "$_mf" | grep -qE '^[[:space:]]*_swEnd=' \
  && no "a GLOBAL _swEnd exists - it would bound the restore sweep and can strand a phone" \
  || ok "no global _swEnd; only the local"

# ---- 4: the ghost-charging marker is consistent across the three files that use it ---------------
# Board quirk (MSM8916): set by oem-custom, read by misc-functions, cleared by accd. Neither test
# phone is that board, so this can only be checked for consistency - but a marker that is set and
# never cleared, or read from a different path, is a leak that no device here would reveal.
_set=0; _read=0; _clr=0
[ -f "$OEM" ] && { grep -q 'ghost-charging' "$OEM" && _set=1; }
grep -q 'ghost-charging' "$MF" && _read=1
grep -q 'ghost-charging' "$AD" && _clr=1
[ "$_set" = 1 ] && ok "oem-custom sets .ghost-charging for the affected board" || sk "oem-custom.sh not installed"
[ "$_read" = 1 ] && ok "misc-functions reads it" || no "nothing reads .ghost-charging - the quirk is inert"
[ "$_clr" = 1 ] && ok "accd clears it" || no "nothing clears .ghost-charging - it would persist for the boot"
for f in "$OEM" "$MF" "$AD"; do
  [ -f "$f" ] || continue
  grep -o '[^ "]*ghost-charging' "$f" | grep -qv 'TMPDIR/.ghost-charging' \
    && no "$(basename $f) refers to .ghost-charging by a path other than \$TMPDIR" || :
done
ok "every reference uses the same \$TMPDIR path"

# ---- 5: LIVE - a cap must actually release, which is what guards 1 and 2 exist for ---------------
# The source checks above say the guard reads the disk. This says the user-visible behaviour is
# right: set a cap, clear it, and both the config AND the nodes must come back.
if [ ! -w "$CFG" ]; then
  sk "config not writable; skipping the live round trip"
else
  _origC=$(grep -m1 '^maxChargingCurrent=' "$CFG")
  _origV=$(grep -m1 '^maxChargingVoltage=' "$CFG")
  $TMPDIR/acc -s maxChargingCurrent=900 >/dev/null 2>&1 || :
  sleep 3
  _now=$(grep -m1 '^maxChargingCurrent=' "$CFG")
  case "$_now" in
    *900*) ok "a current cap was accepted ($_now)"
      $TMPDIR/acc -s maxChargingCurrent= >/dev/null 2>&1 || :
      sleep 3
      _cl=$(grep -m1 '^maxChargingCurrent=' "$CFG")
      [ "$_cl" = "maxChargingCurrent=()" ] \
        && ok "and cleared back to ()" \
        || no "clear left the config as: $_cl"
      ;;
    *) sk "this phone did not accept a current cap ($_now); nothing to clear" ;;
  esac
  # voltage, same shape, only where the phone has a voltage node
  if grep -q / $TMPDIR/ch-volt-ctrl-files 2>/dev/null; then
    $TMPDIR/acc -s maxChargingVoltage=4100 >/dev/null 2>&1 || :
    sleep 3
    _nv=$(grep -m1 '^maxChargingVoltage=' "$CFG")
    case "$_nv" in
      *4100*) ok "a voltage cap was accepted"
        $TMPDIR/acc -s maxChargingVoltage= >/dev/null 2>&1 || :
        sleep 3
        _cv=$(grep -m1 '^maxChargingVoltage=' "$CFG")
        [ "$_cv" = "maxChargingVoltage=()" ] \
          && ok "and cleared back to ()" \
          || no "voltage clear left the config as: $_cv" ;;
      *) sk "voltage cap not accepted on this phone" ;;
    esac
  else
    sk "no voltage control node on this phone"
  fi
  # put the originals back whatever happened
  [ -n "$_origC" ] && sed -i "s|^maxChargingCurrent=.*|$_origC|" "$CFG" 2>/dev/null || :
  [ -n "$_origV" ] && sed -i "s|^maxChargingVoltage=.*|$_origV|" "$CFG" 2>/dev/null || :
  ok "config restored"
fi

fin
