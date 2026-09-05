(set +u
# A FALLBACK IS NOT THE NEW TRUTH ON DISK.
#
# When $config fails to parse, _srcgood loads .config-good so the daemon keeps enforcing SOMETHING
# rather than dying. That is correct. What was not correct is what happened next: the very next
# config persist wrote those fallback values back out over the real file, so a TRANSIENT read
# failure became PERMANENT loss of the user's settings.
#
# Device-proven on a Pixel 6a: .config-good held the shipped defaults, the live config held
# capacity=(5 101 70 80 false), and after one boot the user's 80% limit was gone and the file read
# 75 -- the module default -- with nothing logged and no way to tell it had ever been 80.
#
# While running on the fallback the daemon has nothing worth writing: its in-memory values did not
# come from the user. Skip the persist entirely until a real config parses again, which clears the
# flag. Enforcement is unaffected -- only the write is suppressed.
[ "${_cfgFallback:-0}" != 1 ] || exit 0
s0="${charging_switch-${s}}"


ab="${apply_on_boot-${ab-${applyOnBoot[@]}}}"
af=${amp_factor-${af-$ampFactor}}
aiapc="${allow_idle_above_pcap-${aiapc-$allowIdleAbovePcap}}"
ap="${apply_on_plug-${ap-${applyOnPlug[@]}}}"
bso="${batt_status_override-${bso-$battStatusOverride}}"
bsw=${batt_status_workaround-${bsw-$battStatusWorkaround}}
cc=${cooldown_capacity-${cc-${capacity[1]}}}
cch=${cooldown_charge-${cch-${cooldownRatio[0]}}}
cdc=${cooldown_current-${cdc-$cooldownCurrent}}
cm=${capacity_mask-${cm-${capacity[4]}}}
cp=${cooldown_pause-${cp-${cooldownRatio[1]}}}
ct=${cooldown_temp-${ct-${temperature[0]}}}
cw=${current_workaround-${cw-$currentWorkaround}}
fo="${force_off-${fo-$forceOff}}"
ia="${idle_apps-${ia-${idleApps[@]}}}"
# Parse into `lang`, which is the name the emit below actually reads (language=${lang:-en}).
# This used to assign to `l`, and `l` is referenced nowhere else in the file, so an existing
# language= was silently dropped and every config write reset a non-English user back to en.
lang=${lang-${l-${language}}}
mcc="${max_charging_current-${mcc-${maxChargingCurrent[@]}}}"
mcv="${max_charging_voltage-${mcv-${maxChargingVoltage[@]}}}"

# HEAL A CONFIG THAT WAS CLEARED BY AN OLDER BUILD. In mksh `name=value` writes name[0] and leaves
# name[1..n] alive, so every `acc -s maxChargingCurrent=` before the fix in set-prop.sh published
#
#   maxChargingCurrent=( usb/current_max::500000::2200000 main/current_max::500000::2000000)
#
# -- the user's value gone, the derived node entries surviving. apply_on_plug iterates the whole
# array, so those survivors were re-applied on every loop and the cap could not be cleared: two test
# phones stayed pinned at 500000 with a UI reporting no limit, and a Mi A3 sat at a 3.9V float on a
# 4.4V pack after its voltage cap was "cleared".
#
# Fixing set-prop stops NEW corruption; it cannot repair a config already on disk. The leading value
# is the whole meaning of these two keys -- with no value there is no cap, so the derived entries are
# not just stale, they are a cap nobody asked for. Drop them here, at the one place every config
# write passes through, so the first write after an upgrade publishes a clean key.
# Detected on the FIRST TOKEN, not on a leading space: re-reading `( usb/current_max::... )` from
# disk gives an array whose element 0 IS that node entry, because the space is only whitespace to the
# parser. A real value is a bare number of mA or mV; anything else in first position means the value
# was lost and only derived entries remain.
case "${mcc%% *}" in ''|[0-9]*) : ;; *) mcc= ;; esac
case "${mcv%% *}" in ''|[0-9]*) : ;; *) mcv= ;; esac
mt=${max_temp-${mt-${temperature[1]}}}
om="${off_mid-${om-$offMid}}"
pbim=${prioritize_batt_idle_mode-${pbim-$prioritizeBattIdleMode}}
pc=${pause_capacity-${pc-${capacity[3]}}}
rbsp=${reset_batt_stats_on_pause-${rbsp-${resetBattStats[0]}}}
rbspl=${reset_batt_stats_on_plug-${rbspl-${resetBattStats[2]}}}
rbsu=${reset_batt_stats_on_unplug-${rbsu-${resetBattStats[1]}}}
rc=${resume_capacity-${rc-${capacity[2]}}}
rcp="${run_cmd_on_pause-${rcp-${runCmdOnPause[@]}}}"
rr="${reboot_resume-${rr-$rebootResume}}"
rt=${resume_temp-${rt-${temperature[2]}}}
s="${charging_switch-${s-${chargingSwitch[@]}}}"
sc=${shutdown_capacity-${sc-${capacity[0]}}}
st=${shutdown_temp-${st-${temperature[3]}}}
tl="${temp_level-${tl-$tempLevel}}"
ur=${ui_refresh-${ur-${uiRefresh:-60}}}
vf=${volt_factor-${vf-$voltFactor}}


