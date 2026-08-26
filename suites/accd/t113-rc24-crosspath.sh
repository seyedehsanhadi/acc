#!/system/bin/sh
# t113 - the twelve rc23->rc24 findings, each one "the fix exists on one path and was not copied
# to the path AccA / Pixel / init actually uses".
#
# Every case below is written to FAIL against the old code. NO HARDWARE: pure functions and
# temp files only, nothing is written to a real power_supply node.

ID=t113
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
T=${TMPDIR:-/dev/.vr25/acc}/t113; rm -rf "$T"; mkdir -p "$T" || { no "no tmp"; fin; }

[ -f "$execDir/cfg-guard.sh" ] || { no "cfg-guard.sh not installed"; fin; }
. "$execDir/cfg-guard.sh"

# ---- 1. source-as-parse-test ------------------------------------------------
# A config that PARSES but whose last command fails. The old `( . $file )` test judged the exit
# status, so this read as malformed -- and the callers respond by DELETING .config-good or
# overwriting the user's config with the defaults.
printf 'capacity=(5 101 70 75 false)\nfalse\n' > "$T/exit1.conf"
cfg_parses "$T/exit1.conf" && ok "a valid config ending in a failing command still parses" \
                           || no "config with a non-zero last command judged malformed"
# ...and it must not be EXECUTED while being judged.
printf 'capacity=(5 101 70 75 false)\ntouch %s/SIDE_EFFECT\n' "$T" > "$T/side.conf"
cfg_parses "$T/side.conf" >/dev/null 2>&1
[ -f "$T/SIDE_EFFECT" ] && no "the parse test EXECUTED the config" \
                        || ok "the parse test does not execute the config"
# a genuinely truncated file must still be caught
printf 'capacity=(5 101 70 75\n' > "$T/trunc.conf"
cfg_parses "$T/trunc.conf" && no "a truncated config was accepted" \
                           || ok "a truncated config is still rejected"
# and the fix must be live in the daemon + oem-custom, not just in srccfg_try
grep -q 'cfg_parses' "$execDir/accd.sh"      && ok "accd.sh uses the parse test" \
                                             || no "accd.sh still sources to decide validity"
grep -q 'cfg_parses' "$execDir/oem-custom.sh" && ok "oem-custom.sh uses the parse test" \
                                              || no "oem-custom.sh still sources to decide validity"

# ---- 2. idleApps pause must not reach the writer ----------------------------
grep -q 'pause_capacity=${capacity\[3\]}' "$execDir/accd.sh" \
  && ok "pause_now names the real pause for write-config" \
  || no "pause_now still lets write-config publish the lowered capacity[3]"
grep -q 'unset pause_capacity resume_capacity' "$execDir/accd.sh" \
  && ok "_srccfg clears the shadow names each pass" \
  || no "_srccfg does not clear them, so pass 1's levels republish forever"

# ---- 3. acca -s must refuse what acc -s refuses -----------------------------
cfg_check_kv 'pause_capacity=999' 2>/dev/null && no "999 accepted (write-config would clamp to 80)" \
                                              || ok "out-of-range pause refused, not clamped"
cfg_check_kv 'pause_capacity=abc' 2>/dev/null && no "non-numeric pause accepted" \
                                              || ok "non-numeric pause refused"
cfg_check_kv 'capacity=5 101 70 75' 2>/dev/null && no "array key accepted as a scalar" \
                                                || ok "array key refused"
cfg_check_kv 'pause_capacity=75'  2>/dev/null && ok "a valid percent is accepted" \
                                              || no "75 wrongly refused"
cfg_check_kv 'pause_capacity=3900' 2>/dev/null && ok "a valid mV value is accepted" \
                                               || no "3900mV wrongly refused"
cfg_check_kv 'cooldown_capacity=101' 2>/dev/null && ok "cooldown 101 (its 'off') still accepted" \
                                                 || no "cooldown 101 wrongly refused"
grep -q 'cfg_check_kv' "$execDir/acca.sh" && ok "acca -s validates before writing" \
                                          || no "acca -s still reaches write-config unchecked"
grep -q 'cfg_parses' "$execDir/acca.sh"   && ok "acca sources the config parse-safely" \
                                          || no "acca still has a bare . \$config under set -eu"

