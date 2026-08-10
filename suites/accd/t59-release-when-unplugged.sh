#!/system/bin/sh
# t59 - releasing a charging switch must not depend on the cable being attached.
#
# THE INCIDENT THIS ENCODES
#   A Mi A3, unplugged, with battery/input_suspend latched at 1 and no daemon running:
#
#       $ acc -e
#       Charging enabled
#       $ echo $?
#       0
#       $ cat /sys/class/power_supply/battery/input_suspend
#       1
#
#   The command reported success, exited 0, and wrote nothing at all - the write ledger had no
#   input_suspend entry, because the write never happened rather than having failed. A direct
#   `echo 0` to the same node worked, so the hardware was never involved.
#
#   enable_charging gated the physical flip on present(), on the stated premise that "skipping the
#   flip changes nothing electrically" while unplugged. That premise is false. It changes the NEXT
#   plug: an input-cut node left latched keeps blocking charge the moment power returns, and the
#   only thing that would undo it is a later enable_charging from a RUNNING daemon.
#
#   That daemon is exactly what is missing in the cases that matter:
#     - `acc -e` and `acc -d` stop the daemon by design and never restart it.
#     - the daemon's own EXIT trap calls enable_charging on the way out.
#   So the retry the gate depended on is unavailable in precisely the situations that need it, and
#   the phone cannot charge until a reboot or another ACC command.
#
#   The gate's original purpose - suppressing a ~2s phantom "Charging" blip - was already obsolete
#   when this was found. write() became idempotent (read-before-write) in rc14/rc20: a switch
#   already at its resume value writes nothing, so there is no node poke to blip. The only case
#   that actually writes is the latched one, which is the case that must never be skipped.
#
# NO HARDWARE. Source-level, so it runs anywhere.

ID=t59
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
AS=$execDir/acc.sh
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }

# `^[ ]*` not `^  *`: the latter needs a leading space and silently misses column-0 functions.
body(){ sed -n "/^[ ]*$1()/,/^[ ]*}/p" "$2" | sed 's/#.*//'; }

_ec=$(body enable_charging "$MF")
[ -n "$_ec" ] || { no "could not extract enable_charging"; fin; }

# ---- 1: the release itself is unconditional -------------------------------------------------------
# The flip that returns the switch to its resume value must not sit inside a present() test. Anchor
# on the line itself and check nothing gates it: comments are stripped above, so a mention of
# present in the surrounding prose cannot be mistaken for the gate.
_flip=$(printf '%s' "$_ec" | grep -n 'flip_sw on || cycle_switches on' | head -1 | cut -d: -f1)
if [ -n "$_flip" ]; then
  ok "the release flip is present in enable_charging"
  # Everything before the flip, with the ghostCharging wrapper allowed. If `if present` appears in
  # that span the flip is gated again and the bug is back.
  _pre=$(printf '%s' "$_ec" | sed -n "1,${_flip}p")
  printf '%s' "$_pre" | grep -qE 'if present; then' \
    && no "the release flip is gated on present() again - an unplugged phone stays latched and cannot charge on the next plug" \
    || ok "nothing gates the release on present() - a latched switch is released with the cable out"
else
  no "could not find the release flip - enable_charging no longer flips the switch on"
fi

# ---- 2: the .sw restore path has the same property -------------------------------------------------
# The idle-avoidance handoff restores a saved switch config and flips it. It carried an identical
# present() gate and the identical consequence.
_sw=$(printf '%s' "$_ec" | sed -n '/TMPDIR\/.sw/,/^    fi/p')
if [ -n "$_sw" ]; then
  printf '%s' "$_sw" | grep -qE 'if present; then' \
    && no "the .sw restore path still gates its flip on present()" \
    || ok "the .sw restore path flips regardless of present() too"
else
  no "could not locate the .sw restore path"
fi

