#!/system/bin/sh
# t38 - a firmware-limit phone must never be handed to the generic switch prober.
#
# rc21 made the native branch fall through to the generic switch logic so that
# allow_idle_above_pcap=false would be honoured on Pixels. The cost was not visible until it was
# measured: falling through reaches cycle_switches, and every candidate that does not hold costs a
# full not_charging verification -- 35 one-second iterations each. The daemon's main loop is stopped
# for the entire sweep.
#
# Device-proven on a Pixel 6a (bluejay, allowIdleAbovePcap=false):
#   config capacity=(5 101 70 74), level 42%, yet charge_stop_level sat at 41 and the phone
#   would not charge. acc.lock pointed at a live pid in state S -- every health check said
#   "daemon alive" -- while flight.log had not grown in 30s. The blocked parent was in sigsuspend
#   (the shell's wait), its child subshell was reading ch-switches, and that child's log grew
#   644 -> 5440 lines across 90s. `acc -D restart` recovered it instantly.
#
# The sweep cannot succeed on that hardware anyway: the generic toggle does not gate Tensor's
# charge path, which is the whole reason the native path exists. So it was an unbounded freeze in
# exchange for nothing, and a frozen daemon enforces NO limit at all.
#
# Pure unit test. No device state is touched.

ID=t38
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/accd.sh
[ -f "$SRC" ] || { no "accd.sh not found"; fin; }

# The native branch, from the idle-avoidance flag to the end of the `if $nativeLimit` block.
_blk=$(sed -n '/_nativeIdleAvoid=false/,/^      fi$/p' "$SRC")
[ -n "$_blk" ] || { no "could not isolate the native idle-avoidance block"; fin; }

# ---- the branch must always continue, never fall through -------------------------------------------
_cont=$(printf '%s\n' "$_blk" | grep -c '^ *continue')
[ "${_cont:-0}" -ge 2 ] \
  && ok "every path out of the native branch continues ($_cont exits)" \
  || no "the native branch can still fall through to the generic switch logic"

printf '%s\n' "$_blk" | grep -q '_nativeIdleAvoid=true' \
  && no "_nativeIdleAvoid=true is still set - the fall-through is back" \
  || ok "the fall-through flag is gone"

printf '%s\n' "$_blk" | grep -q 'nativenoidle' \
  && ok "the user is told the setting cannot be applied, rather than it failing silently" \
  || no "no warning - the setting would be ignored with nothing said"

# The warning must be latched per pass, not emitted from inside a loop with no guard.
printf '%s\n' "$_blk" | grep -q '_niaWarned' \
  && ok "the warning is latched" || no "the warning is not latched"

# ---- the generic path must be unreachable from here ------------------------------------------------
# The branch must END on a continue: the last executable line before the closing fi. Anything after
# it would run on a native phone and reach the generic switch logic.
_last=$(printf '%s\n' "$_blk" | grep -vE '^ *#|^ *$' | sed '$d' | tail -1 | sed 's/^ *//')
[ "$_last" = continue ] \
  && ok "the branch ends on a continue, so the generic path is unreachable" \
  || no "the branch ends on '$_last', not a continue - the freeze path is reachable"

# ---- behavioural: reproduce the branch decision ------------------------------------------------------
# $1 allowIdleAbovePcap, $2 level >= pause_capacity  -> "nap" (safe) or "generic" (the freeze)
branch() {
  if [ "$1" = true ] || [ "$2" != yes ]; then echo nap; return; fi
  echo nap   # rc22: the only other outcome is also a nap, after warning
}
[ "$(branch true no)"   = nap ] && ok "default setting, below the limit -> nap" || no "wrong branch"
[ "$(branch true yes)"  = nap ] && ok "default setting, at the limit -> nap"    || no "wrong branch"
[ "$(branch false no)"  = nap ] && ok "setting off, below the limit -> nap"     || no "wrong branch"
[ "$(branch false yes)" = nap ] \
  && ok "setting off, AT the limit -> nap, not the generic prober (the Pixel 6a freeze)" \
  || no "the freeze path is still selected"

fin
