# ACC bug register — rc21 → rc22

Everything found, fixed, or still open. Baseline is rc21 `1406274`, current build `202505310`.

## A. Fixed (24)

All hardware-verified on the A3, the Pixel, or both, except **16**, which is source-only and flagged
as such in the table.

Coverage at `202505310`, both switch classes and all three supply conditions:

| | unplugged | slow (500 mA) | fast |
|---|---|---|---|
| A3 (generic `input_suspend`) | 53 / 0 | O5: 6 trials, all <= 15 s | 20 / 21 (its charger drops out) |
| Pixel 6a (native `charge_stop_level`) | 56 / 0 | 53 / 0 | 56 / 0 |

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
| 15 | `temp_now` coerced an unreadable sensor to 250 (25 °C), so the thermal limit silently stopped being enforced with nothing anywhere saying so | `accd.sh` | t42 9/0; sandbox: 2 log lines across 4 failing reads + recovery; on both phones since 202505304 |
| 20 | **Two USB re-kick gates with independent timestamps and intervals** (accd 300 s, misc-functions 30 s). Neither saw the other's firings, so the protective gap collapsed: `apsd_rerun` fired every 15-62 s, renegotiating the charger continuously, and the charge never established | `accd.sh`, `misc-functions.sh` | t35 17/0; A3 with no limit set: storm before, **0 fired in 6 min** after; one gated kick then recovered it from 400 mA ICL to 1144 mA |
| 19 | A voltage limit was stored on a phone with no voltage control node, so AccA showed a limit nothing could apply | `set-ch-volt.sh` | Pixel A/B: `(3900)` -> `()`; the grid now honestly SKIPS the 8 voltage subsets instead of failing them |
| 18 | **Current caps silently did nothing.** The rc22 apply-side marker guard refuses to write a current node while `.mcc-custom` is absent, but `set_ch_curr` created that marker AFTER the apply, so the first apply was always skipped. Config, node list, marker and `acc -i` all reported a limit that was never written | `set-ch-curr.sh` | t43 7/0; Pixel A/B, 500 mA cap on 2.2 A: A wrote **zero** nodes, rate 1440 mA; B wrote 6 nodes, rate 576 mA. Grid confirms: current-cap row went FAIL to PASS |
| 17 | The daemon never republished its own interface cache. It sources the file once at init and runs from memory, so losing the file cost it nothing and it never noticed — but that file is what `acc`, AccA and switch-scan read | `accd.sh`, `batt-interface.sh` | A/B both phones, daemon pid unchanged: A 480 s at 0 bytes, B healed in 20 s with polarity preserved (`+` A3, `-` Pixel) |
| 21 | The learned charge polarity was lost whenever the cache was republished: `_cache_republish` wrote `_DPOL` from a variable the daemon's main shell does not always hold, so ACC had to re-derive direction from scratch | `misc-functions.sh`, `batt-interface.sh` | A3: `.dpol='+'` seeded, polarity survived a live rebuild. Sandbox covers all 4 states; the `|| :` guard prevents a `set -eu` abort |
| 16 | `.testingsw` was an empty marker, so a scan killed by SIGKILL was indistinguishable from one in progress | `misc-functions.sh`, `acc.sh` | source only. **NOT yet on a phone** |

**Silent ones** (no user could have reported): 4, 5, 6, 12, 14, 15.

## B. Open — confirmed, not fixed

| # | Bug | Severity | Why not yet |
|---|---|---|---|
| ~~O1~~ NOT REPRODUCIBLE | Two throttles tight enough to stop the charge suppress the binary pause. **Reproduced on the A3 grid** (`CTA-`: level 71 >= pause 71 and 34 C > max 32 C, both pauses skipped because the 381 mA cap made the pack net-negative and `is_charging` went false). Did NOT reproduce on the Pixel. ACC stops believing it is charging, so capacity/temperature never assert. Nothing is charging so nothing is harmed, but the hold depends on the throttle | low | needs a main-loop restructure; not safe unsoaked |
| ~~O6~~ FIXED as bug 19 | On a phone with no voltage control node, `max_charging_voltage` prints "No voltage control file found", then prints a success tick and **persists the value anyway**. AccA reads config, not the CLI, so it shows an enforced-looking limit that nothing applies. Pixel 6a: `ch-volt-ctrl-files` absent | low | not safe to fix late in a stabilisation pass: a missing ctrl-file means either "unsupported" or "not resolved yet, phone has not charged since boot", and the current path persists intent deliberately so the daemon can apply at the next charging tick. Needs the two cases separated, then a soak |

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

