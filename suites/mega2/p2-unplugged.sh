#!/system/bin/sh
# P2 - unplugged behaviour. Everything that can be proven with the cable out.
#
# Most of ACC's dangerous failure modes are visible here, because "unplugged" is when the daemon is
# supposed to be doing nothing at all. Anything it writes, cuts, or spins on with no charger attached
# is either a bug or a battery cost the user never agreed to.

hdr "P2 UNPLUGGED BEHAVIOUR"

plugged && { no "cable attached - P2 cannot run"; return 0 2>/dev/null || exit 0; }

# ---- 1: the daemon is alive AND advancing ---------------------------------------------------------
daemon_looping 25 \
  && ok "daemon advances over 25s unplugged" \
  || no "daemon did not advance - wedged, or dead behind a live-looking lock"

# ---- 2: an idle phone is a SILENT phone -------------------------------------------------------------
# rc14/rc19 made every node write idempotent. With no cable there is nothing to enforce, so a healthy
# daemon writes nothing at all. Any write here is churn: it costs battery and, on Tensor, re-triggers
# the charger state machine.
_a=$(ledger_lines)
sleep 60
_b=$(ledger_lines)
_d=$(( ${_b:-0} - ${_a:-0} ))
[ "${_d:-0}" -eq 0 ] \
  && ok "60s idle produced ZERO node writes" \
  || { no "${_d} node write(s) while idle and unplugged - churn the user pays for"; tail -n "$_d" $LEDGER 2>/dev/null | sed 's/^/        /'; }

# ---- 3: nothing is left cut --------------------------------------------------------------------------
# Checked by switch CLASS: a level switch (charge_stop_level 100 pcap) rests at pause_capacity for as
# long as the limit is enforced, which is not a cut. See sw_released in lib.sh.
note "$(sw_state_desc)"
sw_released \
  && ok "charging is permitted by the switch with no cable attached" \
  || no "the switch is BLOCKING charge with no cable ($(sw_state_desc)) - it will not charge when plugged"
_n=$(sw_node 2>/dev/null); _on=$(sw_on_val)

# ---- 4: the release must not depend on the cable -------------------------------------------------------
# This is the rc22 root-cause fix, exercised live rather than by reading source. Measured failure it
# guards: `acc -e` on an unplugged A3 printed "Charging enabled", exited 0, wrote nothing, and left
# input_suspend=1 - the phone could not charge until a reboot.
#
# BINARY switches only. A level switch's OFF value is the token `pcap`, and writing that string to
# charge_stop_level would either be rejected or land as garbage in a node that governs charging. The
# equivalent path for firmware-limit phones is exercised in P4, where a real thermal hold moves the
# level pair and it can be observed without inventing a value to write.
_isbin=no
case "$(sw_off_val)" in pcap|*%) : ;; *) _isbin=yes ;; esac
if [ "$_isbin" != yes ]; then
  skip "the live release test (this phone uses a level switch; covered by the thermal hold in P4)"
elif [ -n "${_n:-}" ] && [ -f "$_n" ]; then
  _off=$(sw_off_val)
  if [ -n "${_off:-}" ]; then
    daemon_stop >/dev/null 2>&1
    chmod a+w "$_n" 2>/dev/null || :
    echo "$_off" > "$_n" 2>/dev/null || :
    sleep 1
    if [ "$(cat "$_n" 2>/dev/null)" = "$_off" ]; then
      acc -e >/dev/null 2>&1
      sleep 2
      _after=$(cat "$_n" 2>/dev/null)
      if [ "${_after:-}" = "${_on:-}" ]; then
        ok "acc -e released a latched switch with the cable OUT (the rc22 fix, live)"
      else
        no "acc -e did NOT release the latched switch (still $_after) - phone would not charge on next plug"
        # Do not leave it cut whatever the verdict.
        chmod a+w "$_n" 2>/dev/null || :; echo "$_on" > "$_n" 2>/dev/null || :
      fi
      # And the write must be recorded: an unlogged write is why this bug hid for so long.
      grep -q "$(basename $_n)" $LEDGER 2>/dev/null \
        && ok "and the release is recorded in the write ledger" \
        || no "the release happened but was never ledgered - invisible to anyone debugging it"
    else
      skip "could not latch the switch to test the release"
    fi
    daemon_start >/dev/null 2>&1
    sleep 4
  fi
