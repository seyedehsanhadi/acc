# ACC - Advanced Charging Controller

Community fork of VR-25's ACC, maintained by seyedehsanhadi.

- Telegram group: https://t.me/+hU1oF-BCf5hmM2Rk
- Fork: https://github.com/seyedehsanhadi/acc   .   AccA app: https://github.com/seyedehsanhadi/AccA
- Upstream (original): https://github.com/VR-25/acc

Changes since the fork baseline (v2025.5.18-stable.6.5):

**v2025.5.18-6.5.1-rc24 (202505333)**

Nobody reported a fault in rc23. Everything below was found by testing it, so these are latent
problems rather than a queue of complaints, and most of them need a particular charger, kernel or
install path to show up at all.

Fixed
- Find my switch ships AMPS v7.3.1. A native %-limit pick is now functionally cycled, pause and resume, against a charging baseline instead of being confirmed on the engage reading alone, and a run that cannot measure says so instead of failing the switch.
- A 9 V charger no longer collapses to about 4.4 V shortly after you plug it in. ACC read a live, negotiated supply as unnegotiated and re-ran USB detection on it. Voltage and current are now normalised before any comparison, because the same kernel path reports microvolts on one phone and millivolts on another, and the contract bar moved from 6.0 V to 6.5 V, which is above the operating band of a healthy 5 V supply.
- A charger that has once reached high voltage is treated as negotiated for the rest of that plug, however far it later sags. A high-voltage label (HVDCP, PD, QC) counts on its own. Only unplugging the cable clears it.
- All charger re-detection goes through a single gate that has to satisfy six conditions at once, and each plug gets one repair attempt, never two. Previously every caller invented its own way around the check, and those escapes were the fault.
- A stalled charger is answered by lifting its input current limit, which cannot disturb a voltage contract, instead of by re-detecting the charger.
- Your charge limit is no longer silently absent after install. The installer reported the exit code of a fork rather than of the daemon, so a daemon that never came up looked like a successful install and the phone charged to 100% with nothing to show it was wrong.
- The limit can no longer stop being enforced part-way through a session, from an abort inside the first-install probe or the leak backstop taking the daemon with it.
- The known-good config fallback can no longer be poisoned by a one-shot charge. The daemon cached whatever config it had just parsed into `.config-good`, and during `acc -f` that is a throwaway in tmpfs, so one charge-once to 100 left the fallback holding pause=100 with no cooldown and no caps, plus the `-f` restore hook. A config that later failed to parse would have fallen back to the most aggressive profile the module can hold. Only a config outside tmpfs is cached now, which also covers the daemon's own two temporaries.
- `acc -f 95 -s mcc=500` works again. The help documents `-f [capacity] [-a] [additional opts/args]`, but rc21 made every non-numeric argument fatal to stop `acc -f 8O` quietly falling back to 100 and charging a phone to full, and that also refused the options on the same help line, so the pass-through code below had been unreachable. Options now end the argument loop instead of failing it. A typo in the capacity position has no leading dash, so it is still refused.
- `acc -f` now ends by itself. It hands the daemon a throwaway config with the one-shot limit on it, and until now nothing ever loaded the real config again: `acc -f 100` parked a phone at 100% until the daemon was restarted by hand. AccA's "charge once" button sends `acca -f N` with no `-a`, so that was the normal path rather than an edge case. `-a` never covered it either, because it restores on unplug and a phone left plugged after reaching the target keeps the override. The throwaway now carries a second hook that restores the real config when the target level is reached, whether the cable is still in or not. Unplugging early still needs `-a`, which is what `-a` documents, and that case now clears itself on the next charge.
- Releasing a current ceiling still writes the negotiation side of the port, because that is where the ceiling was applied: apply_on_plug sets usb/current_max, so a release that skipped it would strand the cap instead of clearing it. An earlier rc24 build skipped that write and was reverted after both phones reproduced the stranded cap. The roughly 100 mA reading that prompted it was traced to a cable of about 500 milliohms, not to ACC. What does stay off the negotiation side is the stall repair, _hv_lift, which lifts a charger-owned input limit only.
- Uninstalling ACC no longer leaves the phone barely charging, for the same reason.
- Charging no longer renegotiates every time it resumes from a pause, which cost you fast charge after the first pause of the session.
- Plugging in charges again on phones whose switch is an input cut. The re-arm gated on a node that an input cut masks to zero while the cable is still in.
- No more five minutes of "not charging" before it starts: the candidate sweep that ran as the resume path when no switch was configured is now bounded.
- An untried candidate can no longer end up used as your configured switch, where a voltage float ceiling stands in for a pause and the limit is never enforced.
- Fast charging survives. A write that already held the right value was re-asserted five more times, which re-triggered input current limiting and the charge pump.
- Clearing a current limit no longer strands the phone at 500 mA. The restore replayed a default snapshotted from whenever ACC first saw the node, which on a laptop port is 500000.
- A collapsed charger is repaired on phones that report microamps. 5353 µA was read as five amps, so the detector never fired.
- `acc -t` gives up after the time it says it will. The wait counted loop passes, and a pass costs about 36 seconds on an unplugged phone, so the three-minute default ran closer to two hours.
- `maxChargingCurrent` works on phones with a firmware charge limit. It was accepted, stored and displayed while nothing was ever written; a reporter's Pixel 4a 5G had been running a 925 mA limit that had never done anything. The firmware-limit branch returned before the charging-current and charging-voltage limits were reached at all.
- Clearing a charging limit removes its node entries instead of leaving them behind and continuing to apply them, and an applied cap is never recorded as the node's own default, so a cap can be released and applied again on any phone.
- The diagnostic bundle no longer accuses a working switch on phones with a firmware limit, and it attaches the kernel log from an abnormal reboot that it advertises in its own index.
- "Show config" works in AccA, and a config value containing a command substitution is stored rather than run.

