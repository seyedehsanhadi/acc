# ACC - Advanced Charging Controller

Community fork of VR-25's ACC, maintained by seyedehsanhadi.

- Telegram group: https://t.me/+hU1oF-BCf5hmM2Rk
- Fork: https://github.com/seyedehsanhadi/acc   .   AccA app: https://github.com/seyedehsanhadi/AccA
- Upstream (original): https://github.com/VR-25/acc

Changes since the fork baseline (v2025.5.18-stable.6.5):

**v2025.5.18-6.5.1-rc20 (202505300)**

rc19 shipped a bug that could let a battery charge to 100% with the limit switched on. If you are
on rc19, update. This release exists to undo it.

What went wrong. ACC can freeze Android's battery state, which is how the Capacity Mask shows you
a different percentage than the real one. rc19 added a marker so that only the mask would release
that freeze, but the cooldown cycle freezes the same state and never sets the marker. rc18 had
been clearing it every loop by accident, so nobody noticed. Once the cooldown cycle ran, the
freeze became permanent: the reading stopped moving, the phone still showed charging after the
cable came out, temperature went stale, and because the charge limit reads Android's level, the
limit could no longer fire. Reproduced on a Mi A3, which reported AC powered while the cable state
said discharging.

The fix has four parts, so no single mistake can bring it back. The marker now lives inside the
function that does the freezing, so every caller sets it rather than only the one we remembered.
The daemon clears any freeze once at startup, which covers a phone upgrading from rc19 with a
frozen state and no marker. While any freeze is in force, the battery percentage used for control
decisions is read from the kernel instead of from a value we wrote ourselves. And if Android and
the kernel ever disagree by more than 5 points, the kernel wins, so no freeze from any source can
stop a pause. The rule behind all four: what you see may follow Android, what charges must follow
the kernel.

Uninstalling now hands Android's battery state back. Removing rc19 while a mask or a cooldown
freeze was in force left the phone showing a fake percentage until reboot.

Fast charge no longer dies when the cooldown cycle runs. On phones whose charger negotiates a
proprietary fast mode (VOOC, SuperDart, HyperCharge), that handshake does not survive the charging
switch being toggled, and the charger drops to 500 mA USB until the cable is physically unplugged.
So above the cooldown level the cycle was not slowing a fast charge down, it was ending it for the
rest of the session. A Realme GT Neo 2 owner saw 4400 mA below the cooldown level and 500-600 mA
stuck above it, with normal speed when ACC was off; that phone is confirmed fixed. ACC now skips
the cooldown cycle while a fast-charge session is live and tells you once a day that it did.
Temperature protection is unchanged: max_temp still pauses charging and shutdown_temp still fires.
This only affects phones that expose a vendor fast-charge node and have cooldown turned on. To
switch it off, create the file `/dev/.vr25/acc/.fcguard-off`.

Two hazards inherited from before the fork, both found while auditing the above:

- A numeric but absurd `shutdown_temp` was accepted as valid. A hand-edited or restored config
  containing `9` powered the phone off at room temperature. Device-proven, now band-checked, and
  the same class of problem with `shutdown_capacity` at a high battery level is checked too. Real
  over-temperature and low-battery protection still fire.
- The charging-current limit was released for a few seconds on every resume, because on a phone
  whose charging switch is a current node, the switch's ON value is the uncapped default. The
  limit is now re-applied immediately on resume. This is the "my 1000 mA limit is ignored when
  charging resumes" report.

Also new: a write ledger recording every node write with a timestamp, so the next report of this
kind can be answered from evidence instead of guesswork, and a notice for Xiaomi owners whose
current limit sits in the range that stops the fast-charge pump from engaging.

**"AccA shows a different percentage from Android."** This one has a specific cause and it is
fixed. AccA reads ACC's state export, and that export was built into a single scratch file shared
by every writer. The daemon refreshes it on its own loop and every `acc --state` call refreshes it
too, so an app polling while the daemon ticks meant two builds running at once, one truncating the
other, and the half-written result being published as if it were complete. Measured on a Mi A3
before the fix: 13 of 40 reads came back as malformed JSON, including 3 of 16 issued strictly one
at a time, because the daemon alone is enough of a second writer. An app handed that either shows
stale numbers or falls back to zero, which is exactly what people were seeing. After the fix, 40
of 40 reads are well formed across serial, two-way and three-way overlap. The same shared-scratch
mistake in the switch parser is fixed too.

**Three things were silently dead on Pixel and Tensor phones.** Those devices hand the charge
limit to the firmware, and that path returns early in the daemon's loop, skipping everything after
it. Two of the casualties are fixed here:

- The Capacity Mask did nothing at all. Turning it on stored correctly, reported correctly, and
  had no effect whatsoever. It now applies on these phones like everywhere else.
