# ACC rc24 to rc25: detailed notes

The full per-build record behind the condensed rc25 entry in changelog.md, newest first.

**v2025.5.18-6.5.1-rc25-test24-15 (202505372)**

Fixed
- Charging no longer drops and reconnects right after plugging in on phones with charge pumps (Poco F4 / munch and similar Xiaomi fast-charge phones). Each time charging was allowed, ACC switched on every "charging enabled" node that read off, including the charge pumps. The firmware keeps those off on purpose while USB-PD negotiates and switches one off at lower currents, so forcing them on broke the connection and the phone re-plugged, then ACC did it again. The reporter's log shows two reconnects, each 2 to 3 s after that write. ACC now leaves those nodes to the charger while it is charging. A charger that really stays dead is still revived, by the watchdog that first checks for 9 s that no charge is flowing. Present since rc13; the original VR25 never did this.

**v2025.5.18-6.5.1-rc25-test24-14 (202505371)**

Fixed
- The same stuck voltage limit had a second way in, and it was the more common one while plugged in. On every plugged pass the daemon also rewrites the voltage limit from the copy of the config it holds in memory. A pass that started just before a clear wrote the old limit back afterwards, left no mark behind, and nothing ever released it. Reproduced on a Mi A3: 5 runs in 24, plugged only. That pass now skips the voltage limit once the clear has dropped its mark, the same guard the current limit has had since test24-10. A limit that is really set is still enforced on every pass.

**v2025.5.18-6.5.1-rc25-test24-13 (202505370)**

Fixed
- Clearing a voltage limit could leave the phone capped (4.15 V holds a Mi A3 near 70 to 80%) with the config and AccA both saying no limit, and no command could release it. The clear restored the default voltage, but a daemon pass that had read the old config a moment earlier wrote the limit back in the same second. The daemon marked that write as its own, and the clear then deleted the mark on its way out. Once the mark was gone, nothing was left to undo, so the cap stayed until a reboot. Reproduced on a Mi A3 in 1 run in 5. The clear now drops the mark before it restores, so a late daemon write keeps its mark and the daemon's next pass releases it. A limit applied at daemon start is marked the same way. Present since rc24.

**v2025.5.18-6.5.1-rc25-test24-12 (202505369)**

Fixed
- Charging no longer keeps dropping and reconnecting on Xiaomi fast-charge phones (Poco F4 / munch) while a current limit is set. ACC wrote the limit into the charger's input nodes (`usb/current_max`, `input_current_settled`, `pc_port`, `dc` and the charge-pump input limits) and rewrote them every few seconds because the driver kept resetting them. Those nodes belong to the USB-PD negotiation: in the reporter's log every recorded disconnect came 0 to 11 s after one of those rewrites. When `restrict_cur` holds the limit and `restrict_chg` is armed, the limit is already enforced at the battery, so ACC now leaves the input nodes to the charger. On every other phone, and whenever `restrict_cur` does not take the value, the input nodes are capped exactly as before. The "firmware will not let … hold" warning no longer fires for the nodes ACC leaves alone.

**v2025.5.18-6.5.1-rc25-test24-11 (202505368)**

Improved
- Lower standby cost, with no change in behaviour. The unplugged nap waits 5 s per tick instead of 1 s; cable, shutdown-temperature and deadline checks keep their 5 s cadence, and acc/AccA config changes still end the nap at once through the daemon's wake pipe. Measured with the kernel's exact run-time counter, phone awake: idle cost 77 to 41 ms/min on a Mi A3, 145 to 100 ms/min on a Pixel 6a.
- `is_android` no longer scans every process on each pass once it has confirmed Android. One full unplugged pass on a Mi A3 fell from 1469 to 999 ms of CPU.

**v2025.5.18-6.5.1-rc25-test24-10 (202505367)**

