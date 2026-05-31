**v2025.5.18-dev-fix11 (202505185)**
- The cap is now driven by the TARGET level on both sides, so the recharge stops
  EXACTLY at pause_capacity. The old on-value of 100 ("charge to 100%") made the
  firmware sail past the limit on every resume and overshoot it (the 75->77 breach).
  The google charge_stop_level switch is now:
    * `pcap pcap` -- charge to the cap and hold there (battery-idle), the DEFAULT;
    * `pcap 5`    -- discharge to resume_capacity, then recharge to the cap, repeat
                     (the cycle used when battery-idle is off; recharge still tops out
                     exactly at the cap, never above).
  The overshooting `100 5` and `100 battery/capacity` (on=100) variants are removed.
  `pcap` resolves to pause_capacity on both the on and off side in flip_sw.

**v2025.5.18-dev-fix10 (202505184)**
- Settings apply immediately. The daemon already re-reads the config every loop; its
  per-loop wait now wakes the instant the config file changes, so limit/temperature/
  switch edits from AccA take effect within ~1s (live re-read) instead of after the
  full loop delay -- no daemon restart, no UI freeze.
- The daemon survives a front-end restart. `acca -D restart` was a bare `exec accd`,
  which ran the daemon inside the calling process; when the caller was a one-shot
  script (the switch scanner), the daemon died the moment that script exited, leaving
  charging UNCAPPED. It now launches detached (its own session) and stays up.
- Switch scanner: re-arms charging between tests so every switch (including the
  flat-hold `pcap` variant) is actually evaluated instead of being skipped as "not
  charging", and it now verifies the daemon came back after a scan -- warning loudly
  if it did not.

**v2025.5.18-dev-fix9 (202505183)**
- Full fail-safe coverage: every capacity comparison (pause, resume, cooldown,
  shutdown, idle-reassert) now treats an empty OR non-numeric value as the safe
  outcome (pause / do-not-resume / do-not-shutdown), not just the two hardened in
  fix4/fix8. A garbage config can now never make any limit check error out.
- Flat-hold generalized: the `/proc/driver/charger_limit` node now also accepts the
  `pcap` (hold-at-target) off value like the Google charge_stop_level node, so more
  chipsets hold the cap flat (firmware-native) with no overshoot.
- Breach watchdog: if the battery is at/above the limit and charging still has not
  stopped, accd posts a throttled warning instead of failing silently; it clears
  itself once charging stops.

**v2025.5.18-dev-fix8 (202505182)**
- Fail-safe hardening: a malformed (non-numeric) pause_capacity or resume_capacity
  now reads as "pause now / do not resume" instead of letting the numeric test
  error out and silently skip the cap (which could overcharge). Previously only an
  empty value was guarded; a garbage value slipped through.
- A charging switch locked with `--` that STOPS working now triggers the auto
  fallback (re-selects a working switch) and posts a warning, instead of failing
  silently. `--` still suppresses routine re-cycling while the switch works, so
  there is no churn in the normal case.

**v2025.5.18-dev-fix7 (202505181)**
- Pixel/Tensor: the upper limit now HOLDS instead of being overshot. The google
  `charge_stop_level` node is a charge LIMIT ("charge to N%, hold"), not an on/off
  switch. fix5/fix6 drove it as 100/5 -- writing 5 makes the firmware discharge, then
  resume at the resume level, then re-charge and overshoot the cap (a 70<->limit
  sawtooth; reported breach 75 -> 77 on a Pixel 9a). fix7 drives it to the TARGET
  level via a new `pcap` off-token (= pause_capacity), so the firmware holds the
  battery flat at the cap: tight, no overshoot, and true battery-idle. `100 5`
  (discharge) and `100 battery/capacity` (hold at live %) remain as fallbacks.
- Charging-switch scanner now prefers idle/flat-hold switches over discharging ones,
  and understands the `pcap` token, so `--apply` locks the flat-hold variant rather
  than the sawtoothing discharge variant.
