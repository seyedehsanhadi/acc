#!/system/bin/sh
# t73 - `acc -t` must not wait forever, and must say which situation it is in.
#
# THE DEFECT. The wait before the switch test was:
#     not_charging && { print_unplugged; while not_charging; do sleep 1; set +x; done; }
# One line of advice, then a spin on not_charging every second with no timeout, no further output
# and no exit but Ctrl-C. Reported by a user as "acc -t doesn't auto-advance".
#
# not_charging is decided from the charging STATUS, and a phone sitting AT its charge limit reads
# "Not charging" and keeps reading it until the pack drains to the resume level -- on a firmware
# limit phone, hours. So the command hung, and the single line it had printed ("Ensure the charger
# is plugged") was itself wrong, because the charger was plugged in the whole time.
#
# AND THE FIRST FIX FOR IT WAS WRONG TOO. It called present(), which resolves its node list against
# the daemon's working directory. `acc -t` never sets one, so present() returned false on a plugged
# phone and printed the very message the fix existed to stop printing. Measured on a Pixel 6a.
#
# NO HARDWARE for the logic; the plugged probe is executed against real sysfs.

ID=t73
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AC=$execDir/acc.sh
[ -f "$AC" ] || AC=/data/local/tmp/stage-acc.sh
[ -f "$AC" ] || { no "acc.sh not found"; fin; }

BLOCK=$(sed -n '/not_charging && {/,/eval "\${_logOn:-:}"/p' "$AC")
[ -n "$BLOCK" ] || { no "could not lift the acc -t wait block"; fin; }

# ---- 1: the wait is bounded ---------------------------------------------------------------------
printf '%s\n' "$BLOCK" | grep -q '_twmax' \
  && ok "the wait has a ceiling" \
  || no "the wait is still unbounded - the command can never return on a phone held at its limit"
printf '%s\n' "$BLOCK" | grep -q 'exit \$exitCode_' \
  && ok "it exits rather than spinning once the ceiling is reached" \
  || no "reaching the ceiling does not exit"

# ---- 2: it keeps telling the user it is alive ----------------------------------------------------
printf '%s\n' "$BLOCK" | grep -q 'still waiting for charging to start' \
  && ok "it reports progress while waiting, so it cannot look hung" \
  || no "no progress output - a bounded wait that prints nothing still reads as a hang"

# ---- 3: the two situations get different messages -------------------------------------------------
printf '%s\n' "$BLOCK" | grep -q 'Charger is plugged in, but the battery is not taking charge' \
  && ok "a plugged phone that is not charging is told the truth about why" \
  || no "a plugged phone still gets 'ensure the charger is plugged'"
printf '%s\n' "$BLOCK" | grep -q 'print_unplugged' \
  && ok "a genuinely unplugged phone still gets the plug-in message" \
  || no "the unplugged case lost its message"

# ---- 4: the plugged probe does NOT depend on the daemon's working directory -------------------------
printf '%s\n' "$BLOCK" | grep -q '_t_plugged' \
  && ok "the wait uses its own plugged probe" \
  || no "still calling present(), which needs a working directory acc -t never sets"
_pp=$(sed -n '/_t_plugged() {/,/^ *}$/p' "$AC" | sed -n '1,12p')
printf '%s\n' "$_pp" | grep -q '/sys/class/power_supply/' \
  && ok "that probe reads absolute paths" \
  || no "the probe uses relative paths and will misreport outside the daemon"

# ---- 4b: the OPENING message is gated too -----------------------------------------------------------
# The line the user actually saw came from an unconditional print_unplugged before the wait, so
# `acc -t` told every user to plug in a charger that was already plugged in.
grep -q '_t_plugged || print_unplugged' "$AC" \
  && ok "the opening 'ensure the charger is plugged' only prints when the phone is not plugged" \
  || no "acc -t still opens by telling a plugged-in user to plug in"
_np=$(grep -c '^    print_unplugged$' "$AC")
[ "${_np:-1}" -eq 0 ] \
  && ok "no unconditional print_unplugged remains in the -t path" \
  || no "$_np unconditional print_unplugged call(s) still there"

# ---- 5: EXECUTE the probe here, against this phone's real sysfs --------------------------------------
# The whole point is that it answers correctly in a context with no working directory set, so run it
# from one: cd somewhere that has no power_supply nodes under it.
_r=$( cd / 2>/dev/null
      eval "$(sed -n '/_t_plugged() {/,/^ *}$/p' "$AC" | sed -n '1,12p')"
      _t_plugged && echo PLUGGED || echo UNPLUGGED )