Fixed
- A charging-current limit now holds on Xiaomi phones with charge pumps (Poco F4 / munch and similar). ACC wrote the limit to `restrict_cur`, but the driver only uses that value while `restrict_chg` is 1, and ACC never set it. A 4000 mA limit let 7.9 A through. ACC now sets `restrict_chg` to 1 while a limit is applied, but only after `restrict_cur` has taken the limit and only when `restrict_chg` was 0. ACC sets it back to 0 on release only if ACC was the one that raised it, so a restriction the ROM set itself is left alone. Nothing changes when the charging switch is a `restrict_*` node. The gap dates back to VR25's v2022.6.4, which first wrote `restrict_cur`. On a Mi A3, `restrict_cur` 600000 with `restrict_chg` 0 left 1.43 A flowing; with `restrict_chg` 1 the current was 0.60 A.

**v2025.5.18-6.5.1-rc25-test24-9 (202505366)**

Fixed
- `acc -d` followed by `acc -e` hands control back to the daemon again. `-d` stops the daemon so it cannot undo the pause, and nothing ever started it again, so the pair left the charge limit unenforced until the next reboot. This is the pair behind the app's own "Disable charging" and "Enable charging" scripts. A bare `acc -e` at or above the charging limit no longer releases the switch only for the restarted daemon to cut it again, a toggle that can drop a fast-charge contract; it keeps the pause and points to `acc -f` for a one-time charge. `acc -D stop` still means stopped.
- A working automatic charging switch is no longer dropped because the current unit could not be read. A microamp phone rebooted while holding in bypass reads a few milliamps on the battery against hundreds on the input, the unit came back unknown, the status became Unknown and was counted as "still charging", and both switch watchdogs could blacklist the switch. Only a measured status now counts toward replacing a switch; the pause itself is enforced exactly as before.
- A proven microamp current unit is remembered across reboots. A reading of 16000 or more on the battery node cannot come from a milliamp gauge, so it is recorded per node and reused when a later reading is too small to decide.
- The warning "config has ampFactor=1000000 but this phone's sensors read 1000" no longer fires on microamp phones that are merely idling. It appeared on Pixel 4a reports and told users to clear a correct setting. It now fires only when the hardware proves microamps against a milliamp setting.
- The ten-minute unplugged nap ends early when the battery reaches shutdown_temp, so the thermal cutoff acts as quickly as it did with the two-minute nap.
- Clearing a voltage limit that sat below the battery no longer leaves the phone plugged in and not charging. The charger had terminated at the low float voltage (charge_done=1, status still Charging, 0 A) and restoring the default float voltage did not restart it; only a replug did. Measured on a Mi A3 at 54%. ACC now re-arms the charger once when that latch is present below the charging limit.

Added
- `logs/daemon-events.log` records every daemon start, every exit with its code, and every stop request with the command that asked for it and that command's parent. A report of "ACC stopped working" can now be answered: which command stopped the daemon, from where, and whether it ever came back. Bounded to a few hundred lines.
- Diagnostic bundles carry three new pieces of evidence in the quick tier: that event log, a three-sample reading of every power supply's current, input current, online, present and voltage (the unit and sign evidence a single idle snapshot could not give), and `acc-state.txt`, which names the lock marker, last good switch, learned current unit, blacklist and one-time-charge state.

**v2025.5.18-6.5.1-rc25-test24-8 (202505365)**

Fixed
- `acc -e` re-enables charging again on a phone whose charging switch is chosen automatically. It aborted instead, on the first line of the block that restores the switch the daemon had saved, because that line expanded an array the config does not define: config.txt ships without a charging_switch line, auto-discovery being the documented default, and a fresh command has not run discovery yet. The abort was silent - the command printed "Charging enabled", exited 0, left the switch latched off and the battery unable to charge, and skipped the daemon restart at the end of its own branch, so nothing came along later to retry. Measured on a Mi A3 and a Pixel 6a: input_suspend stayed at 1 while the shell reported "chargingSwitch[@]: parameter not set". The same abort made `acc -d` report the switch as broken and collect a full log bundle on a phone whose switch was working.