# backup scripts
# PER-WRITER name. rc21 made the publish temp per-process ($config.$$.tmp) but left this
# staging file on a shared name, so two concurrent writers overwrote each other's ':' user
# scripts between the grep here and the cat at publish time, and one writer's rm deleted the
# other's file mid-flight. Same $$ discipline as the publish temp.
_sf=$TMPDIR/.scripts.$$
touch $_sf
grep '^:' $config > $_sf 2>/dev/null || :
sed -i 's/^:/\n:/' $_sf
printf "\n\n\n" >> $_sf


# enforce valid capacity and temp limits

# Defensive numeric coercion (additive, same style as the rc-era ': ${mt:=50}'
# guards and accd.sh's 'case $x in ''|*[!0-9]*)' fail-safes). The ':=' defaults
# below only fire on EMPTY/unset values -- a non-numeric value (e.g. mt=abc from a
# corrupt edit or a bad --set) slips straight through into the config. The daemon
# reads every temperature[] element with RAW arithmetic ($(( ${temperature[N]} * 10 ))
# in accd.sh: shutdown/cooldown/resume/max have NO comparator guard), so a garbage
# temp would crash the control loop. Capacity[0..3] have fail-safe comparators in
# accd.sh, but capacity_mask (capacity[4]) is run as a command and capacity[0/3] are
# used raw in mask_capacity/cap_idle_threshold, so coerce those too. Force any
# non-numeric value back to its documented default BEFORE the ordering guards run,
# so the arithmetic below and in the daemon only ever sees clean integers.
case ${sc-} in *[!0-9]*|'') sc=5;; esac
case ${cc-} in *[!0-9]*|'') cc=101;; esac
case ${rc-} in *[!0-9]*) rc=;; esac   # recomputed below if needed
case ${pc-} in *[!0-9]*) pc=;; esac
case ${ct-} in *[!0-9]*) ct=;; esac
case ${mt-} in *[!0-9]*) mt=;; esac
case ${rt-} in *[!0-9]*) rt=;; esac
case ${st-} in *[!0-9]*|'') st=55;; esac
case ${cm-} in true|false) :;; *) cm=false;; esac

: ${pc:=75}
: ${rc:=70}

# rc(6.3.1): clamp out-of-range NUMERIC pause/resume to a safe default. A corrupted value
# (e.g. 99999999, or 150) is all-digits so it passes the daemon's non-numeric fail-safe, but
# it is then read as millivolts and makes the daemon NEVER pause / ALWAYS resume = overcharge.
# Valid: 0-100 (percent) or 3001-5000 (mV). Anything else -> documented defaults.
case $pc in *[!0-9]*) ;; *) { [ $pc -le 100 ] || { [ $pc -gt 3000 ] && [ $pc -le 5000 ]; }; } || pc=80;; esac
case $rc in *[!0-9]*) ;; *) { [ $rc -le 100 ] || { [ $rc -gt 3000 ] && [ $rc -le 5000 ]; }; } || rc=75;; esac

# rc(6.4): pause and resume MUST be in the same unit domain (both percent <=3000, or both
# mV >3000). A mixed config (e.g. pause=5000mV, resume=80%) passes the rc<pc test below
# (80<5000) but the daemon then reads pause as mV -> volt_now never reaches 5000 -> it
# NEVER pauses = overcharge. Coerce resume into pause's domain before the ordering guard.
if [ $pc -gt 3000 ]; then
  [ $rc -gt 3000 ] || rc=$((pc - 150))