fi

# ---- 5: charge direction with no charger ------------------------------------------------------------------
# Both phones have reported "Charging" while unplugged, with OPPOSITE current signs and opposite cached
# polarity - three independent arbiters agreeing on the wrong answer. present() is the physical fact and
# must be the last word.
_ks=$(kstat)
case "$_ks" in
  Discharging|Not?charging|Unknown) ok "kernel status is '${_ks}' with no cable, as expected" ;;
  Charging|Full) no "kernel reports '${_ks}' with NO CABLE - the direction arbiter is being lied to" ;;
  *) note "kernel status: ${_ks}" ;;
esac

if command -v acc >/dev/null 2>&1; then
  _ai=$(acc -i 2>/dev/null | head -20)
  case "$_ai" in
    *Charging*) printf '%s' "$_ai" | grep -qE 'Not charging|Discharging' \
                  && ok "acc -i does not claim to be charging while unplugged" \
                  || no "acc -i reports Charging with no cable" ;;
    *) ok "acc -i does not claim to be charging while unplugged" ;;
  esac
fi

# ---- 6: cold bootstrap of the tmpfs working directory --------------------------------------------------------
# /dev/.vr25/acc is tmpfs and is wiped on every boot. A daemon that cannot recreate it dies at the lock
# with exit 13 and never starts - measured, and the reason rc22 added `mkdir -p $TMPDIR`.
daemon_stop >/dev/null 2>&1
rm -rf $TD 2>/dev/null || :
daemon_start >/dev/null 2>&1
sleep 6
if daemon_alive; then
  ok "daemon self-bootstrapped its tmpfs working directory after a full wipe"
  daemon_looping 15 && ok "and it is looping after the cold start" || no "started after wipe but is not looping"
else
  no "daemon could NOT start after its tmpfs directory was wiped - it would not survive a reboot"
fi

# ---- 7: config survives a daemon restart ------------------------------------------------------------------------
_c1=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
_t1=$(grep -m1 '^temperature=' $CFG 2>/dev/null)
_s1=$(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null)
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1
_c2=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
_t2=$(grep -m1 '^temperature=' $CFG 2>/dev/null)
_s2=$(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null)
[ "$_c1" = "$_c2" ] && ok "capacity survived a daemon restart" || no "capacity changed across restart: $_c1 -> $_c2"
[ "$_t1" = "$_t2" ] && ok "temperature survived a daemon restart" || no "temperature changed across restart: $_t1 -> $_t2"
[ "$_s1" = "$_s2" ] && ok "charging switch survived a daemon restart" || no "switch changed across restart: $_s1 -> $_s2"

# ---- 8: a low max_temp must LAND, not be silently rewritten -------------------------------------------------------
# write-config once reverted a valid low max_temp (40 -> 50) and crushed a wide resume hysteresis. A
# limit the user sets and the daemon ignores is the worst possible outcome for a thermal control.
# shutdown_temp is NEVER touched here.
_orig_t=$(grep -m1 '^temperature=' $CFG 2>/dev/null)
acc -s cooldown_temp=33 max_temp=34 resume_temp=32 >/dev/null 2>&1
sleep 4
_m=$(grep -m1 '^temperature=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//' | cut -d' ' -f2)
[ "${_m:-}" = 34 ] \
  && ok "a low max_temp (34) lands in config and is not silently raised" \
  || no "max_temp was rewritten to ${_m} instead of 34 - the user's limit is being ignored"
_st=$(grep -m1 '^temperature=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//' | cut -d' ' -f4)
[ "${_st:-}" = "$(printf '%s' "$_orig_t" | sed 's/.*(//;s/).*//' | cut -d' ' -f4)" ] \
  && ok "shutdown_temp was not altered as a side effect" \
  || no "shutdown_temp changed as a side effect of setting max_temp"
# put it straight back
cp -f $RECOVER.config $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1
sleep 4
_back=$(grep -m1 '^temperature=' $CFG 2>/dev/null)
[ "$_back" = "$_orig_t" ] && ok "temperature restored after the test" || no "temperature NOT restored: $_back"