Note
- Almost every change here makes ACC do less: do not renegotiate, do not lift the negotiation side during a stall repair, fail closed when a supply cannot be proven dead, bound the sweep. The price is a rarer missed repair, where a stalled charger that rc23 might have kicked back to life is answered only by lifting its input current limit.

**v2025.5.18-6.5.1-rc23 (202505331)**

Fixed
- Charging no longer resumes a tenth of a degree under your maximum temperature: on firmware-limit phones the hold now stays on down to your resume temperature, as the switch path already did.
- Every busybox tool could silently vanish from the daemon's PATH, leaving a phone with no daemon and charging uncapped after a switch scan.
- The charger's input current no longer stays collapsed after a firmware pause, where the firmware handed it back at a fraction of what it took.
- The pack's own current limit is no longer written while ACC probes the charger. It was meant to be left alone, but the check that protected it never matched, so it had never once run. On phones whose fast charging uses a charge pump, the value written sits below what the pump needs, and firmware falls back to slow charging until the next reboot.
- `acc -t` can no longer leave your phone with no daemon and charging uncapped, whether it is piped, interrupted, or simply finishes.
- `acc -t` no longer waits forever for a cable: it reports how long it has waited and gives up after three minutes.
- Switch discovery runs at all: every invocation used to abort claiming a scan was already running, so all three of AccA's scan buttons did nothing.
- Switch discovery builds the switch list itself when it is missing, instead of telling you to run a command that does not build it.
- A switch scan no longer leaves your phone unable to draw current: the current limits it writes while testing are now put back, instead of being left at zero.
- A switch scan no longer grades the rest of its list against a phone it has already stopped from charging, and says so plainly if charging does not come back between tests.
- `--apply` now refuses to lock a switch chosen from a run the scan itself flagged as unreliable.
- A switch scan no longer reports the daemon as restored when what it found was the process that had just killed it.
- Switch discovery now restores each node it wrote, instead of matching whole recorded lines.
- A diagnostic bundle from a phone that hung at boot now carries the kernel logs.
- An unplugged Pixel no longer polls at the plugged-in rate all night, which cost it around eight times the idle CPU of a phone on the switch path.
- Pausing charging while a listed app is in the foreground works on firmware-limit phones, and an unplugged phone no longer pays for the check it cannot act on.
- Switch testing no longer rejects a switch that works, on phones whose kernel keeps reporting "Charging" after the input is cut, which could leave you with no charge limit at all.
- Putting charging back after a switch test is no longer slow on those same phones. The check that decides charging has resumed was left blind during the restore, so a search that should stop at the first switch that works walked the whole list instead, around thirty five seconds an entry, with the daemon out of its loop and your limits unenforced for all of it.
- Your shutdown level is honoured on Pixel and other firmware-limit phones, where it was accepted and then ignored, letting the battery run to empty instead of stopping where you asked.
- A Pixel resting at its charge limit overnight no longer wakes ten times more often than it needs to.
- A phone with no charging switch chosen yet no longer searches for one over and over while unplugged, which cost about a tenth of a processor core continuously and found nothing, because there was no charger to test against.
- A search for a charging switch can no longer hold a plugged phone off charge for minutes on end. It had no time limit at all: a candidate that does not work costs about thirty five seconds to rule out, there are well over a hundred to try, and the search runs up to three times per attempt. While it ran, nothing else ran either, so your charge limit and temperature limit were not being enforced and the phone looked idle to every health check. The search now stops after about two minutes and continues from where it stopped the next time, so a phone with an awkward switch still ends up with one. `acc -t` is untouched and still tests every candidate.
- Reading the battery for the app's status feed no longer starts three dozen short-lived processes each time.