else
  [ $rc -le 3000 ] || rc=$((pc - 5))
fi

[ $rc -lt $pc ] || {
  [ $pc -gt 3000 ] && rc=$((pc - 150)) || rc=$((pc - 5))
}

# rc21 (A2): every rc derivation above ("rc=$((pc - 5))", "rc=$((pc - 150))")
# runs AFTER the 0-100 / 3001-5000 range check, and its result is never
# re-validated. A very low pause therefore produced a NEGATIVE resume that no
# clamp caught -- `acc 0` wrote capacity=(0 101 -5 0 false). The daemon compares
# level <= resume, and level is never negative, so such a config can never
# resume. Floor the derived value; sc is already floored by its own guard below.
[ $rc -ge 0 ] || rc=0

# rc(6.4.1 / N5): shutdown_capacity must share pc/rc's unit domain. A leftover percent sc
# (e.g. 5) in an mV config (pc>3000) means "shut down at 5 mV" -- never reached -- silently
# disabling low-battery shutdown protection. Coerce into the active domain BEFORE the sc<rc
# guard (mirrors the pc/rc domain coercion above).
sc=${sc:-5}
# sc < 1 is the documented "disable auto-shutdown" sentinel (accd.sh gates on capacity[0] < 1).
# Preserve it in BOTH domains -- only domain-coerce an ENABLED (>=1) level, else a user's sc=0
# would become a live mV threshold in an mV config and silently re-arm shutdown.
if [ $sc -ge 1 ]; then
  if [ $pc -gt 3000 ]; then
    [ $sc -gt 3000 ] || sc=$((rc - 150))
  else
    [ $sc -le 3000 ] || sc=5
  fi
fi

# ensure shutdown_capacity < resume_capacity. Without this an inverted config (shutdown >=
# resume) could make the daemon shut the phone down ABOVE the resume level.
# rc(6.4): enforce in BOTH percent and mV modes (was percent-only -- a mV config such as
# shutdown=4000mV resume=4100mV slipped through and shut the phone down at 4.0V / ~60%).
[ ${sc:-5} -lt $rc ] || sc=$(( rc > 1 ? rc - 1 : 0 ))

: ${mt:=50}
# rc6 (H4): cap an absurd numeric max_temp into a sane band. The shutdown_temp floor below keeps
# st>=max_temp; an out-of-band mt (e.g. 90) would otherwise drag the whole temperature band off or
# force st down below mt. Valid pause/cooldown ceiling is ~20..60 C; anything else -> 50.
{ [ ${mt:-50} -ge 20 ] && [ ${mt:-50} -le 60 ]; } 2>/dev/null || mt=50
: ${rt:=40}
: ${ct:=45}

# resume_temp must sit below max_temp; an at/above value collapses the hysteresis
# to a minimal 1 C swing that rapid-toggles, so force it down. This is a real
# invariant (resume-above-pause makes no physical sense) and stays.
[ $rt -lt $mt ] 2>/dev/null || rt=$((mt - 1))
# A resume MORE than 10 C below max used to be capped to exactly mt-10. That
# discarded a legitimate choice: a wide hysteresis (pause at max, resume only
# after the cell cools a lot) is a valid preference, not a fault, and the daemon
# already honours a wide gap from a hand-edited config untouched -- so the setter
# clamping it was pure normalisation dressed as safety, and it silently
# overwrote what the user asked for (max_temp=55 resume_temp=40 became 45). Honour
# any resume below max. The one real hazard the old cap guarded against is a
# resume so LOW the battery can never cool to it in normal use, which would leave
# charging stuck off after a single thermal pause; guard THAT directly with a
# reachability floor, and only a sub-floor value is rebuilt to the default 10 C
# gap. 15 C is a temperature a cell reaches in an ordinary cool room; below it,
# reachability is doubtful.
[ $rt -ge 15 ] 2>/dev/null || rt=$((mt - 10))
# ...and the rebuilt value must itself clear the floor. mt is clamped to 20..60 above, so for any
# mt below 25 the mt-10 rebuild lands under 15 again (mt=20 -> rt=10) and the invariant this guard
# states silently did not hold. Re-check, then restore the resume-below-max invariant, since
# pinning rt to 15 could otherwise meet or exceed a low mt.
[ $rt -ge 15 ] 2>/dev/null || rt=15
[ $rt -lt $mt ] 2>/dev/null || rt=$((mt - 1))

