# rc22 stabilization — plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Get from "rc21 was about to be called stable" to "rc22 is stable on any phone, any kernel" — with the evidence to say so.

**Architecture:** ACC's correctness rests on a chain of facts it has to learn about each phone: which nodes are the fuel gauge, what unit the current is in, which sign means charging, whether the status node lies, which switch holds, what class that switch is. Every limit sits downstream of that chain. When a link is wrong the failure is always the same and always silent — `is_charging` goes false and all four limits stop being evaluated, with nothing logged and nothing shown. Two phones cannot cover the device space, but the chain can be **fault-injected**, so the coverage comes from simulating each per-device fact rather than owning each device.

**Tech Stack:** POSIX shell (mksh on device), ACC module scripts under `install/`, pure-unit suites under `suites/`, two devices over ADB WiFi.

## Global constraints

- Target shell is **mksh**. `sh -n` on device is the gate, `dash -n` locally is the proxy. `bash -n` alone proves nothing.
- Daemon runs under `set -eu`. A new unguarded call site kills it, which fires the exit trap and drops the limit.
- `shutdown_temp` is never lowered by any test. Held at `max(saved, 55)`.
- Every test restores the config on EXIT/INT/TERM/HUP and holds a lock so two runs cannot overlap.
- Every behavioural fix ships with a unit test that is **mutation-verified**: it must fail against `git show HEAD:install/<file>`.
- No AI attribution anywhere. No code comments explaining mechanics — only reasoning.

---

## Part 1 — What actually changed since rc21

rc21 is `1406274`. Everything below is **uncommitted working tree**, and the builds on both phones were made from it. `versionCode` went 202505301 → 202505302, but `202505302` has been used for several distinct builds this week, so it does not identify one. That is a problem in its own right (Task 0).

| # | Change | File | Class | Coverage today | Gap |
|---|---|---|---|---|---|
| 1 | `_temp_hold()` + guards on exit trap, `generic_rearm`, init release | `accd.sh` | behaviour | t33 22/0, A3 before/after on hardware | never tested on the native class |
| 2 | init current-restore bounded to `<=100mA` | `accd.sh` | behaviour | t32, curtana field-confirmed not firing | — |
| 3 | `_kstatus` stash + sign-vs-kernel tie-break | `batt-interface.sh` | **behaviour, safety-critical** | none until t34 | **never tested on a phone whose sign is genuinely wrong** |
| 4 | `_ccd` set only when the counter ruled | `batt-interface.sh` | **behaviour, safety-critical** | t34 13/0, A3 partial | not proven end-to-end |
| 5 | `sdp()` replaces instead of appending; flips counted | `misc-functions.sh` | behaviour | 7/0 unit, A3-verified | arming `.dpol_unstable` **freezes** a polarity — only safe because of #3/#4 |
| 6 | tmpfs bootstrap `mkdir -p $TMPDIR` | `accd.sh` | recovery | A3-proven | boot auto-start cause still open |
| 7 | AMPS 7.2.3 ON-value rejection, pcap `CFG_LEVEL` | `amps.sh`, `acc-compat.sh` | detection | bramble + pixel field | — |
| 8 | `native_unlatch` temperature guard | `accd.sh` | **reverted** | Pixel A/B proved it latched `charge_stop_level` | pinned by t33 so it cannot return |

**The single biggest risk is #3 + #5 together.** #5 makes `.dpol_unstable` reachable, which *freezes* the cached polarity. If that frozen polarity is wrong, the only thing standing between the user and "all four limits silently off" is the tie-break in #3 — which is uncommitted, was never in any released build, and has never been exercised on a phone whose sign is actually wrong. Fault injection (Part 3) exists mainly to close that.

## Part 2 — What "any phone, any kernel" actually means

These are the axes that differ. Each is a link in the chain; each has a discovery step, a failure mode, and a blast radius.

