#!/system/bin/sh
# t70 - the firmware pause must not cost the phone its charge speed.
#
# THE DEFECT
#   Google's charge_stop_level pause works by zeroing the charger's input-current votes. On resume
#   the firmware re-arms them to the USB default and never back to what it had negotiated. Measured
#   on a Pixel 6a across one ordinary ACC pause/resume, charger INPUT side (so screen load cannot
#   confound it):
#       before pause   main-charger/current_max 3200000   input 1418750 uA
#       held           main-charger/current_max       0
#       after resume   main-charger/current_max  500000   input  478625 uA
#   and it stayed there until the cable was physically pulled. A phone that reaches its limit once
#   charges at a third of its speed for the rest of that plug.
#
# THE TWO WAYS THE FIX ITSELF CAN GO WRONG, both hit on hardware and both covered below.
#
#   1. WRITING THE WRONG NODE. usb/current_max, tcpm*, pc_port carry the NEGOTIATED contract, not a
#      vote. One write to usb/current_max on bluejay dropped the port to 100000 - 100 mA,
#      unconfigured - and charging stopped until it was written back by hand. The allow-list is the
#      fix and case 1 is what keeps it narrow.
#
#   2. TRUSTING battery/status. bluejay reads "Not charging" for a sample at a time while charging
#      perfectly normally. Keyed on status, the restore fired on nearly every loop. The pause is
#      detected by the vote READING ZERO, which is the firmware's own signature and does not flap.
#
# NO HARDWARE. Source-level for the discovery block, executed with fake sysfs for the function.

ID=t70
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }

W=${TMPDIR:-/data/local/tmp}/t70.$$
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null
trap 'rm -rf "$W" 2>/dev/null' EXIT

FN=$(sed -n '/^  native_icl_restore() *{/,/^  }/p' "$AD")
[ -n "$FN" ] || { no "native_icl_restore() not found in accd.sh"; fin; }

# ---- 1: the discovery allow-list never reaches the negotiated-contract supplies -------------------
_disc=$(sed -n '/_iclNodes=$/,/^  done/p' "$AD")
if [ -z "$_disc" ]; then
  no "could not find the _iclNodes discovery block"
else
  _bad=
  for _n in usb tcpm pc_port dc wireless battery; do
    printf '%s' "$_disc" | grep -qE "(^|[^a-z_-])$_n[)|]" && _bad="$_bad $_n"
  done
  [ -z "$_bad" ] \
    && ok "the allow-list admits no contract/wireless/battery supply" \
    || no "the allow-list admits:$_bad - writing one of those renegotiates the port to 100 mA"
  printf '%s' "$_disc" | grep -q 'main-charger' \
    && ok "the allow-list includes main-charger, the vote that actually gates the pack" \
    || no "main-charger is not in the allow-list, so the measured node is never restored"
  printf '%s' "$_disc" | grep -q 'input_current_limit' \
    && no "input_current_limit is still collected - it lives on usb on every phone seen" \
    || ok "only current_max is collected"
fi

# ---- the fake sysfs harness ---------------------------------------------------------------------
# One charger vote node. run() drives one loop pass and reports what the function wrote.
#
# The daemon keeps its memory in shell variables that live across loop passes, so the harness has to
# as well. It cannot: each pass runs in a subshell (the function has to be eval'd somewhere it can be
# stubbed) and a subshell's variables never come back. The first version of this test read SAVE/HELD
# straight after the call and got the caller's stale copy every time - four green cases that were
# measuring nothing. The memory is carried in files instead, which is what a subshell cannot lose.
NODE=$W/main-charger.current_max
STAT=$W/status
: > $W/save; echo 0 > $W/held
sv(){ cat $W/save 2>/dev/null; }
hd(){ cat $W/held 2>/dev/null; }
mem(){ printf '%s' "${1-}" > $W/save; printf '%s' "${2:-0}" > $W/held; }
run() {  # $1 present(0=yes) $2 vote $3 status  -> prints the vote after the pass
  printf '%s\n' "$2" > "$NODE"; printf '%s\n' "$3" > "$STAT"
  ( eval "$FN"
    _iclNodes=$NODE
    battStatus=$STAT
    _iclSave=$(cat $W/save 2>/dev/null)
    _iclHeld=$(cat $W/held 2>/dev/null)
    _pres=$1                        # bind BEFORE the stub: inside present(), $1 is present's own arg
    present(){ return $_pres; }
    _wlog(){ :; }
    native_icl_restore
    printf '%s' "${_iclSave-}" > $W/save
    printf '%s' "${_iclHeld:-0}" > $W/held ) 2>/dev/null
  read -r _v < "$NODE"; echo "$_v"
}