# ---- 3: re-negotiation must STILL be gated ----------------------------------------------------------
# The fix is narrow on purpose. APSD/AICL re-detection only means anything with a cable attached,
# and running it unplugged would be the fast-charge-contract hazard all over again (t56/t58). This
# is the half that must NOT have been loosened.
_case=$(printf '%s' "$_ec" | sed -n '/case "${chargingSwitch\[\*\]-}"/,/esac/p')
if [ -n "$_case" ]; then
  printf '%s' "$_case" | grep -q 'rekick_usb' \
    && ok "re-negotiation still routes through rekick_usb, so acc -sk off and the rate limit apply" \
    || no "re-negotiation no longer routes through rekick_usb"
  # Each arm carries its own present guard, and the block sits behind one as well.
  _n=$(printf '%s' "$_case" | grep -c 'present &&') || _n=0
  case "${_n:-0}" in ''|*[!0-9]*) _n=0;; esac
  [ "${_n:-0}" -ge 2 ] 2>/dev/null \
    && ok "both re-negotiation arms keep their own present() guard" \
    || no "only ${_n} re-negotiation arm(s) guard on present() - APSD could run with no cable"
else
  no "could not locate the re-negotiation case block"
fi

_post=$(printf '%s' "$_ec" | sed -n "${_flip:-1},\$p")
printf '%s' "$_post" | grep -qE 'if present; then' \
  && ok "a present() gate still wraps the post-release work" \
  || no "the present() gate around re-negotiation is gone - APSD/AICL would run unplugged"

# ---- 4: the idempotency the fix depends on ----------------------------------------------------------
# Removing the gate is only safe because a redundant flip writes nothing. If write() ever loses its
# read-before-write, this fix starts poking the node on every unplug and the phantom-charging blip
# the gate existed to prevent comes back. Device-measured: two consecutive `acc -e` calls with the
# switch already at its resume value produced ZERO new ledger entries.
_w=$(body write "$MF")
if [ -n "$_w" ]; then
  # ASSERT THE GUARD, NOT THE VARIABLE.
  #
  # This used to be `grep -q '_cur'`, which only proves the name appears somewhere in write(). A
  # mutation that neuters the COMPARISON while leaving `_cur="$(cat "$2")"` in place therefore
  # sailed straight past it - planting exactly that defect and running all 31 suites found NOT ONE
  # that failed. Read-before-write is what stops a redundant poke re-triggering the Tensor charger
  # state machine and what killed the idle fork storm, so a hole there is the worst one available.
  #
  # Three things have to be true, and each is checked separately: the node is read, the reading is
  # compared with what is about to be written, and a match SHORT-CIRCUITS before any write happens.
  printf '%s' "$_w" | grep -q '_cur="$(cat'     && ok "write() reads the node's current value first"     || no "write() no longer reads the node before writing"

  printf '%s' "$_w" | grep -qE '\[ "\$_cur" = "\$_tgt" \]'     && ok "and compares that reading against the value about to be written"     || no "write() reads the node but never compares it with the target - the read is decorative"

  # The comparison must return, not merely log. Everything between the comparison and the first
  # write has to contain a return; otherwise the value is compared and then written anyway.
  _guard=$(printf '%s' "$_w" | sed -n '/\[ "\$_cur" = "\$_tgt" \]/,/_wlog "write/p')
  if [ -n "$_guard" ]; then
    printf '%s' "$_guard" | grep -qE '^ *return 0'       && ok "and a match returns BEFORE the write, so a redundant poke costs nothing"       || no "the same-value comparison does not return before the write - the node is written regardless"
  else
    no "could not locate the span between the idempotency check and the write"
  fi
else
  no "could not extract write()"
fi

# ---- 5: name the reason the daemon cannot be relied on ------------------------------------------------
# The gate was defensible only if something always retried later. These two arms are why it was not.
if [ -f "$AS" ]; then
  _e=$(sed -n '/-e|--enable/,/;;/p' "$AS" | sed 's/#.*//')
  printf '%s' "$_e" | grep -q 'daemon_ctrl stop' \
    && ok "acc -e does stop the daemon, so nothing would have retried the release afterwards" \
    || echo "      note  acc -e no longer stops the daemon; the retry assumption may hold again"
else
  echo "      note  acc.sh not present; skipping the CLI assertion"
fi

fin
