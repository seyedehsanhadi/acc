# ACC - Advanced Charging Controller

Community fork of VR-25's ACC, maintained by seyedehsanhadi.

- Telegram group: https://t.me/+hU1oF-BCf5hmM2Rk
- Fork: https://github.com/seyedehsanhadi/acc   .   AccA app: https://github.com/seyedehsanhadi/AccA
- Upstream (original): https://github.com/VR-25/acc

Changes since the fork baseline (v2025.5.18-stable.6.5):

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