- Restored 2022/2023 behavior: when a pause can't be confirmed, accd reports failure
  and retries on the next loop instead of `exec`-ing a full daemon re-init mid-pause
  (the re-init re-armed charging in its window and thrashed flicker-prone switches).

**v2025.5.18-dev-fix6 (202505180)**
- Add acc-switch-scan.sh, a fast charging-switch scanner. `acc -t` waits up to 35s
  per switch; this polls the charging current ~3x/sec and decides each in ~1-4s,
  tests the whole list, ranks the working ones, prints a machine-readable BEST=
  line, and with --apply locks in the best switch automatically. AccA's switch
  test uses it from 1.0.50.

**v2025.5.18-dev-fix5 (202505180)**
- Pixel/Tensor: prefer the fixed-threshold google charge_stop_level switch. The
  dynamic "battery/capacity" variant pinned the stop level to the live %, so the
  firmware re-resumed at the threshold and accd re-tested the switch (brief on/off
  bursts near the limit). Disabling that variant lets ACC adopt the clean fixed
  switch, which holds the limit without churn.

**v2025.5.18-dev-fix4 (202505180)**
- Charging no longer pulses on/off near the limit. The strict charging-switch
  selection (fix3) re-enabled charging while pausing on devices whose only working
  switch the firmware keeps re-arming; it now keeps charging OFF while probing and
  selects a switch once per accd session instead of on every pause loop.
- Fail-safe limit: a missing/unreadable pause or resume capacity now reads as
  "pause now / do not resume" instead of letting the battery charge past the limit.

**v2025.5.18-dev (202505180)**
- acc -f fixes & enhancements
- acca -t q ... (quiet test; reports Ok, Idle or Fail)
- Add `/sys/devices/platform/charger/bypass_charger 0 1` switch (@Rem01Gaming)
- Avoid needlessly forcing default current, temp_level and voltage
- Config print includes acc version code
- Fix new defaults not applying
- Out of the box Encore Tweaks support
- Set default `_STI=35`
- Support acc -t[_STI] syntax
- Update doc