Added
- Diagnostics now say when your phone's own battery authentication has failed, which pins it to a slow 5V charge no matter what the charger offers and is nothing ACC can override.

**v2025.5.18-6.5.1-rc22 (202505325)**

Everything since rc21, in one release.

Fixed
- ACC no longer reports charging with nothing plugged in.
- A phone that charges with an inverted current sign is no longer read as discharging.
- A fuel gauge too slow to move no longer blinds every limit at once.
- The learned charge direction now settles instead of re-learning forever.
- The temperature limit now works on Pixel and other firmware-limit phones.
- Charging no longer resumes above your maximum temperature.
- "Never sit above the limit" no longer leaves a Pixel unable to charge.
- Switch discovery no longer interrupts charging at any level on every plug.
- `acc -e` on an unplugged phone no longer leaves it unable to charge.
- Startup restore no longer overwrites a live charger negotiation.
- A new current limit is now actually written the first time it is set.
- A failed apply no longer leaves ACC believing a limit is in force.
- The daemon no longer releases a current limit while you are setting one.
- The daemon now re-reads the config when it decides, not the copy it started with.
- Clearing a current limit no longer lets the daemon put it straight back.
- `acc -s pause_capacity=999` is refused instead of silently storing 80.
- An idle phone no longer wakes the charger driver every second.
- Healing the state cache no longer re-applies a limit already held.
- The daemon can recreate its working directory after a reboot.
- An unwritable data partition no longer stops the daemon silently.
- The switch scan no longer disturbs current limits while restoring nodes.
- The write ledger is no longer empty on firmware-limit phones.
- The collapsed fast-charge detector can now fire; it never could.
- Diagnostic bundles now contain the kernel logs they claim to contain.
- Bundle entries name the file they hold, not the command that made it.
- An empty source is reported as empty, not as a failure.
- A missing log directory no longer aborts the command writing to it.
- Battery info reports correct watts on inverted-sign phones.

Added
- Charger voltage, input current limit and negotiated supply type are recorded on every pass.
- A polarity that flips with the charge mode is recorded, so ACC stops re-learning it.
- Every power-off ACC performed or refused is collected in the diagnostic bundle.
- The test suite is installed with the module, so a flashed build can check itself.
- A voltage limit is refused on phones with no voltage-control node.

Changed
- ACC lets the charger re-negotiate once per plug, only from the 5 V floor.
- A supply at 6 V or more counts as a fast session without a vendor node.
- Every USB re-detection honours `acc -sk off`, the rate limit and the ledger.
- The charger-node list is resolved once per process instead of twice a second.
- Boot and voltage applies skip the write when the value already matches.
- Byte counts in a bundle describe what reached it, not what the source claimed.
- Installing the module clears the marker an interrupted test run leaves behind.

**v2025.5.18-6.5.1-rc21 (202505301)**

Everything since rc20, in one release.

Security
- **An argument to `acc -f` could run commands as root, and one to `acc -n` as the shell user.** rc21 closed this in the pattern-matching helper, but two other paths still handed a caller's text to a shell. Charge-once passed its trailing options through `eval`, which it never needed (they are already separate words), so `acc -f '$(some-command)'` executed it with full privileges. The notification helper embedded its message inside a double-quoted `su -c` string, so the same trick ran as the shell user, and the daemon feeds switch names and limit values through that helper too. Charge-once now calls the helper directly and notifications embed the message single-quoted with any quote escaped, the same way stored config strings have always been handled. Anything that passes an unchecked string to `acc` (a script, a macro, a front-end) was affected. Found by fuzzing every argument-taking option.