# ---- 2: unplugged is free and forgets ------------------------------------------------------------
mem "$NODE=3200000" 1
_v=$(run 1 500000 Discharging)
[ "$_v" = 500000 ] && [ -z "$(sv)" ] && [ "$(hd)" = 0 ] \
  && ok "unplugged: no write, and the remembered ceiling is forgotten" \
  || no "unplugged left vote=$_v save=[$(sv)] held=$(hd) - a strong charger's ceiling must not survive the unplug"

# ---- 3: charging normally learns and writes nothing ----------------------------------------------
mem "" 0
_v=$(run 0 3200000 Charging)
[ "$_v" = 3200000 ] && [ "$(sv)" = " $NODE=3200000" ] \
  && ok "charging: learns 3200000, writes nothing" \
  || no "charging pass wrote vote=$_v / learned [$(sv)]"

# ---- 4: a zeroed vote is the pause, and is only remembered, never written ------------------------
_v=$(run 0 0 "Not charging")
[ "$_v" = 0 ] && [ "$(hd)" = 1 ] \
  && ok "a zeroed vote marks the hold and is not written to" \
  || no "the hold pass wrote vote=$_v held=$(hd)"

# ---- 5: THE FIX - resume at a lower value restores the remembered one ----------------------------
_v=$(run 0 500000 Charging)
[ "$_v" = 3200000 ] \
  && ok "resume at 500000 restored to 3200000 (the shipped bug, fixed)" \
  || no "resume left the vote at $_v - the phone would charge at a third of its speed"

# ---- 6: once, not every loop --------------------------------------------------------------------
_v=$(run 0 500000 Charging)
[ "$_v" = 500000 ] \
  && ok "a later drop is left alone: one restore per pause, so a thermal throttle is never fought" \
  || no "the function wrote again outside a pause cycle (vote=$_v) - that is fighting the charger"

# ---- 7: never lowers ------------------------------------------------------------------------------
mem "$NODE=500000" 1
_v=$(run 0 3200000 Charging)
[ "$_v" = 3200000 ] \
  && ok "a resume ABOVE the remembered value is left alone - the restore only ever raises" \
  || no "the function lowered the vote to $_v"

# ---- 8: a status flap is not a pause --------------------------------------------------------------
mem "" 0
run 0 3200000 Charging >/dev/null            # learn
run 0 3200000 "Not charging" >/dev/null        # the flap: vote never zeroed
_v=$(run 0 500000 Charging)
[ "$_v" = 500000 ] \
  && ok "a status flap with a live vote is not treated as a pause (no write)" \
  || no "a status flap triggered a restore (vote=$_v) - this is what took bluejay off the charger"

# ---- 8b: the deadlock - a resume too weak to charge must STILL be restored -------------------------
# The firmware does not always release to 500000. Measured on bluejay it released to 100000, and
# 100 mA against a live screen leaves the pack draining, so battery/status never returns to
# "Charging". A restore that waits for "Charging" is waiting for the thing it exists to fix, and
# the phone sits on the cable losing charge: vote 100000, charger input 95 mA, pack -130 mA, for
# the whole 96s window it was watched.
mem "" 0
run 0 3200000 Charging >/dev/null
run 0 0 "Not charging" >/dev/null
_v=$(run 0 100000 "Not charging")
[ "$_v" = 3200000 ] \
  && ok "a resume at 100000 that still reads Not charging is restored anyway (the deadlock)" \
  || no "vote left at $_v because the phone was not 'Charging' - that is the deadlock, the phone drains on the cable"

# ---- 9: unplug during the hold forgets, so a weaker charger is never pinned -----------------------
mem "" 0
run 0 3200000 Charging >/dev/null            # strong charger
run 0 0 "Not charging" >/dev/null              # pause
run 1 0 Discharging >/dev/null                 # cable out
_v=$(run 0 500000 Charging)                    # weak charger plugged in
[ "$_v" = 500000 ] \
  && ok "the 3200000 ceiling is not pinned onto a weaker charger plugged in later" \
  || no "a weak charger was forced to $_v carried over from a previous plug"

# ---- 9b: a blacklisted node is never written ------------------------------------------------------
# This restores a remembered vote, not a configured switch, so it writes with a raw echo and never
# passes through write() -- which is exactly how it slipped past the blocked list. rc21 closed that
# same hole twice in this file. It matters more here than usual: AMPS shares this list (its BLF is
# $dataDir/.acc-compat-blacklist, the file sw_blacklisted reads), so a node AMPS blacklisted after
# it took a phone down would be refused by every other writer in the module and written by this one.
mem "$NODE=3200000" 1
_v=$( ( eval "$FN"
        _iclNodes=$NODE
        battStatus=$STAT
        _iclSave=$(cat $W/save 2>/dev/null)
        _iclHeld=1
        _pres=0
        present(){ return $_pres; }
        _wlog(){ :; }
        warn_once_per(){ :; }
        sw_blacklisted(){ return 0; }        # this node is on the blocked list
        printf '500000\n' > "$NODE"; printf 'Charging\n' > "$STAT"
        native_icl_restore
        read -r _x < "$NODE"; echo "$_x" ) 2>/dev/null )