**v2025.5.1-dev (202505010)**
- -c|--config h string   Print config help text associated with "string" (config variable, e.g., acc -c h rt (or resume_temp))
- -s|--set file: Get config from file (in "acc -s" format)
- [acc -c d string] Quotes are no longer mandatory
- [acc -f] Don't use scripts from the default config; fix rt issue
- [acc -p] Filter more irrelevant sysfs nodes
- [acc -t] Add status column hint; show currently set charging switche(s)
- acc -f [cap] -a tries to restart accd automatically shortly after the charger is unplugged; not supported by all devices
- Add debug info to acc-t_output-${device}.log
- Additional switches & device-specific settings
- Also consider dc/online and pc_port/online for plug state detection
- Always sort switches before printing/testing
- Auto re-init accd on exit code 7
- Auto-set batt_status_workaround=false for msm8937
- battStatusOverride: Support ${chargingSwitch[2]} as a file
- Don't include trailing " --" in working switches list
- Drop capacity_sync, discharge_polarity and idle_threshold config variables
- Drop legacy AccA logic
- Exclude battery/store_mode switch
- Exclude current_cmd from mcc working list
- Exclude switches whose num_system_temp_in_levels is null
- Fix "acc -f [#] -s ..."
- Fix "acc -u -f dev^1" syntax & related errors
- Fix "chargingSwitch[2]: parameter not set"
- Fix & optimize current and voltage handling logic
- Fix 'acc -c a "..."'
- Fixes for msm8953 (e.g., Moto Z Play)
- Forbid control files modifications by 3rd-party
- Forbid mt - rt > 10 (fallback to rt = mt - 1)
- Get battery level info from Android's battery service if it differs from the kernel's (replaces capacity_sync)
- Implement battery stats reset workaround
- Implement idle_apps
- Improve bootloop handling logic and debugging tools
- In acc -c a ': sleep profile; at 22:00 "acc -s pc=60 mcc=500; acc -n \"sleep profile\""', the quotes are optional and all ";" can be replaced with ","
- Include dmesg and logcat in log archive
- Drop cooldownCustom
- Drop thermal_suspend (users can still have something like ":; pkill -STOP -f mi_thermald" in config to suspend thermal management processes)
- Lower switch test timeout
- Make it possible to post multiple notifications with acc -n
- Make the scheduler safer and aware of the "/dev/" prefix
- Minimize the use of subshells
- Notifications include timestamps
- Overwrite control files values 6 times within a second to wake up lazy switches
- Overwrite control files values upon issuing a disable/enable charging command, regardless of charging status
- Parse current and voltage control files only once per boot session to avoid "false defaults"
- Patches for KSU/Apatch, install notes and "no reboot needed" workaround
- Recommend trying temp_level if no regular current control file is found
- Reduce idle mode false positives when `bsw=true`
- Reinforce uninstall confirmation
- Reset "auto switch" and move it to the end of the list only if unsolicitedResumes = 3, rather than 1
- Reset switch (in auto-mode) if pbim changes via --set
- Reset working-switches.log on a full switch test
- Rewrite battery info logic (acc -i, -w)
- Rewrite discharge_polarity's logic - now dynamic and fully automatic
- Set idleAbovePcap threshold to (pause_capacity + 1)
- Set millivolts idleAbovePcap threshold to (pause_capacity + 50)
- Show applied config patches after upgrades (Android notification)
- Speed up acca --set for voltage and current limits
- Start accd as soon as the lockscreen shows up (no unlocking required)
- Support "," in place of "|" for egrep patterns (e.g., acc -i curr,volt; acc -w curr,volt; acc -sp cap,temp)
- Support cooldown_current with temp_level as back-end (e.g., acc -s cdc=60% to limit current by 60%)
- Support curl binary without --dns-server option (for upgrades)
- Support more devices with unconventional battery interfaces
- Support Nexus 10 (manta)
- Suppress "Terminated" messages
- Suppress missing current control file errors
- Try honoring allowIdleAbovePcap=false only 2x at most, per accd session
- Try wget if curl fails
- Update docs & strings
- Update installer; add magic overlayfs module support
- Update simplified Chinese translations (by @H-xiaoH)

**v2023.10.16 (202310160)**
- "edit g" shall work with non-root apps (acc -h g, acc -l g, acc -la g)
- -f supports additional options (e.g., acc -f -sc 500)
- -h|--help [[editor] [editor_opts] | g for GUI] prints the help text, plus the config
- -sd shall not print user scripts
- accd auto-updates mcc and mcv arrays (missing ctrl files or array[1] "-" marker)
- Added dev tag to update checker
- Additional charging switches
- Additional current control files
- allowIdleAbovePcap=true, if set to false, accd will avoid idle mode (if possible) when capacity > pause_capacity
- Auto-move failing switches to the end of the list
- Default acc -w refresh rate set to 1 second
- Default capacity_sync set to false
- Dropped obsolete code & information
- Ensure charging switch is set before a pause condition is hit
- Fixed html hyperlinks and duplicate temp in acc -i (OnePlus 7)
- Implement "rt ct mt" restricted charging hysteresis
- Improved current control files parsing & automatic switch logic
- KaiOS support
- Log export function invokes Android's share dialog
- Optimized loop delays (loopDelay=(3 9): 3 seconds while charging/idle, 9 seconds while discharging)
- prioritizeBattIdleMode=no has the opposite effect (prioritize non-idle mode)
- Refactored battery health calculator and cooldown logic
- resume_temp and cooldown_temp optionally override resume_capacity (if resume_temp has a trailing "r", as in resume_temp=35r)
- Selection lists count from 0 instead of 1
- Show /dev/ prefix tip only if acc is not in $PATH
- Suspend regular daemon functions until discharge_polarity is set, either automatically or manually
- Updated documentation
- Validate current control files only while charging
- Wizard is more user-friendly
