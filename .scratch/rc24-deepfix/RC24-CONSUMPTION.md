# What ACC costs: VR25 original vs rc23 vs rc24

Measured 2026-08-21 on two phones, both unplugged, screens off, nobody touching them.

## Method

Four arms per phone. `off` is no ACC daemon at all and is the floor everything else is measured
against — it is not assumed, it is measured as often as the builds are.

| | |
|---|---|
| Arms | `off`, `vr25` (202505180), `rc23` (202505331), `rc24` (202505332) |
| Rounds | 3, arm order rotated each round |
| Window | 180 s measured, 45 s settle discarded |
| Sampling | `battery/current_now` every 3 s → ~57 samples per window |
| Also recorded | daemon CPU jiffies and `/proc/stat` fork count (counters, not samples) |
| Gates | screen verified off, cable verified absent, daemon verified alive **and accruing CPU** |

Rotating the arms means a drift in temperature or state of charge lands on a different arm each
round instead of being attributed to one build. Verifying the daemon accrued CPU matters because a
build that crashed would burn nothing and win the benchmark outright.

**Why `current_now` and not `charge_counter`.** An earlier attempt on these phones used
`charge_counter` and produced nothing usable: it is quantised at 2000 µAh on the Pixel, and on the
Mi A3 it is derived from the capacity percentage and did not move across 200 s of confirmed
discharge — ten identical readings. A metric that cannot move cannot rank anything.

**The outlier rule, stated before the results.** Windows whose sample spread exceeded 2000 mA were
discarded. The separation is not a judgement call: normal windows spread 122–583 mA, contaminated
ones 6536–19053 mA. Something in the system woke during those, and a 19 A swing is not a
measurement of idle drain. 5 of 24 windows were dropped.

## Results

### Mi A3 — laurus, Snapdragon 665

| arm | n | idle mA | daemon ms/min | forks/min | CPU-seconds/day |
|---|---|---|---|---|---|
| off | 2 | 158 | 0 | 120 | — |
| VR25 | 2 | 145 | **1535** | +94 | **2210** |
| rc23 | 1 | 144 | **196** | −12 | **282** |
| rc24 | 3 | 138 | **180** | −14 | **259** |

Floor windows span **17 mA** — that is this phone's resolution today.

### Pixel 6a — bluejay, Tensor

| arm | n | idle mA | daemon ms/min | forks/min | CPU-seconds/day |
|---|---|---|---|---|---|
| off | 2 | 66 | 0 | 338 | — |
| VR25 | 3 | 61 | **2106** | +319 | **3032** |
| rc23 | 3 | 58 | **470** | +39 | **676** |
| rc24 | 3 | 71 | **474** | +36 | **682** |

Floor windows span **18 mA** — this phone's resolution today.

## What the numbers say

**Measured drain cannot separate any of them.** On both phones every build sits within the floor's
own spread, and several read *below* the floor, which is physically impossible and is the clearest
possible sign that this column is noise at this resolution. Whatever ACC costs, it is smaller than
what a phone's own current sensor resolves over three-minute windows.

**The counters separate them cleanly, and reproducibly.** CPU time and fork counts come from
`/proc`; they are counters, not samples, and they have no error bars. An independent run earlier the
same day under different conditions (wakelock held) gave 2234 / 508 / 520 ms/min on the Pixel
against 2106 / 470 / 474 here — the same ordering and within about 10%.

| | Mi A3 | Pixel 6a |
|---|---|---|
| rc24 vs rc23 | **92%** of rc23's CPU | **101%** of rc23's CPU |
| VR25 vs rc24 | **8.5×** rc24 | **4.4×** rc24 |

**rc24 costs the same as rc23** — within ±8% across two chipsets, which is inside the run-to-run
variation. The safety work in rc24 is free.

**VR25's original is 4.4× to 8.5× the CPU of either fork**, and 3–9× the fork rate.

## Turning CPU into battery, honestly

A daemon at 474 ms/min occupies 0.79% of one core and accumulates 682 CPU-seconds per day. Turning
that into milliamp-hours needs a per-core power figure, and this rig does not measure one.

Assuming a little core between 150 mW and 400 mW — the usual range for this class of silicon —
682 CPU-seconds/day is **7–20 mAh/day**, or **0.2–0.5%** of the Pixel's 4068 mAh battery. VR25's
3032 CPU-seconds/day is **33–88 mAh/day**, 0.8–2.2%.

**This estimate is consistent with the measurement, and that is the point.** 7–20 mAh/day averages
0.3–0.8 mA, far below the 18 mA the direct measurement can resolve — so "indistinguishable from no
ACC" is exactly what the estimate predicts. The two methods agree.

An earlier attempt derived the coefficient from a pegged CPU core and predicted ~690 mAh/day, which
would be 29 mA and would have been plainly visible in the drain column. It was not visible, which is
how that coefficient was known to be wrong: a pegged core sits at the top of the DVFS range and a
daemon that wakes for milliseconds does not. That figure was discarded rather than published.

## Limitations

- Two phones, two chipsets. Nothing MTK, Exynos or Samsung.
- Idle, screen off, unplugged. This is most of a phone's day but it is not all of it; a plugged
  daemon loops far more actively and was not measured here.
- The energy conversion carries an assumed per-core power. The CPU-seconds are exact; the
  milliamp-hours are an estimate with its assumption stated.
- 5 of 24 windows discarded by the stated outlier rule.

## Reproducing this

```
suites/consumption-4arm.sh          # the measurement
suites/consumption-4arm-report.sh   # the table
```

Needs `vr25tree`, `rc23tree` and `rc24tree` staged under `/data/local/tmp`. The module is backed up
and checksum-verified before anything is swapped, and restored from a trap on every exit path — both
runs here ended with `restore VERIFIED: checksum 3421293918`.