# cooldown_temp must stay below max_temp -- if they are equal, the cooldown cycle enters and
# immediately breaks at max_temp, so it never actually throttles. Keep a gap below max_temp,
# and never let cooldown_temp fall below resume_temp.
[ $ct -lt $mt ] || ct=$((mt - 5))
[ $ct -ge $rt ] || ct=$rt
# D3: the incremental clamps above can collapse the band (e.g. (40 60 90 65) -> (59 60 59 65))
# where cooldown_temp ~= max_temp and the cooldown stage never throttles. When the cooldown->max
# gap collapses (<3 C), REBUILD the band around max_temp (ct = mt-5, rt = mt-10, the default band
# shape) instead of resetting mt to 50. max_temp is already validated to [20..60] above, so a
# LOW but valid pause temp (e.g. a user who sets only max_temp=40, leaving cooldown/resume at the
# 45/40 defaults) must survive -- the old reset silently reverted it to 50, so the thermal pause
# never fired until 50 C and the battery ran hot past the user's setting.
[ $((mt - ct)) -ge 3 ] || { ct=$((mt - 5)); rt=$((mt - 10)); }
# Re-apply the floor AFTER the rebuild. The rebuild derives rt as mt-10 unconditionally, so a
# low but valid max_temp (mt=20 is inside the validated [20..60] band) produced rt=10 -- below
# any temperature a phone actually reaches, which means the thermal pause could never resume.
# The incremental clamps earlier ran BEFORE this line, so nothing else catches it.
# 15, not 20: 15 is the reachability floor this file documents and already enforces above. At 20
# this guard also fired on the NORMAL path and silently raised a valid resume_temp of 15..19, and
# the raised rt then dragged cooldown_temp and max_temp up with it - `acc -s max_temp=20` was
# published as temperature=(21 22 20 55): max_temp ABOVE the requested 20, with a 1 C
# cooldown->max gap that never throttles, the exact collapse the D3 rebuild above prevents.
[ $rt -ge 15 ] || rt=15
# -ge, matching the primary guard above ([ $ct -ge $rt ] || ct=$rt): cooldown_temp EQUAL to
# resume_temp is a valid band (max_temp=20 -> ct=mt-5=15, rt=15), and -gt pushed ct off the
# mt-5 band shape to enforce an invariant nothing else in the file or the daemon states.
[ $ct -ge $rt ] || ct=$rt
[ $mt -gt $ct ] || mt=$((ct + 1))

# rc6 (A3): shutdown_temp is the HARD over-temperature cutoff -- it must sit at/above the
# operating band, never below it. The non-numeric guard above let a low NUMERIC value (e.g.
# st=8) through, and the daemon then shuts the phone down whenever battery temp >= st (8C is
# always true). Keep st in a sane band [max(max_temp,40) .. 70]; outside that = garbage.
# Reset to an mt-AWARE default (mt+5 for a high max_temp) so st>=max_temp ALWAYS holds -- a
# fixed 55 sat BELOW a high max_temp (e.g. mt=57) and the phone shut down before it ever paused.
case ${st:-55} in *[!0-9]*) st=55;; esac
{ [ ${st:-55} -ge $mt ] && [ ${st:-55} -ge 40 ] && [ ${st:-55} -le 70 ]; } 2>/dev/null || st=$(( mt <= 50 ? 55 : mt + 5 ))


# reset switch (in auto-mode) if pbim has changed and another switch is not being set
# (coerce pbim FIRST -- a corrupt value here must not spuriously wipe a working chargingSwitch -- I9)
case ${pbim-} in true|false|no) :;; *) pbim=true;; esac
! [[ "${chargingSwitch[*]}" != *\ -- && -z "$s0" && ".$pbim" != ".$prioritizeBattIdleMode" ]] || s=