**v2025.5.18-6.5.1-rc25-test24-7 (202505364)**

Fixed
- A firmware charge-limit write is logged with the reason it happened. Every one of them was tagged "thermal hold" and printed the battery temperature next to max_temp, whatever had actually caused it, because the tag was driven by a variable holding the battery level rather than by the hold itself. A report arrived reading "charge_stop_level <- 37 (was 40) thermal hold, temp=369 max=500" - a thermal cut at 36.9 C against a 50 C limit, which is not what happened. The tag also disappeared whenever the battery level could not be read, in the middle of a hold that was still in force. It now names the hold that fired and prints that hold's own measurement.

**v2025.5.18-6.5.1-rc25-test24-6 (202505363)**

Fixed
- A charging switch that did not confirm its pause on the first attempt is no longer un-done before the next one. The firmware applies a level switch on its own tick and the confirmation samples for a fixed window, so "did not confirm this pass" is not "does not work"; undoing the write reset that progress every pass, and a switch that needed three passes never reached a hold at all. The retry the daemon has always done is back.
- A candidate the switch scan did not adopt is handed back again, except at or above the charging limit, where the cut is the point of the scan and re-arming each failed candidate let the battery climb through the rest of the list. What is held back is now recorded and released when the scan ends up adopting nothing, which is the case that left a Mi A3 unable to resume for 150 seconds.

Changed
- The ownership flag that says ACC holds charging off is recorded once the pause is confirmed, as it was through rc24. Moving it earlier suppressed the kernel-status tie-break for every other reading taken while it was up, on the phones whose current sign is least reliable, and bought nothing: the confirmation is already covered by the switch-direction test on the line above it.

**v2025.5.18-6.5.1-rc25-test24-5 (202505362)**

Fixed
- A capacity pause could stay in force after the battery had fallen past the resume level, leaving the phone unable to charge when it was plugged back in. The resume was gated on the battery being cooler than resume_temp whether or not a temperature pause had ever happened, so a pack anywhere in the ordinary band between resume_temp and max_temp was held until the phone happened to cool. Measured on a Mi A3: cut at 80%, still cut at 68% with the cable out, highest temperature ever recorded 43.5 C against a 45 C limit. A real temperature pause still releases at resume_temp exactly as before.
- An automatically selected charging switch no longer marks itself as manually locked. The marker it wrote is the one a manual lock uses, so the app reported automatic selection as off, a change to the battery-idle preference stopped re-picking a switch, and the next save from outside the daemon turned the automatic pick into a real lock that ACC then refused to replace. Both test phones were in that state.
- A switch that stops holding the limit is replaced again. Both watchdogs looked for the manual-lock marker, which an automatic switch does not carry, so the one class of switch ACC is allowed to swap could never reach the replacement path. A manual lock is still never replaced.
- Raising max_temp no longer overwrites a shutdown temperature that was chosen deliberately. Only a cutoff still sitting at the default follows max_temp up.
- The update metadata pointed at release files named for the previous build.

**v2025.5.18-6.5.1-rc25-test24-4 (202505361)**

Fixed
- Shutdown temperatures of 40-70 C are stored independently from the charging pause temperature; invalid values are refused explicitly.
- Rejected charging-switch candidates are restored immediately, preventing an abandoned current or input cut from blocking charging.
- ACC records switch ownership before final cut verification, so stale kernel status cannot strand charging after the resume limit changes.

**v2025.5.18-6.5.1-rc25-test24-3 (202505360)**

- Retry a thermal pause when charging resumes despite ACC's disabled flag, including below the capacity resume limit. Keep enforcing the pause through the cooling band and release at the configured resume temperature.
- Check failing switches during thermal holds as well as capacity holds. Preserve manual switch locks and report a switch that cannot hold the limit.
- Add a regression replay covering the reported Redmi Note 10 Pro failure, thermal hysteresis, switch recovery, and normal resume behavior.