[ "$_v" = 500000 ] \
  && ok "a blacklisted node is left alone - slower charging is not worth re-writing a node that downed a phone" \
  || no "wrote $_v to a blacklisted node - the same bypass rc21 closed twice"

# and the guard must not block a node that is NOT listed
mem "$NODE=3200000" 1
_v=$( ( eval "$FN"
        _iclNodes=$NODE
        battStatus=$STAT
        _iclSave=$(cat $W/save 2>/dev/null)
        _iclHeld=1
        _pres=0
        present(){ return $_pres; }
        _wlog(){ :; }
        warn_once_per(){ :; }
        sw_blacklisted(){ return 1; }        # not listed
        printf '500000\n' > "$NODE"; printf 'Charging\n' > "$STAT"
        native_icl_restore
        read -r _x < "$NODE"; echo "$_x" ) 2>/dev/null )
[ "$_v" = 3200000 ] \
  && ok "an unlisted node is still restored, so the guard is a filter and not an off switch" \
  || no "an unlisted node was not restored (got $_v)"

# source-level: the guard exists and precedes the write
_fnsrc=$(printf '%s' "$FN")
_gl=$(printf '%s\n' "$_fnsrc" | grep -n 'sw_blacklisted' | head -1 | cut -d: -f1)
_wl=$(printf '%s\n' "$_fnsrc" | grep -n 'echo "\$v" > "\$n"' | head -1 | cut -d: -f1)
if [ -n "$_gl" ] && [ -n "$_wl" ]; then
  [ "$_gl" -lt "$_wl" ] 2>/dev/null \
    && ok "the blacklist check precedes the write" \
    || no "the blacklist check sits after the write"
else
  no "could not locate the blacklist guard ($_gl) and the write ($_wl)"
fi

# ---- 10: it is actually called, on the native path ------------------------------------------------
_src=$(sed 's/^[[:space:]]*#.*//' "$AD")
# ---- the ceiling must survive a daemon restart that happens WHILE the phone is held --------------
# The memory lived only in a shell variable, so a daemon started while the phone was already at its
# firmware limit began with an empty _iclSave. The held branch returns before the learn loop, so on
# resume there was nothing to restore; the learn loop at the bottom then recorded the COLLAPSED value
# as the ceiling, and every later cycle in that plug restored to the collapsed figure. One AccA config
# edit, `acc -D restart` or `acc -t` at the limit is enough to trigger it.
#
# Restarting is simulated the only honest way: wipe the in-memory pair, exactly as a fresh process
# would have them, and leave whatever the implementation persisted for itself.
rm -f ${TMPDIR:-/data/local/tmp}/.icl-save 2>/dev/null   # start clean, or an earlier case could carry it
mem "" 0
_v=$(run 0 3200000 Charging)                 # process A sees a healthy ceiling and remembers it
_learned=$(sv)
: > $W/save; echo 0 > $W/held                # <-- process A dies here; B starts with nothing in RAM
_v=$(run 0 0 "Not charging")                 # B's first pass: already held
_v=$(run 0 500000 Charging)                  # firmware resumes it low
if [ "$_v" = 3200000 ]; then
  ok "a daemon restarted while held still restores the ceiling (3200000), so one config edit at the limit no longer costs the rest of the plug"
else
  no "restarted-while-held restored nothing: vote left at ${_v} against the 3200000 learned before the restart - and the collapsed value is now remembered as the ceiling"
fi
printf '%s' "$_learned" | grep -q '3200000' \
  && ok "the pre-restart pass did learn 3200000, so the case above is testing persistence and not a learn failure" \
  || no "the pre-restart pass never learned a ceiling - this case proves nothing"

printf '%s' "$_src" | grep -q 'native_icl_restore || :' \
  && ok "the native branch calls it" \
  || no "native_icl_restore is defined but never called - the fix would be dead code"
_c=$(printf '%s' "$_src" | grep -n 'native_icl_restore || :' | head -1 | cut -d: -f1)
_u=$(printf '%s' "$_src" | grep -n 'native_unlatch || :' | head -1 | cut -d: -f1)
if [ -n "${_c:-}" ] && [ -n "${_u:-}" ]; then
  [ "$_u" -lt "$_c" ] 2>/dev/null \
    && ok "it runs after native_unlatch, so the re-arm has already happened" \
    || no "it runs before native_unlatch - it would sample a vote the firmware has not restored yet"
else
  no "could not locate both call sites on the native path"
fi

fin
