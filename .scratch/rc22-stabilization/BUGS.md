# ACC bug register — rc21 → rc22

Everything found, fixed, or still open. Baseline is rc21 `1406274`, current build `202505304`.

## A. Fixed (16)

Bugs 1-14 are hardware-verified on the A3, the Pixel, or both. **15 and 16 are not yet on either
phone** - they are source- and sandbox-verified only, and are flagged as such in the table. They go
on both phones with the next flash.

| # | Bug | Where | Proof |
|---|---|---|---|
| 1 | `_ccd` was set to the raw counter delta including 0, so a coarse gauge stood the kernel tie-break down and an unchallenged wrong current sign decided everything — every limit blind at once | `batt-interface.sh` | t34 13/0; A3 `acc -i` Discharging→Charging |
| 2 | "Charging" reported with no cable attached | `batt-interface.sh` | t37 9/0; 80 samples across 8 cached states, 0 wrong |
| 3 | `sdp()` appended `_DPOL` forever (18 contradictory lines seen), anti-churn marker unreachable | `misc-functions.sh` | unit 7/0; A3 cache 18→1, flips counted, marker arms |
| 4 | Daemon hung while `acc.lock` + `/proc` said "alive"; `allow_idle_above_pcap=false` handed a native phone to the generic prober | `accd.sh` | t38 9/0; `flight.log` frozen, recovery in 20 s |
| 5 | Native limit latched — phone stranded not charging with a limit far above the level | `accd.sh` | `stop` 45→71 in 20 s vs 160 s stuck |
| 6 | Native thermal pause absent below the resume level (clamped `stop` to `start`, but firmware holds only at `level >= stop`) | `accd.sh` | t39 16/0; 38 °C vs 37 °C was drawing 1.2 A, now ~0 mA |
| 7 | `native_unlatch` pulsed `charge_stop_level=100` then slept a full loop — unrestricted charging on a hot pack, every loop | `accd.sh` | t33; 0 samples at 100 after fix |
| 8 | Init current-restore overwrote live negotiated input nodes (curtana) | `accd.sh` | t32 18/0; no `init restore` lines in curtana's bundle |
| 9 | 500 mA probe-time snapshot written back over a 2 A charger, from two paths | `misc-functions.sh`, `accd.sh` | t36; A3 ICL 0 → 2 A |
| 10 | Clear/re-apply race: CLI cleared the cap, daemon re-applied it 1 s later, marker already gone so every later restore no-oped | `set-ch-curr.sh` | ledger shows release with no re-cap; A3 + Pixel |
| 11 | Cooldown cycle and main resume re-enabled charging on a pre-sleep temperature reading | `accd.sh` | t33 27/0 |
| 12 | Interface cache rebuilt only when *absent*, not when unusable — an empty file left the daemon blind permanently | `accd.sh` | t40 8/0; truncate → restart → rebuilt |
| 13 | Two USB re-kick sites bypassed `acc -sk off`, the rate limit, and the ledger | `set-ch-curr.sh` | t35 16/0; `rekick skipped` now visible in production |
| 14 | An unusable cache healed only at daemon init. A looping daemon never noticed, and `acc -i` sourced an empty file, left every node path unset, and **blocked on stdin** instead of answering — AccA hangs | `batt-interface.sh` | t41 11/0; A/B on both phones, daemon pid unchanged: A blind/blocked, B healed |
| 15 | `temp_now` coerced an unreadable sensor to 250 (25 °C), so the thermal limit silently stopped being enforced with nothing anywhere saying so | `accd.sh` | t42 9/0; sandbox: 2 log lines across 4 failing reads + recovery. **NOT yet on a phone** |
| 16 | `.testingsw` was an empty marker, so a scan killed by SIGKILL was indistinguishable from one in progress | `misc-functions.sh`, `acc.sh` | source only. **NOT yet on a phone** |

**Silent ones** (no user could have reported): 4, 5, 6, 12, 14, 15.

## B. Open — confirmed, not fixed

