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
: ${rt:=40}
: ${ct:=45}

! [[ $rt -ge $mt || $((mt - $rt)) -gt 10 ]] || rt=$((mt - 1))

# cooldown_temp must stay below max_temp -- if they are equal, the cooldown cycle enters and
# immediately breaks at max_temp, so it never actually throttles. Keep a gap below max_temp,
# and never let cooldown_temp fall below resume_temp.
[ $ct -lt $mt ] || ct=$((mt - 5))
[ $ct -ge $rt ] || ct=$rt
# D3: the incremental clamps above can collapse a GARBAGE band into a near-max one (e.g.
# (40 60 90 65) -> (59 60 59 65)) where cooldown_temp ~= max_temp and the cooldown stage never
# throttles. If the cooldown->max gap collapsed (<3 C), the input was garbage -> reset to the
# proven default band rather than ship a dead cooldown stage.
[ $((mt - ct)) -ge 3 ] || { ct=45; mt=50; rt=40; }


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