_truth=UNPLUGGED
for _f in /sys/class/power_supply/*/online; do
  case "$_f" in */battery/*|*/bms/*) continue;; esac
  [ -f "$_f" ] || continue
  read -r _v < "$_f" 2>/dev/null || continue
  [ "$_v" = 1 ] && { _truth=PLUGGED; break; }
done
[ "$_r" = "$_truth" ] \
  && ok "the probe agrees with this phone's own supplies from an unrelated directory ($_r)" \
  || no "probe said $_r, the supplies say $_truth"

# ---- 6: the ceiling is overridable, so this can be tested without waiting three minutes -------------
printf '%s\n' "$BLOCK" | grep -q 'ACC_T_WAIT' \
  && ok "the ceiling can be overridden for testing" \
  || no "no override - the timeout path can only be exercised by waiting it out"

# ---- 7: EXECUTE the wait loop's control flow with a stubbed not_charging -----------------------------
# Never charging, ceiling 3s: it must give up, not spin.
_r=$( ( exitCode_=10
        print_unplugged(){ echo "PLUGMSG"; }
        _t_plugged(){ return 1; }
        not_charging(){ return 0; }
        _tw=0; _twmax=3
        while not_charging; do
          [ "$_tw" = 0 ] && _t_plugged && echo "HELDMSG" || { [ "$_tw" = 0 ] && print_unplugged; }
          if [ "$_tw" -ge "$_twmax" ] 2>/dev/null; then echo "GAVE-UP-AT-$_tw"; exit $exitCode_; fi
          sleep 1; _tw=$(( _tw + 1 ))
        done
        echo "ADVANCED" ) 2>&1 )
case "$_r" in
  *GAVE-UP-AT-3*) ok "a phone that never starts charging gives up at the ceiling instead of spinning" ;;
  *)              no "the loop did not terminate: [$_r]" ;;
esac
case "$_r" in
  *PLUGMSG*) ok "and it printed the unplugged message for the unplugged case" ;;
  *)         no "no message for the unplugged case: [$_r]" ;;
esac

# ---- 8: charging starting mid-wait still advances normally --------------------------------------------
_r=$( ( exitCode_=10
        print_unplugged(){ :; }
        _t_plugged(){ return 0; }
        _n=0
        not_charging(){ _n=$(( _n + 1 )); [ "$_n" -le 2 ]; }
        _tw=0; _twmax=60
        while not_charging; do
          [ "$_tw" -ge "$_twmax" ] 2>/dev/null && { echo "WRONGLY-GAVE-UP"; exit $exitCode_; }
          sleep 1; _tw=$(( _tw + 1 ))
        done
        echo "ADVANCED-after-${_tw}s" ) 2>&1 )
case "$_r" in
  *ADVANCED-after-2s*) ok "charging starting during the wait advances immediately, as before" ;;
  *)                   no "the normal path changed: [$_r]" ;;
esac

# ---- 9: the three causes of the lost daemon, asserted on the source -----------------------------------
# This suite covered the WAIT and never the DAEMON LOSS, which is the half users actually hit. The
# gap showed up in an A/B: removing `trap '' PIPE` was caught only incidentally, by an unrelated
# suite reacting to a line-number shift. A fix nothing asserts is a fix nobody can defend.
AC=$execDir/acc.sh
[ -f "$AC" ] || { no "acc.sh not found at $AC"; fin; }

# (a) SIGPIPE. `acc -t | head` and `acc -t | less` then q kill the process on a closed pipe. The
# cleanup trap covered EXIT INT TERM HUP and not PIPE, so it exited without restoring the daemon.
grep -q "trap '' PIPE" "$AC" \
  && ok "acc -t ignores SIGPIPE, so a closed pipe cannot kill it before cleanup" \
  || no "no PIPE trap - 'acc -t | head' exits without restoring the daemon"
_p=$(grep -n "trap '' PIPE" "$AC" | head -1 | cut -d: -f1)
_s=$(grep -n 'daemon_ctrl stop > /dev/null && daemonWasUp' "$AC" | head -1 | cut -d: -f1)
{ [ -n "$_p" ] && [ -n "$_s" ] && [ "$_p" -lt "$_s" ]; } 2>/dev/null \
  && ok "  and it is ignored BEFORE the daemon is stopped ($_p < $_s)" \
  || no "  the PIPE trap at ${_p:-?} comes after the stop at ${_s:-?} - the window is still open"

# (b) trap ordering. The cleanup was armed after daemon_ctrl stop had already run, so an interrupt
# in that window left nothing to put the daemon back.
_o=$(grep -n 'trap exxit EXIT' "$AC" | head -1 | cut -d: -f1)
{ [ -n "$_o" ] && [ -n "$_s" ] && [ "$_o" -lt "$_s" ]; } 2>/dev/null \
  && ok "the cleanup trap is armed before the daemon is stopped ($_o < $_s)" \
  || no "cleanup armed at ${_o:-?} but the daemon is stopped at ${_s:-?} - an interrupt there loses it"
case "$(sed -n "${_o}p" "$AC")" in
  *INT*TERM*HUP*) ok "  and it covers INT, TERM and HUP" ;;
  *)              no "  the trap no longer covers INT/TERM/HUP" ;;
esac

# (c) the restore must call something that EXISTS. start-stop-daemon is a Debian/busybox tool and
# returned 127 on both test phones, so acc -t had never restored the daemon on any phone lacking it.
_rl=$(sed -n '/if \$daemonWasUp; then/,/^      fi$/p' "$AC")
# Assert the INVOCATION, not the word. `grep -q setsid` passed on a mutated copy where the launcher
# had been swapped back to start-stop-daemon, because `command -v setsid` still sat in the `if`
# condition two lines above. The assertion could not fail for the defect it exists to catch, and the
# A/B only caught that mutation 34 suites later, by accident, in an unrelated suite.
printf '%s' "$_rl" | grep -qE 'setsid[[:space:]]+\$TMPDIR/\.accdt' \
  && ok "the daemon is restored by setsid ITSELF launching .accdt, not merely mentioned" \
  || no "setsid is not what launches the daemon - the restore runs something else"
printf '%s' "$_rl" | grep -q 'command -v start-stop-daemon' \
  && ok "  start-stop-daemon is only used behind a command -v guard" \
  || { printf '%s' "$_rl" | grep -q 'start-stop-daemon' \
       && no "  start-stop-daemon is called unguarded - it does not exist on Android (127)" \
       || ok "  start-stop-daemon is not called at all"; }
printf '%s' "$_rl" | grep -q '</dev/null >/dev/null 2>&1' \
  && ok "  and the restored daemon does not inherit acc -t's stdio" \
  || no "  the restored daemon keeps the caller's stdio - a closed pipe kills it"
printf '%s' "$_rl" | grep -qi 'UNCAPPED' \
  && ok "a restore that fails says so instead of exiting quietly" \
  || no "a failed restore is silent - the user is left uncapped with no message"

fin
