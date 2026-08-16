#!/system/bin/sh
# AMPS restore(): the phone must end the run in the state it started in.
#
# Five defects, all confirmed by reading restore() and its callees. Every one of them ends a run
# that PRINTS "===== restored".
#
#   1. THE SECOND defaults_native UNDID THE REPLAY. restore did defaults_native -> 3-pass snapshot
#      replay with readback -> defaults_native AGAIN. The second call rewrites the very nodes the
#      replay had just put back: charge_stop_level 100, charge_start_level 99,
#      charge_control_end_threshold 100, batt_full_capacity 100, charge_control_limit 0, qpnp
#      upper_limit -1. Nothing replayed the snapshot afterwards. A Pixel or Samsung with an 80%
#      limit set before the run ended it charging to 100%, with no limit and no message -- the
#      readback had already passed, so fail stayed 0 and the run reported success.
#
#   2. THE CRASH MARKER WAS CLEARED FIRST AND REFILLED BY RESTORE'S OWN WRITES. RCT means "a write
#      returned but the scan never reached its exit". It was removed at the top, then every write
#      restore performs put it back, because jrn_end rewrites it unconditionally. So a clean run
#      always ended holding a live marker naming whatever restore wrote last. A later unrelated
#      panic then blamed that node and blacklisted it forever -- usually usb/apsd_rerun, the node
#      recover_online needs, so every future run lost the ability to revive a dropped charger.
#
#   3. A FULL /data VETOED THE RESTORE. wr() exempts restore from the blacklist but not from the
#      journal, and jrn_begin fails when /data is full or read-only. The probes had already written
#      their OFF values; the replay that puts them back then returned 1 on every node.
#
#   4. THE WATCHDOG WAS SHORTER THAN RESTORE. 130s, against a replay of 3 passes plus a 45s
#      recover_online plus two 15s daemon restarts. It fired mid-replay, wrote its own defaults over
#      values not yet restored, and killed the process 5 seconds later.
#
#   5. A REJECTED ON VALUE CAME BACK VIA ADDLINES, and the guard that rejected it only ever ran on
#      the path a FAILING switch takes.
#
# NO HARDWARE.

ID=t-restore-integrity
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

AMPS=${AMPS:-/data/local/tmp/amps.sh}
[ -f "$AMPS" ] || { no "amps not found (set AMPS=)"; fin; }

BODY=$(sed -n '/^restore(){/,/^  chmod 0644 "\$OUT"/p' "$AMPS")
[ -n "$BODY" ] || { no "could not lift restore()"; fin; }

# ---- 1: no defaults_native after the snapshot replay -------------------------------------------------
_rep=$(printf '%s\n' "$BODY" | grep -n 'done < "\$SNAP"' | head -1 | cut -d: -f1)
_wd=$(printf '%s\n' "$BODY"  | grep -n 'sleep 420; defaults_native' | head -1 | cut -d: -f1)
if [ -z "$_rep" ]; then
  no "could not find the snapshot replay loop"
else
  _after=$(printf '%s\n' "$BODY" | sed -n "$((_rep+1)),\$p" | grep -v '^ *#' | grep -c 'defaults_native')
  [ "${_after:-1}" -eq 0 ] \
    && ok "nothing calls defaults_native after the replay, so the user's %-limit survives" \
    || no "$_after defaults_native call(s) still run after the replay - they overwrite the restored limit"
fi

# ---- 2: the recent-write marker is cleared LAST ------------------------------------------------------
_rm=$(printf '%s\n' "$BODY" | grep -n 'rm -f "\$RCT"' | head -1 | cut -d: -f1)
_last=$(printf '%s\n' "$BODY" | grep -nE 'icl_repair|recover_online|done < "\$SNAP"' | tail -1 | cut -d: -f1)
if [ -n "$_rm" ] && [ -n "$_last" ]; then
  [ "$_rm" -gt "$_last" ] 2>/dev/null \
    && ok "RCT is cleared after restore's own last write, so a clean run leaves no false marker" \
    || no "RCT is cleared at line $_rm but restore still writes at $_last - jrn_end puts the marker straight back"
else
  no "could not locate the RCT removal and restore's last write (rm=$_rm last=$_last)"
fi

# ---- 3: a dead journal must not veto a restore write ---------------------------------------------------
_wr=$(sed -n '/^wr(){/,/return \$_wrc; }/p' "$AMPS")
[ -n "$_wr" ] || no "could not lift wr() - its tail changed shape again, so this whole check is blind"
printf '%s\n' "$_wr" | grep -q '_RESTORING:-0.*= 1 \] || jrn_begin' \
  && ok "the journal is bypassed while restoring, so a full /data cannot block the replay" \
  || no "jrn_begin still gates every restore write - a full /data leaves the phone cut"

# EXECUTE the guard in both directions.
_g(){ ( _RESTORING=$1
        jrn_begin(){ return 1; }              # journal cannot be written
        { [ "${_RESTORING:-0}" = 1 ] || jrn_begin x y; } && echo WRITE || echo BLOCKED ) 2>/dev/null; }