- The daemon trims its own log to stay under 256 KB, and the trim was in the skipped region. That
  log lives in RAM. A Pixel 9a was measured at 10.7 MB after 24 minutes, roughly 450 KB a minute,
  never released until reboot; the same build on a Mi A3 sat at 128 KB. The trim now runs on every
  phone, at the same rate it always did on the others.

Pausing on idle apps and on encore mode are also skipped on those phones. Restoring them means
changing how charging is held on a whole device family, so it is not being guessed at in a release
whose job is to undo damage. It is written up for the next one.

Neither of these is new. Both trace back to the original native-limit work on the old 6.x line,
long before this fork existed, so every Pixel and Tensor user has had them all along.

One more for Pixel owners: ACC, Android's Adaptive Charging and Google's Battery Defender all
write the same firmware limit. When two of them disagree, each correction re-triggers the charger
state machine, and that is what collapses fast charging and wedges the wireless path. ACC now
notices when something keeps undoing its limit and says so once, suggesting you turn Adaptive
Charging off and let one thing own it. It is a message only; the limit is enforced either way.

**v2025.5.18-6.5.1-rc19 (202505299)**

Standby battery drain, deep-fixed. A field report of 7% overnight drain (about twice normal) checked out: the daemon was quietly burning about a quarter of a CPU core around the clock while doing nothing. Measured on a Mi A3 before the fix, sitting idle: about 30 dumpsys calls into Android per minute and 20+ process spawns per second, all night, with every feature at rest. Four sources, all fixed:

- Every battery-percent check spawned a full dumpsys (a binder call into system_server), and the cap checks run several times per loop. The Android level is now cached and re-read only when the kernel percent actually moves. Blind devices with no kernel percent node keep the old per-call behavior.
- With the Capacity Mask off, the mask code still called `dumpsys battery reset` every loop, forever, clearing overrides that were never set. It now resets once when you turn the mask off, then stays silent. With the mask on, the three dumpsys writes fire only when something changed (plug state, percent, or 0.3°C of temperature), plus a periodic full re-assert so an external reset can never silently kill the mask - which also means a daemon reload can no longer strand a frozen status bar.
- Every 1-second wait tick spawned a sleep and a stat: roughly 200,000 forks a night spent waiting. The waits now tick on a timed builtin read of a wake fifo (zero forks), and the config watch is a builtin file test. Settings edits still apply within a second, and writing anything to the fifo wakes the daemon instantly.
- The charger-node list was recomputed with ls+grep every second inside the idle nap. Now computed once.

New: plugged-and-paused - the overnight-on-charger state - holds in a 30-second fork-free nap instead of the 9-second cycle. Unplugging or editing settings still wakes it within about a second. Resume detection moves from 9s to 30s worst case, against a battery that self-drains about 1% an hour: no practical change, far fewer wakeups.

Measured on the same phone in the real overnight state (screen off, plugged, holding at the limit): the old daemon used 31% of a CPU core and was 83% of all process activity on the sleeping phone; rc19 runs the same state at 8% of a core with the fork rate down 6x, and zero dumpsys calls at rest. AccA was audited too: its meter only ticks while the screen is on and stops when it goes off, and update checks run when you open the app - no change needed there.

**v2025.5.18-6.5.1-rc18 (202505298)**

Fixes a status bar stuck on "charging" after you unplug, on phones that use the Capacity Mask. The mask shows a remapped battery percentage by writing Android's own battery state, and it decided plugged-or-not from the charging reading. On phones that report charging as a negative current, or that hold the battery idle with a bypass switch, that reading is unreliable, so after the cable came out the status bar could stay frozen on charging until a reboot. It now reads the physical cable directly, so the status bar follows the real plug state. AccA's dashboard was always correct; only the system status bar was affected.

- Capacity Mask: the plug state written to Android now follows the physical charger (present/online), not the charging-current reading. Reproduced and verified on a Mi A3.

It also fixes the temperature pause. Setting a max temperature on its own did not stick: ACC reset it to 50°C internally, so charging never paused at your limit and the battery could run hotter than you asked. One user set max_temp=40 and watched it reach 43. Three faults in the config sanitizer, all cases of a valid setting being silently changed:

- max_temp reset. Lowering max_temp below the default cooldown temperature, with cooldown and resume left at their defaults, collapsed the temperature band. The guard that catches a collapsed band then reset all three values to the 45/50/40 default, so 40 became 50. It now rebuilds the band around your max_temp (cooldown 5° under, resume 10° under), so any value from 20 to 60°C holds.
- Resume window. A resume temperature more than 10° below max was snapped to one degree under max, a 1° swing that toggled rapidly and discarded your cooldown value too. It is now capped at a 10° swing.
- Shutdown below max. With a high max_temp (56 to 60°C) the shutdown cutoff could sit below it, so the phone shut down before it ever paused. Shutdown now always sits at or above max_temp.