Twelve of the eighteen fixes are the same mistake in different clothes. Bug 18 is a different one, and worse: a guard added in this campaign to fix bug 10 broke the thing it was guarding.

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

## G. The suite was wrong more often than ACC was

Seven false results came out of the harness today, and every one had the same shape: **a fixed
timing assumption standing in for waiting on a condition.**

| what it measured | what it actually measured |
|---|---|
| 22 s sample for loop liveness | ACC's deliberate 120 s idle nap, reported as "nothing is being enforced" |
| CPU delta across 60 s | a daemon restart resetting the counter; -52 ticks scored a PASS |
| `restart()` sleeping 38 s | enough on the Pixel, not on the slower A3 — the same check passed on one phone and failed on the other |
| "cache healed" = non-empty | 8 bytes of `_DPOL=+` from `sdp()`, with no gauge and no current node |
| "still correct" = not `Charging` | an empty answer, scored as correct |
| drain labelled "idle" | drain with the suite itself keeping the CPU awake |
| L4 grid | a stub that skipped, in the pass the grid was the point of |

The cost was real: the `restart()` one alone reported a product bug twice, the second time *after* a
targeted A/B had proven that same phone healed in 20 s. A suite that cries wolf on a correct build is
worse than no suite, because the next real failure is the one you argue with.

The rule that came out of it: **never sleep a guess at how long a phone takes.** Poll for the
condition, with a ceiling. Every wait in the harness now does that.

And the corollary, from bug 14: **a pass on one device and a fail on another is not flakiness to
average out.** It is two different states, and the passing one is usually passing for a reason that
has nothing to do with what is being tested.

## H. The A3's charger is no longer a valid instrument

The A3's grid reports six failures. Its own no-limits control row is one of them:

    FAIL  none: no limit set -> nothing is set, yet the pack measured THROTTLED (105 mA vs free 524)

With nothing configured, ACC cannot be the cause. The supply degraded across the session -
`Fast` 2.0 A, then `Taper` 1.75 A, then 0.56 A drawn at 4.53 V - and the measured free rate fell from
1503 mA (noise floor 187 mA) to 524 mA (noise floor 65 mA). `.dpol_unstable` armed during the run,
which is ACC correctly detecting the current polarity flipping as the charge path changed under it.

This matches the ~500 mΩ series resistance measured earlier in the campaign and reproduced with ACC
uninstalled and never executed. The A3's throttle rows are not measurements of ACC and are not
counted against it. Its binary-limit rows, which need far less headroom, still pass.

**The A3 needs a different cable and charger before its grid means anything.** The Pixel, on a 9 V PD
contract, is the trustworthy instrument for throttle behaviour and reports 20/1.

## I. The re-kick storm changes the A3 story

Section D concluded the A3's charger collapse was ~500 mOhm of cable resistance, on the strength of it
reproducing with ACC uninstalled. That is still true, but it was not the whole cause.

With no limit configured at all, ACC was firing `apsd_rerun` every 15-62 seconds (bug 20). Each one
re-runs USB source detection. Measured consequence: the pack sat at 0 mA for five minutes with the
cable in, level drifting 67% down to 65%, and the input settled at 400 mA. After the fix, six minutes
produced zero re-kicks, and a single gated kick took it from 400 mA back to 1144 mA.

So the resistance is real and the storm made it much worse, and prevented recovery. Both were needed
to produce what the tester saw. The lesson is narrower than "it is the cable": a hardware weakness and
a software defect can produce one symptom together, and proving one does not clear the other.

## J. O5 closed: it does not reproduce, and bug 20 probably caused it

O5 was "after an input-suspend cut, raising the limit took ~4 min to resume on a slow supply".
Measured on the A3 on a real 500 mA source, on the generic `input_suspend` switch the report was
about, with the input confirmed cut on every trial:

| trigger | paused after | resumed after |
|---|---|---|
| capacity, 3 runs | 2 s, 4 s, 4 s | 15 s, 6 s, 7 s |
| temperature, 3 runs | 2 s, 2 s, 4 s | 15 s, 15 s, 6 s |

Worst case 15 s. Both pause paths were timed separately because capacity and temperature are
different terms in the daemon, and three runs each because one measurement is an anecdote.

The likely original cause is bug 20. Before it was fixed, ACC fired `apsd_rerun` every 15-62 seconds
regardless of the rate limit, and on a slow supply that re-negotiates the input from nothing each
time. A charge that has to survive a re-detection every half minute on a 500 mA source is exactly
how a resume takes minutes instead of seconds. The Pixel's native firmware limit never drops the
input at all, which is why its 6 s result could not answer this - different switch class, different
failure mode.