# Defensive coercion for the remaining scalar params. These all have a NULL/empty
# or fixed default as their documented valid value, so unlike the temps/caps above
# an empty value must be PRESERVED -- only non-empty garbage is reset. Booleans are
# run as commands in accd.sh ($forceOff || ...), so garbage merely degrades to false
# noisily; the rest feed raw arithmetic somewhere (ampFactor/voltFactor in
# batt-interface.sh '[ $ampFactor_ -eq 1000000 ]'; tempLevel in 'echo $((100 - $l))';
# cooldownRatio[*] in 'sleep'; cooldownCurrent in set_ch_curr range checks). Keep
# them clean so a corrupt config can never wedge those code paths.
case $af in *[!0-9]*) af=;; esac                   # amp_factor: null or integer
case $vf in *[!0-9]*) vf=;; esac                  # volt_factor: null or integer
case ${tl-} in *[!0-9]*|'') tl=0;; esac           # temp_level: integer %, default 0
# ui_refresh: seconds between idle state.json publishes, or 0 to publish on change only. Garbage
# falls back to the 30s default rather than to 0, because 0 is a real setting here (heartbeat off)
# and a typo must not silently switch the meter to change-only. Floor at 5: below that the publish
# costs more than the interval on a slow phone, and the change-driven path already covers anything
# faster. No ceiling -- a very large value is just "off" spelled differently, which is harmless.
case ${ur-} in *[!0-9]*|'') ur=60;; esac
[ "${ur:-60}" = 0 ] || [ "${ur:-60}" -ge 5 ] 2>/dev/null || ur=5
# cooldown_current: null, plain mA, or a percentage (mA%). Validate the numeric part;
# blank anything else so set_ch_curr / set_temp_level never choke on garbage.
case ${cdc-} in
  '') :;;
  *%) case ${cdc%\%} in ''|*[!0-9]*) cdc=;; esac;;
  *[!0-9]*) cdc=;;
esac
case ${cch-} in *[!0-9]*) cch=;; esac             # cooldown_charge: null or integer seconds
case ${cp-} in *[!0-9]*) cp=;; esac               # cooldown_pause:  null or integer seconds
# default-config.txt ships allowIdleAbovePcap=false. This coerced a missing or garbage value to
# TRUE, so a fresh install and its first config write disagreed about the shipped default, and the
# user's setting flipped without them touching it. The shipped value is the intended one.
case ${aiapc-} in true|false) :;; *) aiapc=false;; esac
case ${bsw-} in true|false) :;; *) bsw=true;; esac
case ${cw-} in true|false) :;; *) cw=false;; esac
case ${fo-} in true|false) :;; *) fo=false;; esac
case ${om-} in true|false) :;; *) om=true;; esac
case ${pbim-} in true|false|no) :;; *) pbim=true;; esac
case ${rr-} in true|false) :;; *) rr=false;; esac
case ${rbsp-} in true|false) :;; *) rbsp=false;; esac
case ${rbsu-} in true|false) :;; *) rbsu=false;; esac
case ${rbspl-} in true|false) :;; *) rbspl=false;; esac

# rc6 (A1): clamp plain-numeric mcc/mcv/tl HERE so the front-end path (acca -s, which writes
# config directly via this file) gets the SAME validation acc -s applies through set_ch_curr/
# set_ch_volt. A bad value (mcv=4500, mcc=99999) used to be stored verbatim -- only the daemon
# re-clamped on apply, so the saved config diverged from the acc -s result. Lists (with spaces)
# and node paths contain non-digits, so they are left untouched.
case "$mcc" in ''|*[!0-9]*) ;; *) [ $mcc -le 9999 ] || mcc=9999;; esac
case "$mcv" in ''|*[!0-9]*) ;; *) [ $mcv -ge 3700 ] || mcv=3700; [ $mcv -le 4300 ] || mcv=4300;; esac
case "${tl:-0}" in ''|*[!0-9]*) ;; *) [ ${tl:-0} -le 100 ] || tl=100;; esac

