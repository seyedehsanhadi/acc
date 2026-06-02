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

[ $rc -lt $pc ] || {
  [ $pc -gt 3000 ] && rc=$((pc - 150)) || rc=$((pc - 5))
}

: ${mt:=50}
: ${rt:=40}
: ${ct:=45}

! [[ $rt -ge $mt || $((mt - $rt)) -gt 10 ]] || rt=$((mt - 1))

# cooldown_temp must stay below max_temp -- if they are equal, the cooldown cycle enters and
# immediately breaks at max_temp, so it never actually throttles. Keep a gap below max_temp,
# and never let cooldown_temp fall below resume_temp.
[ $ct -lt $mt ] || ct=$((mt - 5))
[ $ct -ge $rt ] || ct=$rt


# reset switch (in auto-mode) if pbim has changed and another switch is not being set
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

runCmdOnPause='$rcp'" > $config


cat $TMPDIR/.scripts $TMPDIR/.config-help >> $config
rm $TMPDIR/.scripts
set -u)
