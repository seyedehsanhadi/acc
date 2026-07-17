(set +u
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
l=${lang-${l-${language}}}
mcc="${max_charging_current-${mcc-${maxChargingCurrent[@]}}}"
mcv="${max_charging_voltage-${mcv-${maxChargingVoltage[@]}}}"
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
vf=${volt_factor-${vf-$voltFactor}}


# backup scripts
touch $TMPDIR/.scripts
grep '^:' $config > $TMPDIR/.scripts 2>/dev/null || :
sed -i 's/^:/\n:/' $TMPDIR/.scripts
printf "\n\n\n" >> $TMPDIR/.scripts


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

# resume_temp must sit below max_temp; an at/above value collapses to a minimal 1 C swing.
# A resume set MORE than 10 C below max is capped to a 10 C hysteresis (a lower resume could
# never be reached in a warm room -> charging stuck off), NOT crushed to mt-1 as the old
# combined guard did -- that 1 C swing rapid-toggled AND cascaded into cooldown_temp, forcing
# the band rebuild below to discard the user's cooldown_temp as well.
[ $rt -lt $mt ] 2>/dev/null || rt=$((mt - 1))
[ $((mt - rt)) -le 10 ] 2>/dev/null || rt=$((mt - 10))

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
# cooldown_current: null, plain mA, or a percentage (mA%). Validate the numeric part;
# blank anything else so set_ch_curr / set_temp_level never choke on garbage.
case ${cdc-} in
  '') :;;
  *%) case ${cdc%\%} in ''|*[!0-9]*) cdc=;; esac;;
  *[!0-9]*) cdc=;;
esac
case ${cch-} in *[!0-9]*) cch=;; esac             # cooldown_charge: null or integer seconds
case ${cp-} in *[!0-9]*) cp=;; esac               # cooldown_pause:  null or integer seconds
case ${aiapc-} in true|false) :;; *) aiapc=true;; esac
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

echo "configVerCode=$(cat $TMPDIR/.config-ver)

allowIdleAbovePcap=${aiapc:-true}
ampFactor=$af
battStatusWorkaround=${bsw:-true}
capacity=(${sc:-5} ${cc:-101} $rc $pc ${cm:-false})
cooldownCurrent=$cdc
cooldownRatio=($cch $cp)
currentWorkaround=${cw:-false}
forceOff=${fo:-false}
language=${lang:-en}
offMid=${om:-true}
prioritizeBattIdleMode=${pbim:-true}
rebootResume=${rr:-false}
resetBattStats=(${rbsp:-false} ${rbsu:-false} ${rbspl:-false})
temperature=($ct $mt $rt ${st:-55})
tempLevel=${tl:-0}
voltFactor=$vf

applyOnBoot=($ab)

applyOnPlug=($ap)

battStatusOverride='$bso'

chargingSwitch=($(echo "$s" | sed 's/ m[AV]//'))

idleApps=($ia)

maxChargingCurrent=($mcc)

maxChargingVoltage=($mcv)

runCmdOnPause='$rcp'" > $config.tmp


cat $TMPDIR/.scripts $TMPDIR/.config-help >> $config.tmp
# rc16+: write to a temp then ATOMICALLY rename, so the daemon (which re-reads config.txt
# every loop) never sees a half-written file, and a failed/partial write (disk full,
# permission loss) leaves the previous config intact instead of truncating it.
mv -f $config.tmp $config 2>/dev/null || rm -f $config.tmp 2>/dev/null
rm $TMPDIR/.scripts
set -u)