## K. O1 could not be reproduced, and the guard has never fired

O1 was accepted on the strength of one A3 grid row: `CTA-`, level 71 against pause 71, 34 C against
max_temp 32, switch reading ON. Deliberate attempts to reproduce it, all on hardware:

| attempt | result |
|---|---|
| 300 mA cap, laptop USB-A (500 mA), screen off | ACC reports Charging - throttle never starved it |
| + 3700 mV voltage cap under a 3928 mV pack | still Charging |
| + screen on | still Charging |
| laptop USB-C (1.2 A), same caps + screen | still Charging, level climbed 54% to 59% |
| USB-A + caps + screen + **8 busy cores** | `acc -i` reports Discharging - condition looked reached |

The last one was the closest, and it is what settled it. An unconditional debug line at the top of
the guard's branch logged **zero** times across that entire run. The daemon never entered it: every
flight.log line was tagged `Charging`, and the ledger shows it cutting `input_suspend` and releasing
it again through the ORDINARY path. `acc -i` and the daemon disagreed only because they sample at
different moments.

So the premise - that the daemon stops believing it is charging while plugged with a limit reached -
was never demonstrated. The original row was sampled 40 s after applying limits, which is the same
measurement-timing class that produced several false findings in this campaign.

**The guard stays**, because it costs one condition per loop in a branch that is already rare, and if
the state ever does arise the limit will hold. It is a backstop, not a fix for a proven defect, and
the code says so. Twelve of these findings were verified by A/B on hardware; this one was not, and it
is not counted among them.

## L. Correction: what bug 22 is and is not

I described bug 22 as ACC restoring "a restriction it had not created". That is not accurate and the
register should not have said it.

Measured after a clean reboot on the A3, before ACC restored anything:

    qcom-battery/restrict_cur = 1000000     the vendor's own boot value
    qcom-battery/restrict_chg = 0           restricted mode NOT engaged

So 1000000 is the hardware's own default for that node, not something ACC invented. ACC recorded it
correctly. What ACC got wrong was writing it back on a RESTORE, because a restore means "ACC is no
longer capping this" and the right action there is to release the ceiling high and let the driver
clamp - the same rule already applied to usb/current_max and the other input nodes.

It still matters, because restrict_chg is engaged by the vendor at runtime (it read 1 during the
earlier sessions), and once engaged a restrict_cur of 1000000 bites. Lifting the pair took that phone
from 4.64V/1.51A to 5.97V/3.03A.

So: real bug, real measurement, wrong description. The fix is unchanged.

## M. Bugs 23-25: switch discovery could slow or stop a healthy charge

Found by an eight-way parallel audit of every path that could reduce charging speed with nothing
configured. 34 candidates, 4 survived adversarial refutation, and they collapse to three sites - all
in the DISCOVERY window, none in steady state. That reconciles them with the hardware number: with a
switch already locked ACC charges 247 mA FASTER than unmanaged, because it releases ceilings the
vendor left low. No steady-state measurement covers a fresh install or a scan.

| # | Bug | Where | Proof |
|---|---|---|---|
| 23 | A **rejected** switch candidate was left latched OFF for the whole session, with no restore anywhere. Values held: `*/current_max 0`, `*/constant_charge_current 0`, `charge_stop_level 5`, `siop_level 0` — the phone could sit at zero current while ACC reported normal | `misc-functions.sh` | t46 15/0; the failure arm ten lines below already had the level check, the reject arm did not. One helper, both callers |
| 24 | A scan's `restore_all_on` replayed the probe-time **snapshot** over ACC's own HIGH release, because `awk '!seen[$0]++'` puts the snapshot second and the sweep runs top to bottom. Ends a scan with `usb/current_max` at 2.2 A after ACC negotiated 2.8 A | `acc-switch-scan.sh` | t46; negotiation-owned nodes now skipped, binary switches still restored |
| 25 | Discovery cut a healthy charge at **any** battery level. An empty `chargingSwitch` is the shipped default, so a fresh install stopped a 40% charge to find a switch it would not need until 80% | `accd.sh` | t46; `probe_due` waits until within 5% of the pause level and fails OPEN on every unparseable case |

t46 is mutation-verified at 1/14 against the rc21 baseline.

**Not yet demonstrated on hardware.** All three live in the discovery window, and both test phones
have a switch locked, so a steady-state run cannot exercise them. Proving them needs the switch
blanked (`acc -s charging_switch=`) on a live charge, watching whether ACC cuts a healthy charge to
hunt for a switch it does not need yet. Until that runs, these are source- and sandbox-verified only,
and the register should not claim more.