# rc8: remember whether the charging switch was LOCKED by the USER (a manual lock to RESPECT --
# never auto-replace it) vs by the daemon's own auto-locker (which may self-heal/replace it).
# isAccd=true means the running daemon wrote this config; a user `acc/acca -s` runs with
# isAccd=false. The 3 auto-replace sites (disable_charging fallback, breach monitor, resume
# watchdog) read this marker and only ever auto-change an AUTO-locked switch, never a user lock.
case "$s" in
  # rc14: a USER `--` lock must SURVIVE the daemon re-persisting config. Previously the daemon
  # (isAccd) cleared .user-locked whenever it rewrote a `--` switch -- including re-saving the
  # user's OWN locked switch on boot/verify -- which intermittently dropped the lock across reboots
  # (device-observed: 1 of 3 reboots). The daemon never auto-replaces a user-locked switch (it warns
  # instead, see disable_charging), so it has NO reason to clear the marker; only a USER writing the
  # switch (isAccd=false) should ever touch it. Daemon writes now leave an existing lock intact, and
  # auto mode is unaffected because the marker is already absent there (it is only ever set by a user).
  *\ --) ${isAccd:-false} || touch $dataDir/.user-locked 2>/dev/null || :;;
  '') ${isAccd:-false} || { rm -f $dataDir/.user-locked 2>/dev/null; touch $dataDir/.rediscover 2>/dev/null; } || :;;  # D7: the rm was UNCONDITIONAL -- only a USER going automatic (isAccd=false) clears the lock; a daemon blank must not
  *) ${isAccd:-false} || rm -f $dataDir/.user-locked 2>/dev/null || :;;
esac


# runCmdOnPause / battStatusOverride are emitted inside single quotes below; a user value
# containing a single quote (run_cmd_on_pause="don't ...") produced an unbalanced line and the
# daemon could no longer source the config at all (charging control dead until a manual edit).
# Escape ' as '\'' so any value round-trips; the escape is applied to the RAW value on every
# write (the sourced value is unescaped), so it never double-escapes.
rcp=$(printf %s "$rcp" | sed "s/'/'\\\\''/g")
bso=$(printf %s "$bso" | sed "s/'/'\\\\''/g")

# rc21: publish through a PER-PROCESS temp, not a shared $config.tmp. Under
# concurrent writers (many `acca -s` at once) the shared name raced: writer A's
# `> $config.tmp` truncated while writer B was mid-write, then B appended over
# A's remnant and mv'd the mix - a malformed config (Pixel 9a: 1 of 5 rounds of
# 10 concurrent writers). The `acca -s` flock is only best-effort (flock -w 5,
# and skipped entirely when flock is absent), so it cannot be relied on to
# serialise. A per-process name cannot collide, so each writer builds its own
# file and the mv is a clean last-writer-wins - correct concurrent semantics and
# never a corrupt config, lock or no lock. Same pattern edit() already uses.
_ct=$config.$$.tmp

# Per-process temps are only cleaned up by the mv (or the rm on its failure path), so a writer
# killed between building the file and renaming it strands one forever. The shared name rc20
# used was at least self-cleaning by reuse; this one accumulates, in the same directory the
# daemon's config fallback lives in. Measured: 50 concurrent writers left 42 files behind.
# Sweep by liveness, not by age: a temp whose owning pid is gone can never be renamed, and one
# whose pid is alive may be mid-write by another writer right now and must not be touched.
for _st in $config.*.tmp; do
  [ -e "$_st" ] || continue
  _sp=${_st%.tmp}; _sp=${_sp##*.}
  case "$_sp" in ''|*[!0-9]*) continue;; esac
  [ "$_sp" = "$$" ] && continue
  kill -0 "$_sp" 2>/dev/null && continue
  rm -f "$_st" 2>/dev/null || :
done

# printf '%s\n', not echo. mksh's echo builtin expands backslash escapes with no way to turn it
# off (its -e is documented as a no-op "since this is the default"), so any config value holding
# a backslash -- a runCmdOnPause with \n, a Windows-style path, an escaped quote -- came back
# through this emit mangled or silently truncated. printf '%s\n' emits the body verbatim.
# cooldownRatio: the fields are QUOTED rather than defaulted to 0. Empty is the documented
# "ratio disabled" value - default-config.txt ships cooldownRatio=(), accd.sh gates the whole
# cooldown cycle on `while [ -n "${cooldownRatio[0]-}" ]`, every sleep inside falls back with
# ${cooldownRatio[N]:-${loopDelay[0]}}, and `acc -f` disables the ratio by setting an empty
# cooldown_charge. ${cch:-0} wrote a literal 0, which is NON-empty, so it turned the cycle ON
# with zero-second halves (disable_charging / sleep 0 / enable_charging / sleep 0 in a tight
# loop, thrashing the charging switch) on every config written from a stock cooldownRatio=().
# Quoting keeps an empty field a real empty ELEMENT, so cooldown_pause still cannot slide into
# the charge slot. cch/cp are coerced to empty-or-digits above, so nothing quotable gets here.
# $TMPDIR/.config-ver is a tmpfs cache the DAEMON writes at init. Reading it unguarded made every
# config write depend on the daemon having run since the last boot: after a tmpfs loss (the exact
# case rc21's bootstrap exists for) `acc 75 70` and `acc -s key=value` died with
# "cat: can't open .../.config-ver" and exit 1, so the user could not change a setting until the
# daemon had re-initialised. The value is a constant in default-config.txt, which is on persistent
# storage and always present; fall back to reading it there, the same way accd.sh derives it.
_wcVer=$(cat $TMPDIR/.config-ver 2>/dev/null) || _wcVer=
[ -n "$_wcVer" ] || _wcVer=$(sed -n '/^configVerCode=/s/.*=//p' $execDir/default-config.txt 2>/dev/null)
printf '%s\n' "configVerCode=$_wcVer