# ---- 4. negotiation supplies: NOT a blanket rule ---------------------------
# The four writes that reach usb/current_max are NOT one class, and only one of them is a skip:
#
#   apply_on_plug default   5000000 to clear ACC's cap        must write (else the cap is stranded)
#   init restore            5000000 when the node is <=100mA  must write (the leftover 50000 case)
#   rekick ICL lift         5000000 when ICL is really 0      must write (a skip makes it inert)
#   uninstall :180          the node's recorded pre-ACC value must write (put back what ACC found)
#   uninstall :237          5000000 by name on every supply   SKIPS usb, and should
#
# _hv_lift also stays off usb, and that is right: it lifts a LIVE negotiated port, which is a
# different operation from clearing a cap ACC itself applied.
#
# The two "100mA" measurements in the tree are also different events: the A3's "5000000 over a
# live 1.2A -> 200mA" was traced to a ~500 milliohm cable, while the bluejay "one write -> 100mA"
# is asserted independently in _hv_lift and the rc24 changelog. Only a charger settles which rule
# a LIFT needs; neither touches the cap-clear paths above.
# rc24 forbids writing usb/ dc/ pc_port/ tcpm* from the UNINSTALLER'S name-glob sweep, and that
# skip is deliberate and stays. It was briefly generalised into a predicate applied to every
# RELEASE path too, and that was wrong -- the code's own measurements say so:
#   * apply_on_plug APPLIES the user's cap to usb/current_max. Skipping the release means ACC can
#     cap the node and never let go: "the cap will not clear", reproduced on a Pixel 6a and a Mi A3.
#   * the init restore exists SPECIFICALLY to undo a leftover usb/current_max cap -- the reporter's
#     ledger names that node, `usb/current_max <- 50000 (was 1800000)`.
#   * the re-kick lift targets the input-negotiation nodes BY DESIGN; skipping them makes it inert.
#   * the ~100mA collapse that motivated the generalisation was later explained by a cable with
#     ~500 milliohm of series resistance, whose input collapses identically with ACC uninstalled.
# So the assertion here is the opposite of what it briefly was: the release paths must still be
# able to let go of an input node.
if grep -q 'never LOWER a live value on a restore' "$execDir/misc-functions.sh"; then
  ok "apply_on_plug can still release an input node (the cap can clear)"
else
  no "the restore path no longer releases input nodes - 'the cap will not clear' is back"
fi
if grep -q 'usb/current_max <- 50000' "$execDir/accd.sh"; then
  ok "the init restore still repairs a leftover input cap"
else
  no "the init restore no longer repairs the node it was written for"
fi
if grep -q 'usb/\*|dc/\*|pc_port/\*|tcpm\*' "$execDir/uninstall.sh"; then
  ok "the uninstaller's name-glob sweep keeps its rc24 skip"
else
  no "the uninstaller lost its rc24 negotiation skip"
fi

# ---- 5. journal_check needs panic evidence ---------------------------------
grep -q 'panic\*|\*watchdog' "$execDir/probe-journal.sh" 2>/dev/null \
  || grep -q 'watchdog' "$execDir/probe-journal.sh" \
  && ok "journal_check checks the boot reason" \
  || no "journal_check still blacklists on any leftover pending file"
grep -q '_jcblame' "$execDir/probe-journal.sh" && ok "blacklist + notify + strike count are all gated" \
                                               || no "the gate is missing"

# ---- 8. shipped default vs first write --------------------------------------
_dc=$(sed -n 's/^allowIdleAbovePcap=//p' "$execDir/default-config.txt" 2>/dev/null | head -1)
_wc=$(grep -c 'aiapc=false' "$execDir/write-config.sh" 2>/dev/null || echo 0)
if [ "$_dc" = false ] && [ "${_wc:-0}" -ge 1 ]; then
  ok "write-config agrees with the shipped allowIdleAbovePcap=$_dc"
else
  no "shipped default is '$_dc' but write-config still coerces to true"
fi

# ---- 10. early-cap understands millivolts -----------------------------------
grep -q '_mvolt' "$execDir/post-fs-data.sh" && ok "early-cap handles an mV pause" \
                                            || no "an mV pause still skips the boot-gap cut"

