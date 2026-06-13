**v2025.5.18-6.4-rc2 (202505219)** — field-driven fixes (pre-release)
Driven by real reports from the acc-compat companion tester. All changes are additive or stricter; existing
configs are untouched.
- **Daemon survives "no switch works".** `disable_charging` returns 7 on total switch failure and the daemon
  runs under `set -eu`; the three unguarded then-body call sites (`accd.sh`) used to EXIT the daemon — which
  fired `exxit`, re-enabled charging, and skipped the rc19 "no switch holds — scan in AccA" notice. They are
  now `disable_charging || :`, so the loop keeps retrying and reaches that monitor. (mksh-verified.)
- **Pixel/Tensor native-limit resumes instantly.** `native_unlatch` now raises `charge_start_level` to 100
  alongside `charge_stop_level=100`; `sync_native_limit` restores the real levels on the next line. Pulsing
  only the stop level re-armed the FET 1–3 min late on current Pixel firmware (measured on Pixel 9a/tegu).
- **String-valued switches kept.** `filter_sw` now accepts `on`/`off` node values (e.g. nubia
  `charger_bypass`), which the auto-detect value filter previously dropped.
- **New node layout.** `qcom-battery/odm_battery/{input_suspend,charging_enabled,hq_test_input_suspend}`
  added to `ctrl-files.sh` (newer Xiaomi/HyperOS); field-verified to hold + resume.

**v2025.5.18-6.4-rc1 (202505218)** — SAFETY + DIAGNOSTICS (pre-release)
No change to the 6.2/6.3 resume logic or to how charging is controlled on a working device; every change is
stricter, append-only, a clamp, or diagnostic-only.
- **Sustained-hold switch lock.** A switch is locked only after current stays stopped across 3 samples, in
  BOTH the daemon auto-locker (`cycle_switches`) and the manual scanner (`acc-switch-scan.sh`). A switch that
  stops then re-arms (MediaTek `current_cmd` on Xiaomi/HyperOS klee) is rejected — overcharge stopped at the
  source, not after a breach.
- **Breach watchdog on `present`, not `online`.** An input-cut switch drives `*/online` to 0 while the cable
  is attached, blinding the old watchdog on those devices; it now uses `POWER_SUPPLY_PRESENT`.
- **Fail-safe config.** Out-of-range pause/resume/shutdown values fail safe; pause/resume forced into one
  unit domain (no mixed mV/% never-pause); µA/mA unit threshold unified to 16000.
- **Throttle nodes excluded** as switch candidates (`step_charging`, `restricted_charging`, `cool_mode/down`,
  `system_temp_level`, `temp_cool`, `hmt_ta_charge`) — they scan-OK but never hold.
- **`acca --state`** reads `battery/uevent` atomically and reports a real `statusTrust` (was always "unknown")
  plus a `native` block for Pixel/Tensor (where an empty `chargingSwitch` is normal, not a fault).
- `flip_sw` on=100 re-arm; dropped the dead read-only qpnp `blocking` node; added the OPLUS `oplus_chg`
  `mmi_charging_enable` path. Existing configs unchanged.

**v2025.5.18-stable.6.3.3 (202505217)** — SAFETY ROLLBACK of the 6.3.2 MTK idle change (overcharge fix)
6.3.2 auto-migrated MediaTek devices onto the `current_cmd` switch to get true idle. On some kernels
(e.g. Xiaomi klee / HyperOS) `current_cmd` PASSES the 3-second scan check but does NOT actually hold
the limit, so the battery charged past the cap = OVERCHARGE. Root lesson: never auto-move a device off
a switch that is currently holding the limit, and a 3s current-drop check is not proof a switch holds.
- **Reverted** the `current_cmd` promotion: it is no longer preferred over `input_suspend`, which on these
  phones DOES stop charging. (`ctrl-files.sh` restored to the stable.6.3 ordering — `input_suspend` high,
  `current_cmd` a low fallback.)
