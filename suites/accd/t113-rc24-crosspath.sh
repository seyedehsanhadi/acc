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

# ---- 4. negotiation supplies ------------------------------------------------
# is_nego_node lives in misc-functions.sh. Source it in a guarded way: it is a big file with an
# execDir dependency, and a failure to load must skip these cases rather than fail the suite.
command -v is_nego_node >/dev/null 2>&1 || { . "$execDir/misc-functions.sh" 2>/dev/null || :; trap - EXIT; }
if command -v is_nego_node >/dev/null 2>&1; then
  for n in usb/current_max dc/current_max pc_port/current_max tcpm-source-psy-x/current_max; do
    is_nego_node "$n" && ok "negotiation node recognised: $n" || no "$n not recognised"
  done
  for n in battery/constant_charge_current_max main/current_max main-charger/current_max; do
    is_nego_node "$n" && no "$n wrongly treated as negotiation" || ok "battery-side node allowed: $n"
  done
  is_nego_node /sys/class/power_supply/usb/current_max \
    && ok "absolute paths are recognised too" || no "absolute path not recognised"
else
  sk "is_nego_node not exported into this shell"
fi
grep -q 'is_nego_node' "$execDir/misc-functions.sh" && ok "the re-kick lift skips negotiation nodes" \
                                                    || no "re-kick still lifts usb/"
grep -q 'is_nego_node' "$execDir/accd.sh" && ok "init restore skips negotiation nodes" \
                                          || no "init restore still writes 5000000 to usb/"

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
# R1. apply_on_plug's arg=default branch is the restore that runs when the USER CLEARS a current
# cap -- the most likely of the five restore paths to fire, and the last one still writing
# 5000000 to usb/current_max.
if grep -q 'restore skip' "$execDir/misc-functions.sh"; then
  ok "the clear-a-cap restore skips negotiation supplies"
else
  no "apply_on_plug default still lifts usb/"
fi

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

rm -rf "$T"
fin