Verified on a Mi A3: the acc -s / acc -i round-trip matches on eight temperature scenarios, and the daemon pauses at the set max and resumes after cooldown.

**v2025.5.18-6.5.1-rc17 (202505297)**

Critical fix for every OverlayFS root: KernelSU (including Next, SukiSU and ReSukiSU), APatch, and Magisk running magisk_overlayfs. On those, installing ACC could make every app crash after the next reboot - the root manager itself would not open, and recovery was the only way out. Magisk on its own was never affected.

Already stuck? Just flash this build from recovery. It strips the bad overlay in place, so the next boot comes up clean. You do not have to uninstall ACC first.

- The cause. ACC shipped a system/ overlay (the /system/bin/acc wrappers). Magisk magic-mounts those file by file and leaves the rest of /system/bin alone. OverlayFS roots mount the whole directory instead, which relabels the merged /system/bin: /system/bin/sh stops being executable, so every app and system process that shells out dies with "Exec '/system/bin/sh' failed: Permission denied" (GitHub #197).
- The installer now detects HOW the root manager mounts modules, instead of assuming Magisk just because a modules directory exists. That old assumption treated KernelSU and APatch as Magisk, and is what wrote the overlay onto them in the first place. On an OverlayFS root the overlay is never created, an existing one is removed before the module is staged, and skip_mount is set so a stale one can never be mounted even if it reappears.
- It fails safe. Anything not positively confirmed as Magisk magic mount is treated as OverlayFS, so an unknown root, a future fork, or a recovery flash with no root environment at all takes the safe path. A phone missing the acc PATH shortcut still boots; a phone with a poisoned /system/bin does not.
- Nothing is lost. acc, acca and accd are symlinked onto /data/adb/ksu/bin and /data/adb/ap/bin, which are already on PATH, so the commands behave exactly as before. Magisk keeps its overlay and is unchanged.

- The flashable zip never actually shipped the AMPS engine. install.sh copied only install/*, but acc-compat.sh and amps.sh live at the package root, so flashing a new ACC left the module running whatever engine it already had - a test phone on rc17 was still executing the v7.1.3 engine, three versions stale - and a clean flash got none at all. Only the tarball ever carried it. The current engine is now copied on every install.

AMPS (Find my switch) v7.1.6 - four fixes to the charger/speed report, which was accusing healthy phones of charging slowly. Found from a Realme GT Neo 2 (65W SuperDart) run.

- Charger not found on the `ac` path. AMPS looked for the charger only on usb/main/dc/wireless/pc_port. On Qualcomm and OPLUS phones (Realme, OPPO, OnePlus) the mains path reports online on `ac` while usb sits at online=0 mid-charge, so nothing matched and the report said "not plugged / no input supply reports online" while the phone was actively charging, with the input current and voltage all reading zero. AMPS now scans every supply, takes whichever one the firmware marks online, and reads the limits from wherever they actually live.
- A negative cap is an error code, not a value. -22 is -EINVAL, the kernel saying "property not supported". AMPS stripped the minus sign and reported "IC cap (CCC)=22mA", which also suppressed the fallback to the real ceiling and could fire a false "IC/THERMAL-CAPPED" verdict blaming your charge IC. Caps now reject negatives and fall through to the next source.
- Virtual charger supplies must not win. Pixel and Tensor expose control supplies (gccd, main-charger, rt9471) that report online=1 like a real port but are not one, and they sort ahead of usb. Picking one made the report show the BATTERY voltage as the charger bus voltage (Vbus=3996mV on a 9V PD charger). The real port is now preferred, so a Pixel 9a reads Vbus=8225mV and Iin=2153mA -- exactly what its kernel logs.
- Model spoofing. A ROM that fakes ro.product.* (this one reported itself as a Galaxy S23 Ultra) would file its switches into the device database under someone else's model, misleading every real owner of that phone. AMPS now cross-checks the vendor partition, the device tree and the charger-driver family, says plainly that the model is spoofed, and keys the database on the hardware identity instead.

**v2025.5.18-6.5.1-rc16 (202505296)**

Update-delivery fix. Magisk's built-in module updater now sees new ACC releases - it was pointed at the wrong branch, and the flashable-zip filename did not match the update manifest, so even a version that did show could not download. No change to charging; AccA's in-app updater and notification were already unaffected (they read the GitHub releases API directly, which is also why they were the only surface that caught updates before).

- updateJson tracks the active release branch, so the Magisk Modules tab shows a new ACC the day it ships instead of staying silent on the last stable.
- Flashable-zip name is deterministic again and matches the manifest, so Magisk's one-tap update downloads and flashes instead of failing.
- Update popup shows the current changelog.

**v2025.5.18-6.5.1-rc15 (202505295)**

Brick-safety hardening. A bad charging switch can no longer loop a device into a panic/reboot cycle - the class that ends in a Qualcomm CrashDump / EDL on some phones. Two boot-path guards, both additive and fail-open; healthy boots and normal charging are unchanged. Built, flashed and reboot-verified on a Mi A3 (mksh).

- Early-cap brick-safe (GitHub #305). The one write ACC makes before the daemon starts now honors the daemon's panic-blacklist and write-ahead-journals itself - a switch that kernel-panics mid-write gets blacklisted and early-cap self-disables after ONE crash, instead of re-firing it every boot. +5 selftest cases.
- rebootResume loop-guard. The opt-in "reboot to resume charging" reboots at most twice, then warns instead of rebooting again - so a resume that never works can't loop forever. The counter resets on a healthy charge, so a genuine one-off is never penalized.

**v2025.5.18-6.5.1-rc14 (202505294)**

- Fast charge: charge-control writes are now idempotent (read-before-write), so ACC no longer re-triggers the charger's input negotiation (AICL/APSD) and drops fast charge to slow on charge-pump / PPS / PD / VOOC / wireless phones. Steady charging touches nothing; a stray drift still re-arms instantly.
- Reliable stop: the front-end Stop button always kills the daemon; `acc -D restart` stops the old daemon before starting the new one; stopping at or above your limit no longer overshoots the cap.
- Robustness batch (line-by-line audit, device-verified on mksh): fixed the `acc -s mcc=` "can't create ... Permission denied" spam; the temperature-throttle path is idempotent too; an empty or garbage sensor read and a malformed/truncated config can no longer abort the daemon; and assorted CLI hardening (`acc -H` at 0%, `at` command rewrite, config comma parsing).
- AMPS (Find my switch) v7.1.4: reports your phone's fast-charge resume mechanism - a software re-kick on Qualcomm (`apsd_rerun`/`rerun_aicl`/`dp_dm`) or MediaTek (`en_power_path`), or "physical replug/reboot only" on newer PD-glink/UCSI chargers that self-negotiate. Probes the write-only trigger nodes by name (they are invisible to the read-value node scan). Pairs with AccA's new "Re-kick fast charge on plug" toggle.

**v2025.5.18-6.5.1-rc13 (202505293)**

- Plugged-but-draining recovery on dual-path PMICs (charge vs discharge is decided by the fuel-gauge coulomb-counter slope, immune to a flipping current sign); uninstall reliably restores stock charge nodes; uninstall is mksh-safe.

**v2025.5.18-6.5.1-rc11 ... rc12 (202505291 - 202505292)**

- `acca --state` adds charger-input telemetry (mV/mA) and a physics-based charge-speed class (input watts to slow / standard / fast / super / hyper), universal across vendors with no protocol node.

**v2025.5.18-6.5.1-rc10 (202505290)**

- Stopped the constant USB re-negotiation (every few seconds) when no limit was set - Mi A3 measured 16 re-kicks/30s before, 0 after; config-apostrophe fix; the in-app updater now points at this fork.

**v2025.5.18-6.5.1-rc6 ... rc9 (202505286 - 202505289)**

- AMPS switch-finder hardening: a class-aware stress test that never demotes a working firmware %-limit (Pixel `charge_stop_level`) to a battery-draining cut; thermal-level node detection; clearing a current/voltage limit restores the nodes and re-kicks USB in every charge state.

**v2025.5.18-6.5.1-rc1 ... rc5 (202505281 - 202505285)**

- Charge limit anchored to the fuel gauge (coulomb %) instead of the lying status/current node; self-healing current polarity; `soc:google,charger` (Pixel 4a/5-class) native stop/start managed directly; the "current limit won't stick" save-hang fixed.

**v2025.5.18-stable.6.5 (202505280) - first fork release**

- AMPS (Adaptive Multi-device Probe & Selector): a universal charge-switch finder. It probes the whole power-supply tree, live-tests every switch type (bypass, cut, drain, native %-limit), leak-verifies that a switch truly holds, and recommends the safest - writing only ACC's own reversible switches and restoring every change on exit. Built into AccA as "Find my switch".
- Folds in the full 6.4 / 6.4.1 reliability line: boot-window overcharge cap, sustained-hold switch locking, faster resume, corrupt-config survival, and corrected current / self-healing polarity on Pixel and Tensor.
- Device-verified on Xiaomi Mi A3 and Pixel 9a. Systemless; works on any root (Magisk / KernelSU / APatch). Existing configs are unchanged.

Full pre-fork history (VR-25 ACC 6.4.1 and earlier): https://github.com/VR-25/acc