- **Removed** the 6.3.2 auto-migration that cleared a locked `input_suspend`.
- **Added** a one-shot, MTK-only revert that clears any switch 6.3.2 locked onto `current_cmd`
  (`chargingSwitch=(...current_cmd...--) -> ()`), so already-affected devices re-scan and re-lock
  `input_suspend`. Never left uncapped (empty switch re-scans on the next charge).
- **KEPT** the safe input-cut resume fix from 6.3.2: `input_suspend`/`bypass`/`vbus` switches now resume
  without a reboot (this only affects the RESUME path, never whether the switch holds, so it can't
  overcharge). Also kept all 6.3.1 hardening (out-of-range clamp, scheduler octal-safety, guards).
Net on affected MediaTek phones: the limit holds (no overcharge) AND charging resumes on re-plug without
a reboot. True idle is left off where `current_cmd` is unreliable — safety beats idle. Non-MediaTek and
non-input-cut devices are byte-for-byte unchanged; accd.sh untouched.

**v2025.5.18-stable.6.3.2 (202505216)** — MediaTek TRUE-IDLE fix (idle, not discharge; resume w/o reboot)
6.3.1 added the MTK `current_cmd` switch but it didn't take effect for existing users, for two
reasons now fixed: (1) on mt6375-class MTK, `current_cmd` toggles only the charge FET, so the bare
variant stops charging but the system runs off the BATTERY (discharge). True idle needs
`current_cmd 0 1` PLUS `en_power_path 1` (keep the buck/power-path ON → charger feeds the system,
battery flat, `*/online` stays up → charging resumes on its own). The `en_power_path` idle combo is
now ordered BEFORE the bare `current_cmd` (scanner locks the first switch that stops charging, so
the idle variant must come first; bare stays as the fallback where `en_power_path` is absent).
(2) An upgrade never re-scans, and the daemon honors a LOCKED switch (`--`), so MTK users stayed on
their old locked `input_suspend`. A one-shot, marker-guarded, MTK-only (`/proc/mtk_battery_cmd/
current_cmd` present) migration clears a stale locked `input_suspend` so the daemon re-scans and
picks the idle combo; if it doesn't verify, the scan re-locks a working switch (never left
uncapped). Non-MTK devices and any other locked switch are untouched. Root cause + node/register
mapping confirmed from the mt6375 kernel driver (F_CHG_EN vs F_BUCK_EN).
- **input_suspend no-charge-til-reboot FIX (all input_suspend-only devices, e.g. MTK Moto).** An
  `input_suspend` switch CUTS the charger input, so while paused `*/online` reads 0 -- meaning the
  resume re-arm (gated on `online`) could NEVER fire and charging stayed off until a reboot. For
  input_suspend-type switches the online signal is now treated as unreliable and the resume value
  is written regardless of `online` (harmless when truly unplugged -- no VBUS, no phantom -- and it
  un-masks online when actually plugged). The pause path still enforces the limit, so it can never
  overcharge. All other switch types keep the online gate (no cosmetic unplug blip).

**v2025.5.18-stable.6.3.1 (202505215)** — SAFE bug-fix batch (resume logic from 6.2/6.3 unchanged)
- **MediaTek battery-IDLE auto-selected.** The MTK `current_cmd 0 1` bypass (stops the cell while the
  charger keeps feeding the system = true idle, `*/online` stays up, resumes on its own) is now tried
  **before** `input_suspend` (which cuts the input → battery discharges + online drops → no-charge-til-
  reboot). Fixes the Xiaomi/MTK "discharges at the limit" + "won't resume til reboot" reports. MTK-only
  (`/proc/mtk_battery_cmd/*` absent elsewhere → no-op), still current-verified by `cycle_switches`, so a
  kernel where it doesn't actually cut falls through to `input_suspend` exactly as before. Non-MTK devices
  are byte-for-byte unaffected.
- **`en_power_path` polarity fixed** (`1 0`→`1 1`): the power path stays ON while paused (idle), not OFF
  (which forced discharge — "idle mode but battery still drains").