| Axis | Values seen | Discovered by | Failure mode | Blast radius |
|---|---|---|---|---|
| Gauge node | `battery`, `bms`, `maxfg`, `ds????-fuelgauge`, `smb???-battery` | `batt-interface.sh` `_INIT` scan, cached | reads empty, everything reads 0 | total |
| Current unit | mA, µA, **mixed** (OnePlus 8 Pro: mA current, µV volts) | `ampFactor_`, ≥16000 heuristic, re-latched | a 1.5 A charge reads as 0 mA | limits misjudge |
| Current polarity | `+`, `-`, **mode-dependent** (curtana: 5 V path +, 9 V path −) | `sdp()` sampling, coulomb arbitration | Discharging with the cable in | **total, silent** |
| `charge_counter` | fine, **coarse** (A3: 0 µAh in 120 s), absent | `cc_now` | arbitration cannot rule | polarity unguarded |
| Status node | honest, lying | `battStatusWorkaround` | wrong verdict either way | total |
| Switch class | bypass, cut-input, cut-charge, drain, current-cap, native level | AMPS / `cycle_switches` | limit does not hold, or phone stranded | enforcement |
| Native limit | `google,charger` pair present/absent | `nativeLimit` | generic toggle fights firmware | enforcement |
| Charger | 5 V DCP, QC, PD, VOOC/proprietary | `real_type`, `pd_active`, `_fcNodes` | re-kick collapses it | speed |
| Kernel driver | `qpnp-smb5`, `google,charger`, mtk, oplus | node naming | nodes not found | total |

**The pattern across all of them:** ACC already measures most of this, and `state-export.sh:568-599` already publishes `currentUnits`, `polarity`, `polaritySource`, `statusTrust`, `confidence`, `ccDir` for AccA to read. The daemon does not consult any of it. It enforces identically at `confidence=low` and `confidence=high`, and says nothing when a link is unknown.

**That is the generalization.** Not "support more phones" — make the chain self-verifying, make the daemon act on its own confidence, and make an unknown link loud instead of silent. A phone we have never seen then either works, or tells its owner exactly which link ACC could not establish.

## Part 3 — Test strategy: inject the variation

Two phones give two points in a nine-axis space. Fault injection gives the rest.

Every per-device fact lives in a file ACC reads: `$TMPDIR/.batt-interface.sh` (nodes, unit, polarity), `$TMPDIR/.dpol_unstable`, `config.txt` (`battStatusWorkaround`, `chargingSwitch`). All are writable. So each axis can be forced to its wrong value on a phone we own, and the question becomes: **does ACC notice, recover, and say so?**

| Injection | Simulates | Pass condition |
|---|---|---|
| `_DPOL` flipped to the wrong sign | curtana / sweet, a mis-latched phone | tie-break recovers within one loop; limits still enforce |
| `_DPOL` wrong **and** `.dpol_unstable` armed | the frozen-wrong-polarity case #5 creates | tie-break still recovers; `is_charging` stays correct |
| `charge_counter` unreadable (point at a missing node) | a phone with no coulomb counter | falls back cleanly, no crash, limits hold |
| `ampFactor_` set to 1000 on a µA phone | mis-detected unit | `amp_recheck` re-latches, or limits still hold |
| `battStatus` pointed at a node that always says `Charging` | a lying kernel | `battStatusWorkaround` catches it |
| `battStatus` pointed at one that always says `Discharging` | the sweet report | limits still enforce via the tie-break |
| `.batt-interface.sh` deleted mid-run | tmpfs wipe / cache loss | daemon re-discovers, does not die |
| `.batt-interface.sh` truncated to half a line | crash mid-write | daemon survives, falls back |
| `chargingSwitch` pointed at a non-existent node | stale config after a ROM change | daemon warns, does not strand |

This is the only realistic route to "any phone". Each injection is a unit of Task 3.

**Charger split.** The two charger regimes test different things, and today's runs proved it:

