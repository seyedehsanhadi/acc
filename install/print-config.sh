( set +u   # rc6 (S5): subshell so this 'set +u' (needed for the unguarded array reads below) does NOT leak into the sourcing caller (acc -s / set-prop) and silently disable its unset-var protection

echo "acc_version=$(sed -n s/versionCode=//p $execDir/module.prop)

allow_idle_above_pcap=$allowIdleAbovePcap
amp_factor=$ampFactor
batt_status_workaround=$battStatusWorkaround
capacity_mask=${capacity[4]}

cooldown_capacity=${capacity[1]}
cooldown_charge=${cooldownRatio[0]}
cooldown_current=$cooldownCurrent
cooldown_pause=${cooldownRatio[1]}
cooldown_temp=${temperature[0]}

current_workaround=$currentWorkaround
force_off=$forceOff
lang=$language

max_charging_current=${maxChargingCurrent[0]}
max_charging_voltage=${maxChargingVoltage[0]}

max_temp=${temperature[1]}
resume_temp=${temperature[2]}

off_mid=$offMid
pause_capacity=${capacity[3]}
prioritize_batt_idle_mode=$prioritizeBattIdleMode
reboot_resume=$rebootResume

reset_batt_stats_on_pause=${resetBattStats[0]}
reset_batt_stats_on_plug=${resetBattStats[2]}
reset_batt_stats_on_unplug=${resetBattStats[1]}

resume_capacity=${capacity[2]}
shutdown_capacity=${capacity[0]}
shutdown_temp=${temperature[3]}
temp_level=$tempLevel
volt_factor=$voltFactor

apply_on_boot=\"${applyOnBoot[@]}\"

apply_on_plug=\"${applyOnPlug[@]}\"

batt_status_override=\"$battStatusOverride\"

charging_switch=\"${chargingSwitch[@]}\"

idle_apps=\"${idleApps[@]}\"

run_cmd_on_pause=\"$runCmdOnPause\""

[ "${1-.}" = ns ] || sed -n 's/^:/\n:/p' $config
)
