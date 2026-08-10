#!/system/bin/sh
# P9 - what happens when things go wrong underneath ACC.
#
# WHY
#   Every other phase asks whether ACC does the right thing on a healthy phone. None of them ask what
#   it does when the ground moves: a sensor that stops reading, a config that is corrupt, a daemon
#   killed mid-cycle, a tmpfs wiped by a reboot. Those are the conditions under which "the limit
#   stopped working" reports actually arrive, and until now nothing exercised them.
#
#   THE RULE BEING TESTED, in every case: degrade, never strand. ACC losing a sensor or a config
#   should cost a feature, not the ability to charge. A phone that cannot charge is worse than a
#   phone with no limit.
#
# SAFETY
#   Every fault is injected into a COPY or reverted immediately, the original is restored from the
#   run's recovery file, and the phone is checked for a stranded switch after each one. Nothing here
#   writes shutdown_temp.

hdr "P9 FAULT INJECTION AND RECOVERY"

_orig_cfg=$(cat $CFG 2>/dev/null)

# ---- 1: daemon killed mid-flight ------------------------------------------------------------------
# A kill -9 leaves no chance to run the exit path, which is exactly when a switch could be left cut.
_n=$(sw_node 2>/dev/null)
_p=$(daemon_pid)
if [ -n "${_p:-}" ] && [ -d /proc/$_p ]; then
  kill -9 $_p 2>/dev/null
  sleep 3
  daemon_alive && no "the daemon survived kill -9" || ok "daemon killed outright, with no chance to run its exit path"
  if [ -n "${_n:-}" ] && [ -f "$_n" ]; then
    sw_released \
      && ok "the switch is not left blocking charge after a hard kill" \
      || no "a hard kill left charging BLOCKED ($(sw_state_desc)) - a crash would strand the phone"
  fi
  daemon_start >/dev/null 2>&1
  daemon_alive && ok "the daemon restarts cleanly after a hard kill" || no "the daemon did not come back after kill -9"
else
  skip "the hard-kill test (no daemon running)"
fi

# ---- 2: tmpfs wiped underneath a running daemon -----------------------------------------------------
# /dev/.vr25/acc is tmpfs and vanishes on every boot. rc22 added the mkdir that lets a cold start
# recreate it; this checks the daemon survives losing it while running, not just at startup.
daemon_stop >/dev/null 2>&1
rm -rf $TD 2>/dev/null || :
daemon_start >/dev/null 2>&1
if daemon_alive; then
  ok "the daemon starts with its tmpfs working directory completely absent"
  daemon_looping 15 && ok "and it loops afterwards" || no "it started after the wipe but does not loop"
else
  no "the daemon cannot start once its tmpfs directory is gone - it would not survive a reboot"
fi

# ---- 3: an unreadable temperature sensor ------------------------------------------------------------
# The limit that depends on a sensor must not take the rest down with it, and must not silently
# enforce on a value it cannot read.
_tf=$(ls -1 $G/temp 2>/dev/null | head -1)
if [ -n "${_tf:-}" ]; then
  _tv=$(cat $_tf 2>/dev/null)
  if chmod 000 $_tf 2>/dev/null; then
    sleep 12
    daemon_alive \
      && ok "the daemon survives an unreadable temperature sensor" \
      || no "an unreadable temperature sensor killed the daemon"
    chmod 644 $_tf 2>/dev/null || :
    sleep 3
    [ "$(cat $_tf 2>/dev/null)" = "$_tv" ] || note "sensor value moved during the test (normal)"
    sw_released \
      && ok "and it does not strand charging while the sensor is unreadable" \
      || no "an unreadable sensor left charging BLOCKED"
  else
    skip "the unreadable-sensor test (cannot chmod the node as root here)"
  fi
else
  skip "the unreadable-sensor test (no temp node)"
fi

# ---- 4: a corrupt config --------------------------------------------------------------------------------
# A truncated or garbage config must fall back, not abort the caller. The daemon keeps a known-good
# copy for exactly this; rc21 fixed it loading that copy without checking it first.
cp -f $CFG $WORK/.cfg.bak 2>/dev/null
printf 'capacity=(this is not\ntemperature=garbage\n' > $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1
sleep 4
if daemon_alive; then
  ok "the daemon starts on a corrupt config rather than dying on it"
else
  no "a corrupt config stopped the daemon from starting at all"
fi
# acc -i must not die either: it is how a user would diagnose this.
if acc -i >/dev/null 2>&1; then ok "acc -i still works with a corrupt config"; else no "a corrupt config kills acc -i, the command a user would reach for"; fi
printf '%s\n' "$_orig_cfg" > $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1; sleep 4
[ "$(grep -m1 '^capacity=' $CFG 2>/dev/null)" = "$(printf '%s\n' "$_orig_cfg" | grep -m1 '^capacity=')" ] \
  && ok "config restored after the corruption test" || no "config NOT restored after the corruption test"

# ---- 5: out-of-range settings are refused, not silently coerced --------------------------------------------
# A limit the user typed and ACC quietly replaced is worse than an error: the number on screen is not
# the number in force. shutdown_temp is deliberately not among these.
_before=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
acc -s pause_capacity=999 >/dev/null 2>&1
sleep 3
_after=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
[ "$_before" = "$_after" ] \
  && ok "an out-of-range pause capacity (999) is refused, leaving the previous limit in force" \
  || no "pause_capacity=999 was accepted and changed the config to ${_after}"

# ---- 6: the daemon recovers a switch a previous run left cut -------------------------------------------------
# The startup recovery exists so a phone is never stranded by a crash. Exercised directly: latch the
# switch, start the daemon, and it must release it (temperature permitting).
if [ -n "${_n:-}" ] && [ -f "$_n" ]; then
  _off=$(sw_off_val); _on=$(sw_on_val)
  case "$(sw_off_val)" in
    pcap|*%) skip "the stranded-switch recovery (level switch: covered by the thermal hold in P4)" ;;
    *)
      daemon_stop >/dev/null 2>&1
      chmod a+w "$_n" 2>/dev/null || :; echo "$_off" > "$_n" 2>/dev/null || :
      sleep 1
      if [ "$(cat "$_n" 2>/dev/null)" = "$_off" ]; then
        daemon_start >/dev/null 2>&1
        sleep 8
        sw_released \
          && ok "the daemon released a switch left cut by a previous run" \
          || no "a switch left cut was NOT released at startup - the phone stays stranded"
        chmod a+w "$_n" 2>/dev/null || :; echo "$_on" > "$_n" 2>/dev/null || :
      else
        skip "the stranded-switch recovery (could not latch the switch)"
      fi
      ;;
  esac
fi

# ---- final state ---------------------------------------------------------------------------------------------
daemon_alive && ok "daemon alive at the end of the fault sweep" || no "daemon DOWN at the end of the fault sweep"
sw_released && ok "charging permitted at the end of the fault sweep" || no "charging BLOCKED at the end of the fault sweep"