- **Out-of-range capacity clamp** in write-config: a corrupted numeric pause/resume (e.g. `99999999`,
  `150`) is all-digits so it passed the non-numeric fail-safe but was read as mV → never-pause/always-
  resume = overcharge. Now clamped to a safe default (valid = 0–100 % or 3001–5000 mV).
- **Scheduler `at()` is leading-zero/octal-safe** (`10#`): an `08:`/`09:` time no longer aborts under set -e.
- **`cap_idle_threshold` + `parse_switches`** corrupted-config / uppercase-`DISABLED` guards.
- Verified: 13/13 native+generic spec, 17/17 logic, 82-case sensitivity all unchanged; adversarial diff review GO.

**v2025.5.18-stable.6.3 (202505214)** — HOTFIX: resume-after-limit on ALL phones (generic_rearm)
Extends 6.2's Pixel/Tensor fix to non-Pixel devices (Motorola/Qualcomm/etc.). Some charging switches
(input_suspend, */current_max 0, */charging_enabled 0) hold their "off" state across an unplug/replug,
so after the limit was hit, re-plugging did nothing until capacity fell to resume_capacity — or, on
switches that latch, until a reboot. New `generic_rearm`: on a genuine plug-in (offline→online) below
the limit, re-arm the switch at once via `enable_charging`. A shared loop-top plug tracker (`freshPlug`/
`wasOnline`) now drives both `native_unlatch` (Pixel) and `generic_rearm` (everything else). One-shot
per plug (no sawtooth); skipped on the boot loop (`.minCapMax` present, so it never fights
off_mid_charge); online-gated; cannot overcharge (the pause/limit logic is unchanged). Verified by a
13-case mock-sysfs harness (plug tracker, native refactor, generic re-arm, boot-skip, sawtooth guard).

**v2025.5.18-stable.6.2 (202505213)** — HOTFIX: Pixel/Tensor resume-after-limit without reboot
The rc20 native firmware path (charge_stop_level + charge_start_level) trusted the Tensor driver to
resume at the start level, but that driver latches "stopped" and ignores it (an upstream Google bug,
reproduced on Pixel 6..10 and even with no ACC installed). Result: once the limit was hit, re-plugging
the charger did nothing and only a reboot restored charging. New `native_unlatch` detects the latched
state (plugged in, at/below your resume level, or a fresh plug-in below the limit, while the kernel
still reports not-charging) and briefly pulses charge_stop_level=100 — the only value that re-arms the
FET — then immediately restores your real stop level, so there is no overshoot. It self-disables on
phones whose firmware already resumes correctly, never fires inside the [resume..limit] idle band
(no sawtooth), and can only ever charge toward the limit `sync_native_limit` still enforces (cannot
overcharge). Non-Pixel devices are unaffected (native mode only runs on google,charger hardware).
Verified by an 8-case mock-sysfs regression harness (latched-resume, no-sawtooth, self-disable,
plug-transition, clamp, thermal).

**v2025.5.18-stable.6.1 (202505212)** — all-phones auto-detection hardening
Makes automatic switch selection/locking correct across SoCs, kernels and current conventions,
without manual config. All changes preserve the Pixel/Tensor and normal-Qualcomm paths exactly.
- **Curated switch priority is no longer alphabetized.** The switch list was de-duped with
  `sort -u`, which reordered ACC's hand-tuned priority and let auto-select/auto-lock grab a worse
  switch first (e.g. a current-cut before a clean on/off) on non-Pixel devices. De-dup is now
  order-preserving, so the curated order survives.
- **Switch scan + daemon auto-lock work on inverted-sign kernels** (e.g. some Motorola report
  `current_now` positive while discharging / negative while charging). "Stopped" is now anchored
  to a *reversal vs the charging baseline's own sign* (scan) and the daemon's anti-flicker check
  is sign-agnostic and **unit-scaled** (µA vs mA), so milliamp-reporting devices (older Exynos)
  and inverted-sign devices no longer false-lock a non-working switch. Pixel discharge-hold
  (current reverses) is correctly accepted.