allowIdleAbovePcap=${aiapc:-false}
ampFactor=$af
battStatusWorkaround=${bsw:-true}
capacity=(${sc:-5} ${cc:-101} $rc $pc ${cm:-false})
cooldownCurrent=$cdc
cooldownRatio=('$cch' '$cp')
currentWorkaround=${cw:-false}
forceOff=${fo:-false}
language=${lang:-en}
offMid=${om:-true}
prioritizeBattIdleMode=${pbim:-true}
rebootResume=${rr:-false}
resetBattStats=(${rbsp:-false} ${rbsu:-false} ${rbspl:-false})
temperature=($ct $mt $rt ${st:-55})
tempLevel=${tl:-0}
uiRefresh=${ur:-60}
voltFactor=$vf

applyOnBoot=($ab)

applyOnPlug=($ap)

battStatusOverride='$bso'

chargingSwitch=($(echo "$s" | sed 's/ m[AV]//'))

idleApps=($ia)

maxChargingCurrent=($mcc)

maxChargingVoltage=($mcv)

runCmdOnPause='$rcp'" > $_ct


# rc21: regenerate the help block if it is missing instead of failing the whole write.
# $TMPDIR/.config-help lives on tmpfs and is written in exactly ONE place -- accd's init. So any
# entry that reaches here without that init having run finds no file, and this `cat` fails under
# set -e: `acc 75 70`, `acc -s ...`, every config write dies with
# "cat: can't open '/dev/.vr25/acc/.config-help'". Device-proven: after a run that wipes tmpfs,
# 12 acc-cli assertions failed this way, including the documented pause/resume shortcut.
# The content is a pure derivation of default-config.txt, so rebuilding it costs one sed and
# needs no daemon. Same self-bootstrap principle as the launcher symlinks in acc.sh.
[ -s "$TMPDIR/.config-help" ] || sed -n '/^# /,$p' $execDir/default-config.txt > $TMPDIR/.config-help 2>/dev/null || :
cat $_sf $TMPDIR/.config-help >> $_ct
# rc16+: write to a temp then ATOMICALLY rename, so the daemon (which re-reads config.txt
# every loop) never sees a half-written file, and a failed/partial write (disk full,
# permission loss) leaves the previous config intact instead of truncating it.
# rc21: the temp is per-process ($config.$$.tmp), so concurrent writers cannot
# corrupt each other's file - see the _ct note above.
mv -f $_ct $config 2>/dev/null || rm -f $_ct 2>/dev/null
# Guarded, unlike the bare `rm` this replaces: that one printed
# "rm: .../.scripts: No such file or directory" to stderr on every writer that lost the race.
rm -f $_sf 2>/dev/null || :
# rc19 (standby): nudge the daemon's wake fifo so a settings change applies within ~1s even
# mid-nap. The nap's mtime watch has 1-second granularity and misses an edit landing in the
# same second a tick starts -- harmless at the old 9s naps, but the new 30s/120s holds made
# that a visible lag. CLI writes only (the daemon's own config persists skip it via isAccd);
# gated on a LIVE daemon because opening a reader-less fifo for write would block forever.
${isAccd:-false} || [ ! -p ${TMPDIR:-/dev/.vr25/acc}/.wake ] || ! pgrep -f accd.sh >/dev/null 2>&1 \
  || echo w > ${TMPDIR:-/dev/.vr25/acc}/.wake 2>/dev/null || :
set -u)