Fixed
- **Upgrading could silently not happen.** `/data/adb/vr25/acc` is the path everything resolves through: the root manager's `acc` command, service scripts and the app. Where `/data/adb/modules` did not exist at the first install (normal on KernelSU, where that directory only appears once a module is present) ACC installed there as a real directory. Every later upgrade then installed into `/data/adb/modules/acc` and tried to repoint the old path with `ln -sf`, which cannot replace a real directory: it printed "Is a directory", exited 0, and the phone kept running the first version ever installed. Device-proven: two upgrades on a KernelSU Pixel 6a with `acc -v` still reporting the old version afterwards. The install now moves the stale directory aside, verifies the link resolves to this install, and rolls back with a message instead of exiting 0 on a broken upgrade.
- **A charging config that was a directory killed the front-end.** `config.txt` can exist and not be a regular file, left by a bad backup restore or a botched script. The check read that correctly as "no config" but the remedy wrote the defaults to that same path, which failed with "Is a directory" and took the caller down: `acc -i`, `acc -s` and every `acc -D` died, so the daemon could not be started to repair the very thing that was broken, and nothing said why. A garbage config FILE started the daemon fine; a directory killed it before it could open its log. The obstruction is now moved aside, your own limits are restored from the daemon's last known-good copy rather than silently reset to the defaults, and the write can no longer abort the caller.
- **An idle phone paid for the app's status feed.** The state export AccA reads was rebuilt in full on every daemon pass, forever. Measured on a Mi A3 with the screen off, ACC was starting 2333 processes a minute, about half of one CPU core, doing nothing a user asked for; the export accounted for 1673 of them. Three parts: the device description (model, chip, Android build, ACC's own version) was rebuilt from scratch each pass although it cannot change while ACC is running, the JSON string escaper ran three commands per value on every value, and the whole snapshot was republished whether or not anything had changed. It is now built once, escapes without spawning anything for ordinary values, and publishes when the battery level or charging state actually moves, otherwise at most every 30 seconds. Idle cost fell by about 85%, to at or below upstream ACC measured under the same conditions, with no change to what the app sees.
- **Removing a blocked setting did nothing.** When the blocked list started recording what a setting was writing when the phone went down, each line gained two extra fields, but removal still compared the whole line against a bare path, so it never matched: `acc -sb rm` reported success and changed nothing, and the app's unblock button had no effect either. Removal now matches on the path alone, and entries saved before the change still work.
- **A corrupt saved config could take the daemon down with it.** The daemon keeps a copy of the last config it read successfully, and falls back to that copy when the live one is unreadable. It loaded that copy without checking it first, so a copy that was itself truncated (a full data partition, or a crash mid-copy) caused the exact parse failure the fallback exists to survive, at the worst possible moment. The fallback is now checked before it is trusted, and a copy that fails the check is discarded rather than retried forever.
- **An out-of-range charge limit was accepted with a success tick.** rc21 stopped `acc 12abc` being read as a capacity, but a numeric value outside the valid range still passed: `acc 999` printed the success mark and quietly stored 80% instead. It failed safe (a limit was always applied, never removed) but you were never told the number you typed was not the number in force. Values outside 0-100 percent or 3001-5000 mV are now refused.
- **Exporting your logs produced nothing and reported failure.** `acc -le` (and the Export logs menu item) built the bundle by calling an internal battery helper without an argument. That helper read its first argument unguarded, so the strict-mode shell aborted the export at that point: no tarball was written and the command exited with an error, every time, on every phone. The helper now tolerates the bare call, which was always meant to return a plain battery dump and touches no battery state. Exporting now writes the archive to the ACC data folder and copies it to Download as documented.
- **A node that crashed your phone could still be re-tested and re-suggested.** `acc -t` writes every candidate switch to find one that holds, and `acc -p` suggests candidates found in the power-supply logs. Neither consulted the crash blacklist, so on the one phone where that list is not empty, the node that took it down was written again by the test and offered back by the suggestion. Both now skip blacklisted nodes and say so; `acc -sb rm <node>` allows one back.
- **Charging held far below what the charger can deliver, where upstream ACC charged fine.** Live meter nodes (`*_now`, an instantaneous reading, not a setting) were accepted as charging-switch candidates, so the recorded "on" value was whatever current happened to flow during the scan. A Redmi Note 9S got an entry pinning input at 602 mA, rewritten on every sweep. Meters are no longer candidates. A switch you picked yourself is kept.
- **Switch re-armed on every pass once the battery sat above the limit.** The counter bounding this to two attempts could only be reached below the pause level, while the attempt only runs above it, so it never advanced. About 40 switch writes in 21 minutes on a Redmi Note 10 Pro, held correctly the whole time but needless wear, and enough momentary on-states to trip the "switch not holding" warning about a switch that was holding.
- **Report called a working charging switch broken.** It checked `input_suspend` regardless of which switch you use, so on `charging_enabled` phones that unused node read 0 and the report cried fault. It now reads your configured switch, both path forms, and takes the off value from your config. Same fix covers the overcharge line, which could fire on a phone holding the cell through idle mode.
- **Every diagnostic showed an empty ACC handler version.** The identity line read the handler with `head -1`, but `acc --version` prints a blank line before the version, so that field came out empty in every bundle anyone ever sent us. It now takes the first non-empty line, and where the handler prints nothing at all it tries the other sources and says the version is unreadable rather than leaving a blank that reads as "no handler".