# ---- 11. force_off re-checks its flag ---------------------------------------
grep -q 'f \] || break' "$execDir/accd.sh" && ok "force_off re-reads the flag before writing" \
                                           || no "force_off can still flip after enable_charging"

# ---- 12. plugged detection matches present() --------------------------------
for pat in ucsi oplus glink mtk smb; do
  grep -q "$pat" "$execDir/state-export.sh" && ok "_se_plugged knows $pat supplies" \
                                            || no "_se_plugged still misses $pat"
done
grep -q '_se_supply_nodes online' "$execDir/state-export.sh" \
  && ok "the online fallback is filtered (no battery/online)" \
  || no "the online fallback still globs battery/online"

# ---- review round 2: the two leftovers that were safe to fix --------------------
# R1 was REVERTED. apply_on_plug's arg=default branch must still lift an input node -- that is
# the release that clears a user's cap, and section 4 above already pins it. Nothing to assert
# here beyond what section 4 says.

# R4. The leak hold `continue`s past is_charging(), which carries the thermal cutoff. The hold can
# last hours, and CPU load heats the pack whether or not the input is cut.
# grep -E, not BRE alternation: toybox grep has no backslash-pipe and would match nothing.
if grep -qE '_lst|_ltn' "$execDir/accd.sh"; then
  ok "the thermal cutoff runs during a leak hold"
else
  no "shutdown_temp is still skipped for the whole hold"
fi

# ...and it must stay ADDITIVE: the hold must not start calling is_charging(), which is what the
# `continue` exists to avoid. Comments are stripped first -- the block's own comment explains why
# it avoids is_charging(), and the word in prose is not a call.
if awk '/if leak_backstop; then/,/^      fi$/' "$execDir/accd.sh"      | grep -v '^[[:space:]]*#' | grep -q 'is_charging'; then
  no "the leak hold now calls is_charging - that reintroduces the resume fight"
else
  ok "the leak hold still does not call is_charging"
fi

# R2. native_verify_backstop must PREFER a charger-owned cut and keep usb/ only as a fallback.
if grep -q 'nvb_cut' "$execDir/accd.sh"; then
  ok "the native backstop picks a cut node instead of always using usb/"
else
  no "the native backstop still writes usb/input_current_max unconditionally"
fi
# the usb fallback must still be there -- deleting it lets a Tensor overcharge
if grep -q 'NVB_NODE:-/sys/class/power_supply/usb/input_current_max' "$execDir/accd.sh"; then
  ok "the usb/ fallback is retained for phones with no charger-owned cut"
else
  no "the usb/ fallback was removed - a Tensor ignoring charge_stop_level would overcharge"
fi
# and the saved restore value must match the node's domain, not always 2000000
if grep -q 'echo 0 > $TMPDIR/.nvb-restore' "$execDir/accd.sh"; then
  ok "the restore default matches the cut node's domain"
else
  no "the restore fallback would write a current value into a 0/1 node"
fi

# R5. force_off's background loop cannot see a later change to chargingSwitch[]: `done &` forks,
# and a forked subshell holds a COPY. Proven here rather than assumed -- this is the reasoning
# that decided NOT to add a redundant snapshot.
_fo=$T/fo.out; _fof=$T/fo.flag; : > "$_fo"; touch "$_fof"
_fov=alpha
( while [ -f "$_fof" ]; do echo "$_fov" >> "$_fo"; sleep 1; done ) &
sleep 2; _fov=BRAVO; sleep 2; rm -f "$_fof"; sleep 2
if grep -q BRAVO "$_fo" 2>/dev/null; then
  no "a backgrounded loop SAW the parent's later change - force_off needs an explicit snapshot"
else
  ok "a backgrounded loop keeps its fork-time copy (force_off needs no snapshot)"
fi

# R6. The installer must keep exit 0 and warn. Magisk drops the module on a nonzero installer.
for _f in "$execDir/../../../install.sh" /data/local/tmp/install.sh; do
  [ -f "$_f" ] || continue
  if grep -q 'daemon did NOT start' "$_f" && grep -q '^exit 0' "$_f"; then
    ok "installer warns loudly and still exits 0"
  else
    no "installer no longer warns, or no longer exits 0"
  fi
  break
done

rm -rf "$T"
fin