| # | Bug | Severity | Why not yet |
|---|---|---|---|
| O1 | Two throttles tight enough to stop the charge suppress the binary pause. ACC stops believing it is charging, so capacity/temperature never assert. Nothing is charging so nothing is harmed, but the hold depends on the throttle | low | needs a main-loop restructure; not safe unsoaked |
| O5 | Resume latency in the slow condition: after an input-suspend cut, raising the limit took ~4 min to resume where the fast condition took seconds | **unknown** | not yet measured properly — could be a nap, config propagation, or the recovery path |

## C. Open — reported, unconfirmed on the reporter's device

| reporter | symptom | our status |
|---|---|---|
| **sweet** (Redmi Note 10 Pro) | charging not stopped at max temp | fixed by 1+2+6; **never confirmed on his phone** |
| **curtana** (Redmi Note 9S) | fast charge gone, stuck 5 V / no 9 V | 8+9 fix the ACC side; his last bundle still showed 4.83 V — **unconfirmed** |
| **fleur** (Redmi Note 12) | phone powers off overnight | **ACC exonerated** — shutdown trace absent, and the trace mechanism proven to write. Cause unknown, watcher deployed |
| **bramble / Pixel** | AMPS `pcap` detection | fixed in AMPS 7.2.3, unconfirmed |
| **Realme GT Neo 2** | cooldown kills VOOC | `fast_session` guard, unverifiable without the device |
| **OnePlus SM8250** | probe crash into EDL | latch exists, unverifiable |

## D. Investigated and correctly NOT changed

| finding | evidence |
|---|---|
| USB re-kick does not collapse a fast-charge contract | fired alone on a healthy 1.95 A charge: nothing moved. Repeated on a genuine 9 V PD contract: held 8675 mV across a cap-and-clear |
| The A3's charger collapse is not ACC | ~500 mΩ series resistance measured; input walks to 0 identically with ACC **uninstalled and never executed** this boot |
| The "KNOWN GAP" (raising pause while latched does not resume) | was the frozen daemon. Re-measured at the documented conditions: resumed in 25 s |

## E. The common cause

Eleven of the sixteen fixes are the same mistake in different clothes.

**ACC learns per-device facts and then trusts them absolutely.** Which nodes are the gauge, what unit the current is in, which sign means charging, what the "default" for a node was. Each is a guess that was right once. Nothing tracks confidence, nothing re-validates, and when one is wrong the failure is always silent and always total — `is_charging` goes false and all four limits stop being evaluated together.

Three recurring shapes:

1. **An inference treated as a fact.** `_DPOL`, `_ccd=0` counted as a verdict, `[ -f cache ]` meaning "usable", a probe-time snapshot called a "default", a coerced 25 °C indistinguishable from a measured one. Bugs 1, 2, 3, 9, 12, 14, 15.
2. **A guard whose condition can never be met.** `.dpol_unstable` armed only by a path that cannot run on a tapering pack; the thermal clamp that only holds above `start`. Bugs 3, 6.
3. **A decision taken before a sleep and acted on after it.** Cooldown re-enable, main resume. Bug 11.

`state-export.sh` already computes `currentUnits`, `polarity`, `polaritySource`, `statusTrust`, `confidence` per device — and the daemon consults none of it. That is the structural fix still outstanding, and it is what would turn every one of these from silent into loud.

## F. Fixing one caller is not fixing the bug

Bug 14 is bug 12 in a place I did not look. The rebuild decision was wrong in four files; I fixed
the one the failing test happened to exercise and the other three kept the defect, including the
two that AccA actually reads through. It survived because the A3's daemon restarted by chance
during the run, which repaired the cache and scored a pass — the Pixel, whose daemon stayed up,
failed the identical check.

Two rules from that:

- When a decision is duplicated across callers, replace the duplicates with one named test. Bug 14's
  fix is a `_cache_usable()` in the file all four already source, not a fifth copy of the condition.
- A pass on one device and a fail on another is not flakiness to average out. It is two different
  states, and the passing one is usually passing for a reason that has nothing to do with the fix.