Added
- **A charge setting that restarts your phone AFTER it is written is now caught too.** The crash journal only ever caught a phone that died *during* a write; a write that returned and killed the kernel a few seconds later left no trace, because the record was deleted the moment the write succeeded. The last completed write is now kept until a scan exits cleanly, so a record that outlives its scan means the scan wrote that setting and never finished. Blaming it needs three things to agree: the record must be from an earlier boot, the phone must report an actual panic or watchdog restart, and the recorded path must be a real one. Anything less is discarded, because blocking a healthy setting is its own way of breaking someone's charging. A scan that is merely cancelled, or killed, blocks nothing.
- **`acc -ss f` runs Find my switch**, the same engine the app calls, without going through the app.
- **`acc -ss <n>` picks a switch by its number** in the `acc -ss::` list, so the list you read is the list you can select from. Setting a switch could previously only be done through the interactive picker, which a script cannot drive.
- **`acc -U a` uninstalls without asking.** The confirmation reads from the terminal, so over `su -c` or from a front-end with no console attached it saw end-of-input, took that as "no", and exited reporting success while removing nothing.
- **`acc -sb` reaches the crash blacklist.** Nodes that took your phone down during a switch scan are restored and permanently blocked, but the list was only reachable by calling the engine at its full path. `acc -sb` lists them, `acc -sb rm <node>` allows one to be tested again, `acc -sb clear` allows all. Also in AccA under Blocked settings.
- **Report now says when your ROM is throttling charge rate.** Many ROMs limit charging for heat through a thermal level ACC never touches, and owners read the result as ACC throttling them. When that level is present and non-zero the report states it with Android's thermal status, and says plainly it is the ROM, not ACC.

Fixed
- **A 9V charger could drop to 5V.** The stall re-kick that re-runs charger input detection had no rate limit, so where the stall check misfires it fired every pass (10 times in 10 minutes on a Redmi Note 9S, whose kernel reports current unsigned). Repeated re-kicks collapse a QuickCharge handshake to 5V near 1.8A. First re-kick still fires immediately; only repeats inside five minutes are dropped.
- **The backup cut against a leaking switch could silently do nothing.** It picked the first writable node and reported success without checking charging actually stopped. On a OnePlus 8 where `input_suspend` is the only candidate and the driver re-enables it, the safety net became a no-op and the cell ran past the limit. The cut is now verified, reverted if it did not hold, and the failed node is not rewritten every loop.

User reports and a deep stress-test pass. The pause and shutdown logic is unchanged; these sit around it.

Security
- **An argument could run commands as root.** `acc '$(some-command)'` executed it: the pattern-matching helper built a `case` as text and evaluated it with your argument pasted in. Your first argument passes through it three times per call, so anything feeding `acc`/`acca` an unchecked string could run it privileged. The pattern is still evaluated, the value no longer is. Present in every earlier release and upstream.

Fixed
- **The daemon could not restart if its working folder was missing.** ACC's `/dev` folder is wiped each reboot and rebuilt by the start script; where that had not run, every manual start died opening a lock file inside the absent folder. Start button, `accd --init` and menu restart all dead-ended with "No such file" and a -1% reading. The daemon now creates the folder before taking the lock.
- **The uninstaller now recovers any phone, not just Magisk ones.** It needed full busybox to start, so it could refuse to run on KernelSU, APatch or bare recovery, and restored only a fixed switch list. It now runs on stock tools, replays the value ACC recorded for whatever switch you used, and reports plainly when it cannot reach an encrypted data partition instead of faking success.
- **Earliest-boot write is safer, and the #197 guard reads the real mount.** The pre-Android charge write is skipped unless it can first record what it is doing, so a full or read-only data partition never keeps an unundoable write. The PATH check reads the actual `/system` filesystem type instead of trusting leftovers, closing a Magisk-to-KernelSU case that could re-trigger the #197 boot loop.
- **A menu key could silently erase your charging switch.** Any unrecognised key in the switch selector (including `z`, which exits every other menu) reset it to Automatic and reported success. `z` now exits, unknown keys re-prompt.
- **A mistyped command reported success.** `acc --bogus` printed help and exited 0. Unknown commands now exit 2.
- **A mistyped restore path looked like it worked.** `acc -s /wrong/path` printed the config and exited 0. Now reports "No such config file" and exits non-zero.
- **`acc 12abc` silently became `acc 75`.** Anything starting with a digit was taken as a capacity, the rest discarded, the default substituted, with a success tick. Now rejected.
- **`acc 0` wrote a negative resume level.** Now floored at 0.
- **Log auto-export had been dead since rc15.** An edit turned the character class `[127]` into literal `127`. It now fires on codes 7 and 10, and the docs in all five languages match again.
- **A resume temperature well below max was overwritten.** `max_temp=55` with `resume_temp=40` stored 45. A wide gap is valid and the daemon already ran one. Your value is kept, holding only that resume stays below max and that anything under 15C is rebuilt so charging cannot stick off.
- **ACC could rewrite a value the phone kept refusing, forever.** Where the charger's negotiation owns the input-current nodes, a cap above the negotiated current is reverted instantly and ACC rewrote it endlessly (137 writes in two minutes). It now backs off after five rejections, retries occasionally, and says once that the charger's limit is in force. The battery-side cap is unchanged.
- **Cooldown made the battery percentage flicker.** Holding the phone as "charging" dropped and re-took Android's override every cycle (19 times in two minutes). It now keeps the override and refreshes inside it, handing state back when cooling ends.
- **Simultaneous config writes could corrupt it.** Genuinely concurrent writes could scramble a line. It always fell back safely and predates the fork; even so, each write now builds a private copy and swaps it atomically.
- **Another program writing the config could knock the daemon over.** A crude `echo >` or `sed -i` caught half-finished could trip the daemon, skip a check, or under a flood stop it. It now reads defensively and falls back to the last complete config, so the limit is never dropped.