**v2025.5.18-6.5.1-rc25 (202505359)**

Most of this came from field reports on phones the project had never run on: a Motorola G64 5G, a
Redmi Note 10 Pro, a Fairphone 5, two OnePlus models. The rest came from auditing rc24 rather than
from complaints. Bundles AMPS v7.3.3.

Fixed
- Clearing a voltage limit now releases the hardware cap after a reboot or clean initialization, even when ACC's temporary control cache is absent. The saved setting, UI and live hardware state no longer disagree.
- A phone could be left unable to charge after a switch was blocked. When switch discovery ran automatically the config carries no switch name, so the code that releases a blocked switch could not find the one holding the cut and never ran. Measured on a Moto G64 5G: charging off for about three and a half hours while the app reported it as on.
- `acc -e` stopped the daemon and never started it again, so the limit silently stopped being enforced until the next reboot. Every other path that takes the lock already restarted it. Reproduced on a Pixel 6a and a Mi A3.
- Motorola's MediaTek current node is an on/off flag, not a number, and it cannot be read back. Treating it as a normal current limit could leave charging capped with nothing able to report or undo it. It is now recognised by vendor and by the node being unreadable, written as 0 or 1, and released to 0 when there is nothing recorded to restore.
- Re-detecting the charger could destroy a working high-voltage contract. Uninstall, boot and switch discovery all poked the kernel's re-detect nodes unconditionally. They now require a supply that is present, not already high-voltage, under 5.5 V and drawing 50 mA or less, which is a supply that is genuinely dead rather than merely quiet.
- A battery at a low charge could flash 100% for a second or two. ACC wrote that value itself on every plug and unplug so the framework would record a full-charge event; below 95% the claim is false and the phone just displays it. Reported on a Redmi Note 10 Pro sitting at 12%.
- A phone whose current sign is honest could be latched as "unstable" permanently, which made a slow charge and a drain indistinguishable. Seen on a Fairphone 5 across 1,506 samples.
- Uninstall no longer kills a process that merely inherited the daemon's old PID, leaves nested mounts attached under ACC's mount point, follows a broken symlink into `rm -rf`, removes a shared `bin` directory another module is still using, or deletes PATH links that were never ACC's.
- `acc --diag` could hang forever reading an unbounded file under `/proc`, and its internal time limits did nothing on any phone without the `timeout` applet, which is the phone most likely to need them.
- Saving a setting works on a ROM with no `flock`, and config writes are one locked transaction, so a writer that owns one key can no longer republish a stale copy of the others.
- A scheduled profile fires once instead of on every daemon pass, and a profile that announced itself now actually applies something.
- A USB type list that merely mentions PD is no longer read as a negotiated PD contract.
- The charger-type reader no longer depends on a helper its callers do not load, and the config path is resolved to its real file so an alias is recognised as the same config.
- When a setting is refused, the message names the setting that is actually blocking the charge.
- AMPS leaves firmware-owned nodes alone. A throttle node and SMB5's live charge-current vote are readings, not defaults, and replaying one pins the current below what the firmware asked for.
- AMPS can restore Motorola's write-only flag after an interrupted scan. With no way to read the old value the restore was skipped entirely and the flag stayed latched.

Added
- The flight log records battery temperature as a twelfth field, so a report about a temperature limit can be answered from the log instead of from a reading taken long after the phone cooled. Existing readers are unaffected; the field is appended.
- `acc --diag` has a real quick tier: 29 destinations covering what ACC decided and what it holds now, 10 s on a Pixel 6a against 45 s for a full run. Bundles also carry a build fingerprint, so two reports with the same version string can be told apart, and APatch is detected instead of reading as no root.
- AMPS records every restore, and why it ran, to its own log.

Changed
- The idle nap is ten minutes instead of two, and a nap now tracks wall-clock time so it cannot overrun.
- AMPS no longer asserts that charging failed immediately after a restore; it says the result is not in yet and names what to wait for.