- **Fast charger (QC/PD wall):** limit *enforcement* is measurable. Full 15-combination matrix, current and voltage caps meaningful, re-kick/PD interaction reproducible.
- **Slow charger (PC USB):** *sensing* is stressed. The A3 at 74% tapers under ACC's 10 mA idle threshold, the current sign oscillates around zero, and the coarse counter cannot rule. That is exactly the regime where ACC goes blind — and it is a regime real users hit every night on a weak charger. Test sensing here, not enforcement.

Running the full matrix on a slow charger produces false failures. Today's A3 run is the proof: 9 "failures" that were all environment.

## Part 4 — Execution plan

### Task 0: Make a build identifiable

**Files:** `module.prop`, `changelog.md`

`202505302` currently names at least four different builds. No test result means anything without this.

- [ ] Bump `versionCode` to `202505303` and set `version=v2025.5.18-6.5.1-rc22`.
- [ ] Add a build stamp the daemon logs at start: `git rev-parse --short HEAD` plus `-dirty` when the tree is not clean.
- [ ] Verify `acc -v` and the diag bundle both show it.
- [ ] Commit: `chore: make each build identifiable in logs and diagnostics`

### Task 1: Commit the rc22 pile with tests attached

Nothing below can be trusted while the tree is dirty and the baseline is a moving target. Each change from Part 1 gets its own commit with its test.

- [ ] Commit #2 (init restore bound) + `t32`.
- [ ] Commit #3 + #4 (tie-break, `_ccd`) + `t34`. One commit — they are one mechanism.
- [ ] Commit #5 (`sdp`) + its unit test, promoted from the scratchpad into `suites/misc/`.
- [ ] Commit #1 + #8 (`_temp_hold` guards, and the `native_unlatch` revert note) + `t33`.
- [ ] Commit #6 (tmpfs bootstrap), #7 (AMPS 7.2.3).
- [ ] Run the whole suite on both phones. Gate: all green before proceeding.
- [ ] Tag `rc22-pre` so every later result names a commit.

### Task 2: ADB WiFi and a repeatable rig

- [ ] Both phones on WiFi: `adb tcpip 5555` then `adb connect <ip>:5555` while still on USB, then unplug USB and move to the wall charger.
- [ ] Record both IPs in `.scratch/rc22-stabilization/devices.md` with device, SoC, switch class, gauge node, polarity, counter behaviour.
- [ ] Verify each phone survives a `su -c` round trip over WiFi and that `acc -D restart` is issued in its **own** call — chained in the same `su -c` it SIGTERMs the caller (exit 143).
- [ ] Confirm battery is 40-60% on both, on the fast charger, before any run.

### Task 3: Fault-injection suite — the "any phone" coverage

**Files:** create `PROJECTS/SHIPPING/acc-faultinject.sh`

One script, one injection per case, each with: inject → restart daemon → observe → restore → assert. Every case must restore even on failure.

- [ ] Build the harness: save `.batt-interface.sh`, `config.txt`, and the markers; restore on every exit path; refuse to run if another instance holds the lock.
- [ ] Case 1: flip `_DPOL`, restart, assert `acc -i` status matches the kernel and a temperature pause still fires.
- [ ] Case 2: flip `_DPOL` **and** `touch .dpol_unstable`, same assertions. This is the #5 risk.
- [ ] Case 3: point `temp`/`battCapacity` at a missing node, assert the daemon survives and re-discovers.
- [ ] Case 4: truncate `.batt-interface.sh` mid-line, assert no daemon death.
- [ ] Case 5: `ampFactor_=1000` on a µA phone, assert limits still hold.
- [ ] Case 6: `battStatusOverride` forced to `Discharging`, assert limits still enforce.
- [ ] Case 7: `chargingSwitch` pointed at a missing node, assert a warning and no strand.
- [ ] Run on both phones, both chargers. Record every result.

### Task 4: Enforcement matrix on the fast charger

**Files:** `PROJECTS/SHIPPING/acc-limit-matrix.sh` (exists, already lock-protected and headroom-aware)

- [ ] Run the full 15-combination matrix on the A3 on the wall charger. Expect the current and voltage rows to actually run this time.
- [ ] Same on the Pixel 6a.
- [ ] Compare against `LIMITS.md`'s expectation table; update the measured section.
- [ ] Any row that fails gets its own reproduction before any fix.