Removed
- **The Xiaomi charge-pump warning and its opt-in current veto.** Both rested on the premise that 3000 to 5499 mA blocks a charge pump. The one report behind it turned out to be a 5V/1.6A charger, and later ACC writing 500 mA from a wrongly recorded default. That phone has no charge pump. Nobody ever observed the guarded behaviour and it told at least one person their correct setting was wrong. The fast-charge cooldown guard stays.

Added
- `acc --export <file>` writes your config and refreshes on re-run. The old export silently refused to overwrite, so repeat backups went stale.
- Backup and restore documented in `acc --help`, including that restore merges rather than replaces.

Unchanged
- Pause/resume/shutdown logic, the charging switch, AMPS and AccA compatibility. Every command AccA issues returns what it returned in rc20.

Note for scripts
- Unknown commands now exit 2 instead of 0. `acc -L` was never real and is affected.


**v2025.5.18-6.5.1-rc20 (202505300)**

rc19 could let a battery charge to 100% with the limit on. If you are on rc19, update.

Fixed
- **Overcharge.** rc19 froze Android's battery state and never released it, so the phone showed "charging" after unplugging, the percentage stopped, and the limit could never fire. Decisions now read the kernel, never a value ACC wrote. Four independent guards.
- **AccA showing a different percentage from Android.** The state export shared one scratch file between writers, so daemon and app truncated each other. 13 of 40 reads malformed before, 40 of 40 clean after.
- **Importing a config wiped every setting.** `acc -s <file>` handed the staging file to the rule editor, which used the same path as its scratch. A 389-line config came back as its rule lines, with a tick. Edits now publish by atomic rename and an empty import is refused.
- **Capacity Mask did nothing on Pixel and Tensor.** Those hand the limit to firmware and skip the branch applying the mask. Long-standing.
- **Daemon log grew without bound on the same phones.** 10.7 MB after 24 minutes on a Pixel 9a, in RAM, never freed. Same build on a Mi A3 sat at 128 KB.
- **Fast charge died at the cooldown level** on VOOC / SuperDart / HyperCharge. Toggling the switch ends the handshake and drops to 500 mA until replug. Cooldown is now skipped during a live fast-charge session, announced once a day. Confirmed by the reporter. Opt out: `/dev/.vr25/acc/.fcguard-off`.
- **Two hazards inherited from before the fork.** A numeric but absurd `shutdown_temp` (like `9`) powered the phone off at room temperature; the current limit was released for seconds on every resume.
- Removing ACC now hands Android's battery state back instead of leaving a fake percentage until reboot.

Added
- Warning when something else keeps changing your limit. On Pixel, ACC, Adaptive Charging and Battery Defender write the same node; two owners fighting collapses fast charging and wedges wireless.
- Notice for Xiaomi owners whose current cap sits below what the fast-charge pump needs, with the command to clear it.
- A timestamped ledger of every node write.

Verified on a Pixel 9a (firmware-limit path) and a Mi A3 (switch path): 44/44 and 31/33, plus 12/12 endurance (10 minutes held with no overshoot, 6/6 pause-resume cycles, 3/3 temperature stops and releases).

**v2025.5.18-6.5.1-rc19 (202505299)**

Standby drain, deep-fixed. A 7% overnight drain report checked out: the daemon burned about a quarter of a CPU core around the clock doing nothing. Measured idle on a Mi A3: ~30 dumpsys calls per minute and 20+ process spawns per second. Four sources:

- Every battery-percent check spawned a dumpsys, several times per loop. The Android level is now cached and re-read only when the kernel percent moves. Devices with no kernel percent node keep the old behaviour.
- With Capacity Mask off, the mask code still called `dumpsys battery reset` every loop forever. It now resets once when you turn it off. With the mask on, the three writes fire only on a real change (plug, percent, 0.3C), plus a periodic re-assert so an external reset cannot silently kill the mask.
- Every 1-second tick spawned a sleep and a stat, roughly 200,000 forks a night. Waits now tick on a timed builtin read of a wake fifo, and the config watch is a builtin test. Edits still apply within a second.
- The charger-node list was recomputed with ls+grep every second inside the idle nap. Now computed once.

New: plugged-and-paused holds in a 30-second fork-free nap instead of the 9-second cycle. Unplugging or editing wakes it within about a second. Resume detection moves from 9s to 30s worst case against ~1%/hour self-drain.

Measured in the real overnight state: the old daemon used 31% of a core and was 83% of all process activity on a sleeping phone; rc19 runs it at 8% with fork rate down 6x and zero dumpsys at rest. AccA audited too, no change needed.

**v2025.5.18-6.5.1-rc18 (202505298)**

Status bar stuck on "charging" after unplug, on Capacity Mask phones. The mask decided plugged-or-not from the charging reading, unreliable on phones reporting charging as negative current or holding the battery idle by bypass, so the bar could freeze until reboot. AccA's dashboard was always correct.

- Capacity Mask: plug state now follows the physical charger (present/online), not the current reading. Verified on a Mi A3.

Temperature pause also fixed. Setting max temperature alone did not stick: ACC reset it to 50C internally, so charging never paused at your limit. One user set 40 and watched it reach 43. Three sanitizer faults, all silently changing a valid setting:

- max_temp reset. Lowering it below the default cooldown temperature collapsed the band, and the collapse guard reset all three to 45/50/40. It now rebuilds the band around your max_temp (cooldown 5 under, resume 10 under), so 20 to 60C holds.
- Resume window. A resume more than 10 below max was snapped to one degree under max, a 1 degree swing that toggled rapidly and discarded your cooldown value. Now capped at a 10 degree swing.
- Shutdown below max. With max 56 to 60C the shutdown cutoff could sit below it, so the phone shut down before it ever paused. Shutdown now sits at or above max_temp.

Verified on a Mi A3 across eight temperature scenarios.

**v2025.5.18-6.5.1-rc17 (202505297)**

Critical fix for every OverlayFS root: KernelSU (including Next, SukiSU, ReSukiSU), APatch, and Magisk with magisk_overlayfs. Installing ACC could make every app crash after the next reboot, with the root manager itself refusing to open and recovery the only way out. Magisk alone was never affected.

Already stuck? Flash this build from recovery. It strips the bad overlay in place. You do not have to uninstall ACC first.