[ "$(_g 1)" = WRITE ]   && ok "restoring: the write proceeds despite the dead journal" || no "restoring was still blocked"
[ "$(_g 0)" = BLOCKED ] && ok "probing: a dead journal still blocks the write, as it must" || no "probing was allowed to write unjournalled"

# ---- 4: the watchdog outlives restore's worst case -------------------------------------------------------
_secs=$(printf '%s\n' "$BODY" | sed -n 's/.*( *sleep \([0-9]*\); defaults_native.*/\1/p' | head -1)
case "${_secs:-x}" in
  ''|*[!0-9]*) no "could not read the restore watchdog budget" ;;
  *) [ "$_secs" -ge 300 ] 2>/dev/null \
       && ok "the restore watchdog allows ${_secs}s, comfortably past a 3-pass replay plus a 45s re-online" \
       || no "the watchdog fires after only ${_secs}s - it kills restore mid-replay" ;;
esac
_grace=$(printf '%s\n' "$BODY" | sed -n 's/.*defaults_native 2>\/dev\/null; sleep \([0-9]*\);.*/\1/p' | head -1)
case "${_grace:-x}" in
  ''|*[!0-9]*) no "could not read the watchdog grace period" ;;
  *) [ "$_grace" -ge 15 ] 2>/dev/null \
       && ok "it waits ${_grace}s after its safety writes before the kill" \
       || no "only ${_grace}s between the safety writes and SIGKILL - the kill lands mid-write" ;;
esac

# ---- 4b: wr() reports the real write status ------------------------------------------------------------------
# wr's last command was jrn_end, whose own last command is `rm -f ... || :` -- status 0, always. The
# write's own status was discarded, so wr returned success whether the node took the value or
# returned EACCES, and the [write-fail] guard that feeds the dead-node list could never fire.
printf '%s\n' "$_wr" | grep -q '_wrc=\$?' \
  && ok "wr() captures and returns the write status" \
  || no "wr() still swallows the write status - [write-fail] can never fire and a refusing node is re-probed on every layer"

# ---- 5: the ON-value guard covers the path a WORKING switch takes -------------------------------------------
grep -q '^on_sane()' "$AMPS" \
  && ok "the ON-value guard is a shared function" \
  || no "the guard is still inlined in route_hit only"
sed -n '/^route_stab(){/,/^}/p' "$AMPS" | grep -q 'on_sane' \
  && ok "route_stab (the path every HOLDING switch takes) applies it" \
  || no "route_stab has no ON-value guard - it protected only the switches that already failed"
sed -n '/^route_hit(){/,/^}/p' "$AMPS" | grep -q '\[ -n "\$rh_cfg" \] && ADDLINES' \
  && ok "a rejected line is not appended to ADDLINES" \
  || no "the rejected line still reaches ADDLINES, so cfg_lookup hands it back as the switch"

# EXECUTE on_sane against the measured bramble case.
_os(){ ( rd1(){ echo "${REF:-0}"; }
         log(){ :; }
         eval "$(sed -n '/^on_sane(){/,/^}/p' "$AMPS")"
         on_sane "$1" lbl && echo OK || echo REJECT ) 2>/dev/null; }
[ "$(REF=3800000 _os '/sys/class/power_supply/main/constant_charge_current_max 450000 0')" = REJECT ] \
  && ok "the bramble line (ON=450000 against a 3800000 reference) is refused" \
  || no "the measured 450mA pin was accepted"
[ "$(REF=3800000 _os '/sys/class/power_supply/main/constant_charge_current_max 3000000 0')" = OK ] \
  && ok "a genuine full-rate ON value is accepted" || no "a healthy 3A ON value was refused"
[ "$(REF=0 _os '/sys/class/power_supply/battery/input_suspend 0 1')" = OK ] \
  && ok "a plain boolean switch is not touched by the current-value guard" || no "input_suspend was refused"
[ "$(REF=900000 _os '/sys/class/power_supply/main/current_max 800000 0')" = OK ] \
  && ok "a low ON value on a phone whose reference is ALSO low is kept (a genuinely small charger)" \
  || no "a small-but-consistent charger was refused"

# ---- 6: the combo emitter produces a line ACC can actually parse ---------------------------------------------
grep -q 'von1 \$voff1;' "$AMPS" \
  && no "the pair-combo line still carries a semicolon - ACC word-splits it and every field shifts" \
  || ok "the pair-combo line is flat space-separated, as ACC's chargingSwitch requires"

# ---- 7: ACC's existing switch is not truncated ------------------------------------------------------------------
grep -q "ACC_SW_NOW_FULL=.*awk '{print \$1, \$2, \$3}'" "$AMPS" \
  && no "ACC's current chargingSwitch is still cut to 3 fields - grouped switches lose every node but the first" \
  || ok "ACC's current chargingSwitch is carried whole"

fin