### Task 5: Sensing matrix on the slow charger

- [ ] Both phones back on a PC USB port, battery high enough to taper.
- [ ] Assert: ACC's status matches ground truth, or ACC reports low confidence. Silence with a wrong answer is the failure.
- [ ] Assert: no polarity churn — `.dpol_flips` stays bounded and `.batt-interface.sh` keeps exactly one `_DPOL` line.
- [ ] Assert: the daemon never dies and never overcharges.
- [ ] Expect limit *enforcement* to be untestable here; that is the point, and the tooling must say so rather than fail.

### Task 6: Act on the confidence that already exists

The product change that makes unknown phones safe. Only after Tasks 3-5 show where confidence actually lands.

**Files:** `install/state-export.sh` (reuse `_se_*` helpers), `install/accd.sh`, `install/strings.sh`

- [ ] Extract the sensing computation so the daemon can call it, not only the exporter.
- [ ] When `confidence=low` **and** the phone is plugged: warn once per day naming the link that could not be established, through `warn_once_per`.
- [ ] When polarity cannot be established at all, prefer the kernel status over a guessed sign, and record that choice in the ledger.
- [ ] Add `acc --selftest`: walks the chain, prints each link with its value, source and confidence, and exits non-zero when a link is unknown. Follow the pure synthetic pattern already in `post-fs-data.sh --selftest`.
- [ ] Unit-test the confidence ladder, mutation-verified.

### Task 7: The re-kick / PD work

Already planned in full at `.scratch/pd-rekick-fix/plan.md`. Fold it in here: its Task 2 needs the fast charger this plan is already setting up, so run it inside Task 4's window.

### Task 8: Stability gate

rc22 is not called stable until all of these hold, on both phones, on both chargers, against one named commit:

- [ ] Every unit suite green on device.
- [ ] Fault-injection suite green: every injected fault is either recovered or reported, never silent.
- [ ] Enforcement matrix on the fast charger: all 15 rows correct, or each failure explained and accepted in writing.
- [ ] Sensing matrix on the slow charger: no wrong-and-silent verdicts.
- [ ] 12-hour unattended soak on each phone: overnight on the charger, daemon alive at the end, no overcharge past `pause_capacity + 2`, ledger reviewed.
- [ ] A reboot on each phone with the limit active: comes back charging, limit still held.
- [ ] Uninstall on one phone: charging fully restored, no node left capped.
- [ ] `CHANGELOG.md` covers every change in Part 1.

## Part 5 — Sequencing

Tasks 0-2 first, in order — they are cheap and everything else depends on a named build and a working rig. Task 3 is the highest-value block because it is the only thing that speaks to phones we do not own. Tasks 4 and 5 need the chargers and can run in parallel across the two phones. Task 6 is deliberately last among the code changes: it should be informed by what Tasks 3-5 reveal about where confidence actually lands, not guessed at first.

## Part 6 — Risks

- **The tie-break has never met a genuinely wrong sign on hardware.** It is the load-bearing recovery for the polarity freeze that change #5 introduces. Task 3 Case 2 is the single most important test in this plan.
- **`.dpol_unstable` freezes a polarity permanently for the boot.** Correct when the tie-break works, dangerous when it does not. Consider making the marker expire, or re-checking it whenever the kernel and the sign disagree for several consecutive loops. Decide after Task 3.
- **Fast-charge handshakes do not survive toggling.** Every enforcement test on a fast charger perturbs the negotiation, so a matrix run is not a clean measurement of charge speed. Measure speed separately, right after a replug.
- **Two phones is still two phones.** Fault injection covers the fact chain, not the kernel's own behaviour. A Mediatek or Exynos phone can still fail in a way neither device shows. Task 6 is what makes that failure loud instead of silent, which is the realistic goal.
- **I introduced a regression today and caught it only by A/B.** Any behaviour change that cannot be A/B'd against the previous build on hardware does not ship.