- The cause. ACC shipped a `system/` overlay. Magisk magic-mounts those file by file; OverlayFS roots mount the whole directory, relabelling the merged `/system/bin` so `/system/bin/sh` stops being executable and everything that shells out dies with "Exec '/system/bin/sh' failed: Permission denied" (GitHub #197).
- The installer now detects how the root manager mounts modules instead of assuming Magisk because a modules directory exists. On OverlayFS the overlay is never created, an existing one is removed before staging, and skip_mount is set.
- It fails safe. Anything not positively confirmed as Magisk magic mount takes the OverlayFS path, so an unknown root or a recovery flash with no root environment is safe.
- Nothing is lost. `acc`, `acca` and `accd` are symlinked onto `/data/adb/ksu/bin` and `/data/adb/ap/bin`, already on PATH. Magisk keeps its overlay.
- The flashable zip never shipped the AMPS engine. `install.sh` copied only `install/*`, but the engine lives at the package root, so flashing left the module on whatever engine it had (a test phone on rc17 was running v7.1.3) and a clean flash got none. Now copied on every install.

AMPS (Find my switch) v7.1.6, four fixes to the charger/speed report, which was accusing healthy phones of charging slowly. Found from a Realme GT Neo 2 (65W SuperDart).

- Charger not found on the `ac` path. AMPS looked only at usb/main/dc/wireless/pc_port. On Qualcomm and OPLUS the mains path reports online on `ac` while usb sits at 0, so the report said "not plugged" mid-charge with current and voltage at zero. It now scans every supply and takes whichever the firmware marks online.
- A negative cap is an error code. -22 is -EINVAL. AMPS stripped the sign and reported "IC cap (CCC)=22mA", suppressing the fallback and firing a false IC/THERMAL-CAPPED verdict. Caps now reject negatives.
- Virtual charger supplies must not win. Pixel and Tensor expose control supplies (gccd, main-charger, rt9471) that report online=1 and sort ahead of usb, so the report showed battery voltage as bus voltage (3996mV on a 9V PD charger). The real port is now preferred: a Pixel 9a reads 8225mV and 2153mA.
- Model spoofing. A ROM faking `ro.product.*` (this one claimed to be a Galaxy S23 Ultra) filed its switches under someone else's model. AMPS cross-checks the vendor partition, device tree and charger-driver family, and keys the database on hardware identity.

**v2025.5.18-6.5.1-rc16 (202505296)**

Update delivery. Magisk's module updater was pointed at the wrong branch and the zip filename did not match the manifest, so even a version that showed could not download. No charging change; AccA's updater reads the releases API directly and was unaffected.

- updateJson tracks the active release branch.
- Flashable-zip name is deterministic and matches the manifest.
- Update popup shows the current changelog.

**v2025.5.18-6.5.1-rc15 (202505295)**

Brick-safety hardening. A bad charging switch can no longer loop a device into a panic/reboot cycle, the class that ends in a Qualcomm CrashDump / EDL on some phones. Both guards are additive and fail-open. Reboot-verified on a Mi A3 (mksh).

- Early-cap brick-safe (GitHub #305). The pre-daemon write honours the panic blacklist and write-ahead-journals itself, so a switch that panics mid-write is blacklisted and early-cap self-disables after one crash instead of re-firing every boot. +5 selftest cases.
- rebootResume loop-guard. Reboots at most twice, then warns. The counter resets on a healthy charge.

**v2025.5.18-6.5.1-rc14 (202505294)**

- Fast charge: charge-control writes are idempotent (read before write), so ACC no longer re-triggers AICL/APSD and drops fast charge on charge-pump / PPS / PD / VOOC / wireless phones. A stray drift still re-arms instantly.
- Reliable stop: the Stop button always kills the daemon; `acc -D restart` stops the old one first; stopping at or above the limit no longer overshoots.
- Robustness batch (device-verified on mksh): fixed `acc -s mcc=` permission-denied spam; the temperature-throttle path is idempotent; empty or garbage sensor reads and malformed configs can no longer abort the daemon; CLI hardening (`acc -H` at 0%, `at` rewrite, config comma parsing).
- AMPS v7.1.4: reports your fast-charge resume mechanism, a software re-kick on Qualcomm (`apsd_rerun`/`rerun_aicl`/`dp_dm`) or MediaTek (`en_power_path`), or replug-only on newer PD-glink/UCSI chargers. Probes write-only trigger nodes by name.

**v2025.5.18-6.5.1-rc13 (202505293)**

- Plugged-but-draining recovery on dual-path PMICs (charge vs discharge decided by the coulomb-counter slope, immune to a flipping current sign); uninstall reliably restores stock charge nodes and is mksh-safe.

**v2025.5.18-6.5.1-rc11 ... rc12 (202505291 - 202505292)**

- `acca --state` adds charger-input telemetry (mV/mA) and a physics-based charge-speed class, universal across vendors with no protocol node.

**v2025.5.18-6.5.1-rc10 (202505290)**

- Stopped constant USB re-negotiation when no limit was set (Mi A3: 16 re-kicks/30s before, 0 after); config-apostrophe fix; in-app updater points at this fork.

**v2025.5.18-6.5.1-rc6 ... rc9 (202505286 - 202505289)**

- AMPS hardening: class-aware stress test that never demotes a working firmware %-limit (Pixel `charge_stop_level`) to a battery-draining cut; thermal-level node detection; clearing a limit restores the nodes and re-kicks USB in every charge state.

**v2025.5.18-6.5.1-rc1 ... rc5 (202505281 - 202505285)**

- Charge limit anchored to the fuel gauge instead of the lying status/current node; self-healing current polarity; `soc:google,charger` (Pixel 4a/5-class) native stop/start managed directly; the "current limit won't stick" save-hang fixed.

**v2025.5.18-stable.6.5 (202505280) - first fork release**

- AMPS (Adaptive Multi-device Probe & Selector): a universal charge-switch finder. Probes the whole power-supply tree, live-tests every switch type (bypass, cut, drain, native %-limit), leak-verifies that a switch truly holds, and recommends the safest, writing only reversible switches and restoring on exit. Built into AccA as "Find my switch".
- Folds in the full 6.4 / 6.4.1 reliability line: boot-window overcharge cap, sustained-hold switch locking, faster resume, corrupt-config survival, corrected current and self-healing polarity on Pixel and Tensor.
- Device-verified on Xiaomi Mi A3 and Pixel 9a. Systemless; works on any root (Magisk / KernelSU / APatch). Existing configs unchanged.

Full pre-fork history (VR-25 ACC 6.4.1 and earlier): https://github.com/VR-25/acc