- **Scan hold-quality classification fixed** — dropped the static `usb/current_max` ceiling from
  the charger-input probe (it read constant and mislabeled paused switches as "bypass"); added
  `dc`/`wireless` live input nodes for DC/wireless charging.
- **Broader charger-online detection** — recognizes `main-charger`, OnePlus/Oppo `oplus_*chg`,
  and Qualcomm `pmic_glink` charger supplies (additive; never matches fewer nodes).
- **Spurious-shutdown guard** — a garbage/empty `shutdown_temp` in a hand-edited config can no
  longer trigger a shutdown (it now coerces to the 55 °C default).
- Charge-limiting itself was never affected by any of the above (it is capacity/online based).

**v2025.5.18-stable.6 (202505211)** — STABLE
Promotes stable.6-rc22 to final (identical, tested code). Stable.6 line highlights:
- **Native Pixel/Tensor charge limit** (`charge_stop_level`/`charge_start_level`) — holds the
  battery flat at your cap with no overshoot and true battery-idle (no 100%/5% sawtooth).
- **All-paths group switch** zeroes every Pixel charge path at once; auto-lock locks the group
  so no single path can keep charging.
- **Brick-safe switch probing** (#305/#308): a write-ahead journal blacklists any node that
  panics/reboots the device, so it is never retried.
- **Atomic config writes** (no partial-read/truncate on a failed write) and **safety bounds**
  from a final audit (no div-by-zero, no inverted limits; every param coerces garbage to a safe
  default before the daemon's arithmetic).
- **Deep sleep** when unplugged/idle (#293); **no 2-second phantom "Charging"** on unplug.
- **Install robustness** — busybox / start-stop-daemon fallbacks across more roots and ROMs.
- `acca --state` export (real version + derived charging status + fresh snapshot).
- Temperature band cooldown 45 < max 50 (resume 40, shutdown 55); a collapsed 45/45 auto-repairs.
- ACC is fully standalone (uninstalling the AccA app never removes it); configs auto-migrate.

**v2025.5.18-stable.6-rc13 (202505204)** — PRE-RELEASE
- **Tensor hard-pause now actually applies** (fresh `.stable-defaults7` marker re-runs the
  migration that the stale `.6` marker skipped: `allowIdleAbovePcap=false` +
  `prioritizeBattIdleMode=no` on google,charger devices).
- **All-paths group switch**: a single line that zeroes EVERY Pixel charge path at once
  (battery/constant_charge_current + main-charger + usb + gccd + dc current → 0), tried high,
  so the auto-lock locks the group instead of one path another path defeats.
- **write-config hardening**: every config param now coerces empty/non-numeric/garbage to its
  safe default before the daemon's raw arithmetic sees it (temperature[] and capacity_mask were
  unguarded and could crash the loop); ordering invariants re-verified.

**v2025.5.18-stable.6-rc12 (202505203)** — PRE-RELEASE
- **Brick-safe switch probing (#305/#308).** A write-ahead journal records a candidate switch
  before the risky pause-write; if it kernel-panics/reboots the device, accd blacklists that
  exact node on next boot and never touches it again. Blacklisted nodes are skipped.
- **No more 2-second phantom "Charging" on unplug** — the daemon no longer flips the switch
  back ON while the charger is offline.
- **Deep sleep (#293)** — when unplugged and idle, the daemon waits up to ~120 s (interruptible:
  plugging in or editing a setting wakes it within ~1 s) instead of polling every few seconds.
- **Install robustness (#216/#223/#247/#228/#222/#215)** — busybox discovery now tries Magisk/
  KSU/APatch/system/toybox fallbacks (and manual applet symlinks); a missing start-stop-daemon
  falls back to setsid/nohup; clearer failure messages with the log path.

**v2025.5.18-stable.6-rc11 (202505202)** — PRE-RELEASE
- **"Cut current to 0 = stop" switches for ALL SoCs.** The method proven on the A16 Pixel
  (`usb/current_max …0`) is now generic in the switch DB via wildcards
  (`*/current_max 3000000 0`, `*/constant_charge_current(_max) 5000000 0`,
  `*/input_current(_limit) 3000000 0`), so Qualcomm/MediaTek/etc. that don't respond to the
  on/off or charge-limit nodes can still be stopped. The current-verified auto-lock keeps
  whichever actually cuts.

**v2025.5.18-stable.6-rc10 (202505201)** — PRE-RELEASE
- **Pixel/Tensor limit now holds automatically.** Confirmed on an Android-16 Pixel 9a: the
  charge_stop_level node does NOT cut on A16, but `usb/current_max ... 0` (cut input current)
  does. ACC's idle-above-pcap path "succeeded" in status while charging continued, so it never
  hard-paused. On devices exposing google,charger, the installer now defaults to
  allow_idle_above_pcap=false + prioritize_batt_idle_mode=no (hard-pause), so rc9's current-
  verified auto-lock locks the working current-limit switch on its own. Runs once; only Tensor.

**v2025.5.18-stable.6-rc9 (202505200)** — PRE-RELEASE
- **Reworked switch auto-lock so it actually locks on discharge-only devices.** Two issues:
  (1) `prioritize_batt_idle_mode=true` made the strict pass demand *Idle* (true bypass, ~0
  current), but Pixel/Tensor only *discharges* (`charge_stop_level 100 5` -> negative
  current), so the working switch failed the filter and was skipped; (2) a once-per-session
  sentinel meant strict only ran once. Now: a single strict pass judges a switch purely by
  CURRENT (idle OR discharge = stopped), LOCKS the first that truly cuts, and retries every
  pause until locked (then stops, since a locked switch ends the loop). This finally locks
  `charge_stop_level` on Android-16 Pixel and any discharge-only SoC.

**v2025.5.18-stable.6-rc8 (202505199)** — PRE-RELEASE
- **THE fix.** The switch-verification (rc5) checked the *absolute* current, so a working stop
  switch that makes the battery DISCHARGE (e.g. `charge_stop_level 100 5`, negative current)
  was wrongly rejected as "still flowing" -> nothing ever locked -> the daemon re-probed every
  35 loops and charging restarted (stop-then-reset). Now it rejects a candidate only if current
  is still strongly POSITIVE (charging); a negative/idle current = stopped = accepted + locked.
  This is why rc5-rc7 found the switch, stopped, but couldn't keep it.

**v2025.5.18-stable.6-rc7 (202505198)** — PRE-RELEASE
- **Auto-LOCK the switch once it's current-verified** — fixes "stops at the limit, then
  resumes/resets" sawtooth. In auto mode the daemon re-probes switches every _STI (35)
  loops; that re-probe toggled charging back on, so even after it found the working switch
  and stopped, it restarted ~1% later. Now, when the strict test confirms a switch actually
  dropped the current, the daemon locks it (`--`) and stops re-probing, so it HOLDS. A
  locked switch that later fails is still auto-recovered.

**v2025.5.18-stable.6-rc6 (202505197)** — PRE-RELEASE
- **Pixel/Tensor: try `charge_stop_level` FIRST**, before the `*/charging_state` wildcard
  trap that auto-mode was hitting first (it reports "stopped" while current keeps flowing,
  so the daemon churned and locked nothing -> charging passed the limit). Both drivings are
  offered -- `100 pcap` (stable) and `100 5` (the 2022/2023 driving users confirm worked) --
  and rc5's current-verification keeps whichever actually drops the current. So the daemon
  locks the switch that truly cuts instead of the trap.

**v2025.5.18-stable.6-rc5 (202505196)** — PRE-RELEASE
- **Switch auto-lock now verifies current, not just status** (fixes limit overshoot on
  Tensor/Pixel and any device with a "trap" switch). The strict switch-test rejected a
  switch only if status still read "charging"; the Google `charging_state` node reports
  "not charging" while current keeps flowing, so the daemon churned and locked nothing,
  letting charging sail past the limit. Now a candidate is rejected unless the current
  actually drops (>50 mA still flowing = not stopped), so the daemon locks a switch that
  truly cuts (e.g. `charge_stop_level`). Lenient on mA-reporting kernels (no regression).

**v2025.5.18-stable.6-rc4 (202505195)** — PRE-RELEASE
- `acca --state` now reports **smart sensing, measured live for ANY SoC** (not Tensor-only):
  `plugged` (any */online=1), `currentUnits` (uA/mA auto-detected from magnitude),
  `polarity` (status vs current sign), and `switch.measuredClass` (bypass / idle /
  charging / discharging from plug + unit-aware current band). The app can now read the
  plugged/unplugged reality and classify what the charger is doing on every device.
- Still additive; no charging-behavior change.

**v2025.5.18-stable.6-rc2 (202505194)** — PRE-RELEASE
- Fixes three bugs in the rc1 `acca --state` export (found on a Pixel 9a):
  - **acc version/versionCode were empty** on the daemon/front-end path (`accVer` is only
    set in acc.sh) — now read from module.prop directly, correct in every context.
  - **status read "unknown"** when the front-end requested the snapshot (that path never
    calls `read_status`) — now falls back to a current-sign derivation (Charging /
    Discharging / Idle).
  - **the snapshot could freeze** (`print_state` cat an existing file) — `acca --state`
    now always refreshes before printing, so it's never stale.
- Still additive; no charging-behavior change.

**v2025.5.18-stable.6-rc1 (202505193)** — PRE-RELEASE
- New: `acca --state` (alias `acc -j`) publishes a machine-readable JSON snapshot of
  ACC's actual state to tmpfs every daemon loop and on demand. It is the keystone for
  the upcoming AccA control-bus + diagnostics rebuild: the read-back the front-end
  confirms changes against, the diagnostics feed, and the exportable report source.
- Additive only — no change to charging behavior. The export is written atomically
  (temp+rename, no torn reads), best-effort/non-blocking (never stalls the safety
  loop), tmpfs-only (no flash wear), carries a non-PII fingerprint, and a value that
  cannot be read is JSON null, never 0.
- Includes every STABLE.5 fix below.

**v2025.5.18-stable.5 (202505192)**
- Reverts the stable.4 "gentler max_temp 45 C" change, which was wrong. Lowering max_temp to 45
  left it equal to cooldown_temp, so the config read `temperature=(45 45 40 55)`. cooldown_temp is
  the temperature at which the gentle cooldown cycle STARTS; max_temp is the hard pause. When the
  two are equal the cooldown loop enters and immediately breaks at max_temp -- it never actually
  throttles, so the cooldown stage is dead. The two thresholds have to keep a gap.
- Default temperature band restored to the proven upstream `cooldown 45 < max 50` (resume 40,
  shutdown 55). 50 C has been ACC's default for years; the 5 C gap beneath it is the working range
  of the cooldown cycle. Heat does age cells, but the levers for that are a lower charge limit and
  the cooldown cycle -- not collapsing the two temperature thresholds onto one value.
- Hardening so it cannot recur: write-config now defaults max_temp to 50 and enforces
  cooldown_temp < max_temp (and >= resume_temp) on every rewrite, rather than rebuilding the array
  with both at 45.
- Migration: a config left on the degenerate `(45 45 ...)` by stable.4 is repaired once to
  `(45 50 ...)`. Only that exact collapsed signature is touched; a band you set yourself is left
  alone. No command needed.

**v2025.5.18-stable.4 (202505191)**
- ACC is now fully standalone. Removed the cleanup script that deleted ACC when the
  AccA app was uninstalled -- ACC is a normal Magisk/KSU module, so removing the
  front-end never touches the daemon or your config. Existing installs drop that
  script on update too. (Your config always persists in config.txt regardless.)
- Gentler default temperature limit: max_temp 50 -> 45 C (heat above ~45 ages the cell
  noticeably faster -- BU-410). Fresh installs ship 45; a config still on the old
  default of 50 is updated once; a value you set yourself is left alone.
- Hygiene: AccA's boot receiver is now registered (justifies its boot permission and
  is belt-and-suspenders next to the module's own boot hook), and AccA's stale profile
  temperature default (a legacy "90") is corrected to a sensible resume temp.

**v2025.5.18-stable.3 (202505190)**
- Fixes charging getting STUCK below the range (e.g. frozen at 64 % with a 70-75 range:
  neither charging nor discharging). The Google charge-stop node latches "stopped" once
  it reaches the limit. stable.2 used the limit value (pcap) as BOTH the stop and the
  resume value, and re-writing the limit never re-arms the charger -- so once stopped it
  stayed stopped, even after the battery drained below the range. The resume value is
  now `100` ("charge up"), which re-arms it (what 2022/2023 did); the stop value stays
  at your limit. Net: charge up to your limit, stop, drift down, resume at your resume
  level -- a tight cycle within your range. The installer upgrades a locked pcap-pcap /
  pcap-5 switch to `100 pcap` automatically, no command.

**v2025.5.18-stable.2 (202505189)**
- Hold-at-limit only. Removed the `charge_stop_level pcap 5` discharge variant and
  reverted `allow_idle_above_pcap` to its original default. The stable.1 default
  (`allow_idle_above_pcap=false`) pushed auto-mode into the discharge variant, which
  drained the battery down to resume_capacity (~70) instead of holding at the limit.
  Now charging stops at your limit and holds there -- the only behavior. The installer
  migrates existing configs (undo the false default, drop a locked pcap-5 switch), so
  this needs no manual command.

**v2025.5.18-stable.1 (202505188)**
- Existing configs now auto-adopt the corrected defaults on update (one-time, in the
  installer): the new `allow_idle_above_pcap=false` ("never sit above the limit")
  applies WITHOUT any manual `acc -s` command. Runs once (marker-guarded) and never
  clobbers a deliberate later choice. Fresh installs already get the new defaults.

**v2025.5.18-stable (202505187)**
- First STABLE community build -- consolidates and hardens fix2..fix12:
  * Charge limit holds EXACTLY at your level on Pixel/Tensor -- no overshoot. The
    limit node is driven by the target level on BOTH sides (pcap), never "charge to
    100% then interrupt" (which caused the old 75->77 breach).
  * Default: discharge down to your limit, then HOLD there (battery-idle). Turn
    battery-idle off for a discharge-cycle between resume_capacity and the limit.
  * allow_idle_above_pcap now defaults to FALSE -- never sit ABOVE the limit; if the
    battery is over it, discharge down to it.
  * Hardened: "pcap" falls back to a safe low cap if pause_capacity is empty OR
    non-numeric; every capacity/temp comparison is fail-safe (pause / do-not-resume).
  * Settings apply within ~1s (live re-read, no daemon restart, no UI freeze).
  * The daemon survives a front-end restart -- a switch scan can no longer leave it
    stopped / charging uncapped; it verifies the daemon came back.
  * Breach watchdog warns if the cap ever isn't holding.
  * Switch scanner can LOCK a chosen method: hold (default) or discharge-cycle.

**v2025.5.18-dev-fix12 (202505186)**
- The switch scanner can now LOCK a chosen method (default unchanged: pcap hold):
    * `acc-switch-scan.sh --apply`          -> lock "hold at the limit" (pcap pcap), DEFAULT
    * `acc-switch-scan.sh --apply --cycle`  -> lock the "discharge-cycle" (pcap 5):
      discharge to resume_capacity, then recharge to the cap, repeat.
  It picks the method by the switch LINE rather than the device-dependent measured
  idle/discharging reading, so the choice is reliable even where the kernel slow-
  drains at the limit. AccA exposes both as one-tap Scripts.

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
