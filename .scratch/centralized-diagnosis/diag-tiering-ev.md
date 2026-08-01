# Making the bundle efficient: an expected-value analysis

The bundle is 268 KB compressed / 2.3 MB raw / ~600k tokens to read in full. Two real costs:
the user's upload, and the tokens spent reading it. The naive fix (drop sources) risks throwing
away the one file that would have solved the case. This document works out the efficient middle.

## The reframe

The question is not "which sources do we keep." It is "which sources earn their size on an
*average* report." A source earns its place by **P(decisive)** -- the chance it holds the evidence
that pins the root cause for a random report. A 250 KB file that decides 7% of cases is expensive;
a 1 KB file that decides 40% is nearly free. And crucially: the expensive files are decisive
exactly when a *cheap* signal already says so (a reboot happened, an app crashed). So we can carry
them only then.

## The probability model

Reported problem classes for a charge-control module, with rough frequencies (from this project's
own bug history: overcharge/undercharge, daemon-won't-start, reboot/EDL, switch-not-found,
config-corrupt, standby-drain, app-stuck). These are informed estimates, meant to be tuned, not
gospel.

| Class | freq | decided by |
|---|---|---|
| charge won't stop/start at limit | 35% | config, flight.log, state.json, switch test, battery |
| app crash / won't open / stuck | 20% | last-crash, logcat-crash, breadcrumbs, ANR |
| daemon won't start / not running | 15% | init, install, accd-trace, state.json |
| drain / overheating | 8% | doze-power, thermal, flight.log, dmesg(thermal lines) |
| reboot / bootloop / EDL | 7% | pstore, last_kmsg, bootreason, reboot-history, dmesg |
| wrong/again switch | 7% | AMPS report, switch test, config |
| overcharge to 100% / undercharge | 5% | flight.log, config, state.json, battery |
| native crash | 2% | tombstones, DropBox |
| SELinux / won't-start (context) | 1% | avc-denials |

## Per-source efficiency (P-decisive per KB)

Sizes measured on A3. "eff" = P(decisive) / raw-KB, the value per token spent reading it.

| Source | raw KB | comp KB | P(decisive) | eff | verdict |
|---|---|---|---|---|---|
| _SUMMARY | 1 | 1 | 0.90 (triage) | very high | CORE |
| config full+active | 18 | 2 | 0.45 | high | CORE |
| flight.log | 36 | 7 | 0.40 | high | CORE |
| state.json | 1 | 0.3 | 0.35 | very high | CORE |
| battery/power_supply | 0.7 | 0.3 | 0.30 | very high | CORE |
| logcat-crash | 2 | 0.5 | 0.20 | high | CORE |
| last-crash + breadcrumbs | 1.2 | 0.5 | 0.20 | high | CORE |
| write-ledger | 0.8 | 0.2 | 0.15 | high | CORE |
| AMPS + switch test | 2 | 1 | 0.12 | high | CORE |
| reboot-history (persistent) | 10 | 2 | 0.10 | med | CORE |
| doze-power | 7 | 1 | 0.06 | med | CORE |
| thermal | 3 | 0.5 | 0.08 | med | CORE |
| bootreason / early-cap / journals | 1 | 0.4 | 0.08 | high | CORE |
| env / djs | 8 | 1 | 0.03 | low | CORE (small) |
| accd-trace | 165 | 22 | 0.15 | low | CORE tail (~30 KB) + full on signal |
| init.log | 77 | 13 | 0.15 | low-med | CORE tail + full on signal |
| install.log | 48 | 9 | 0.10 | low-med | CORE tail + full on signal |
| dmesg | 790 | 80 | 0.15 | very low | CORE filtered (~15 KB comp) + full on signal |
| logcat main+system | 335 | 40 | 0.15 | low | CORE filtered + full on signal |
| avc-denials | 98 | 9 | 0.01 | ~0 | CORE our-context only (~1 KB) + full on signal |
| getprop | 47 | 11 | 0.03 | low | CORE curated subset (~1 KB) + full on signal |
| pstore-console | 254 | 28 | 0.07 | very low | HEAVY, auto on reboot signal |
| last_kmsg | 254 | 28 | 0.07 (dup of pstore) | ~0 | HEAVY, auto on reboot signal |
| tombstones | 106 | 15 | 0.02 | very low | HEAVY, auto on crash signal |
| anr | 57 | 8 | 0.05 | low | HEAVY, auto on ANR signal |

## The design: core, always; heavy, only when a cheap signal says it matters

Three collection modes, default is adaptive:

- **CORE (always):** every small high-P source in full, plus *filtered slices* of the big ones --
  dmesg grepped to charge/thermal/power/panic/our-module, logcat to our package + errors, avc to
  our own context, getprop to a curated ~20-key subset, and tails of init/install/accd-trace. This
  is ~30-40 KB compressed, ~45-70k tokens, and it fully decides an estimated ~80% of reports.

- **HEAVY, auto-attached on a positive signal the collector already computes for the summary:**
  - fresh reboot (abnormal bootreason, or pstore present, or a recent reboot-history entry)
    -> add full pstore + last_kmsg + full dmesg.
  - fresh app crash / native crash / ANR (recent DropBox / tombstone / last-crash / anr mtime)
    -> add tombstones + anr + full logcat.
  The heavy raw rides along exactly when the case is the kind that needs it, with no user action.

- **`--full` override** grabs everything regardless; **`--core`** forces minimal (no heavy even if
  signalled). The manifest always records the mode and what was deferred, so a gap is never silent.

## Expected values

Let the "heavy signal present" rate be ~25% of reports (crash 20% + reboot 7%, minus overlap).

| | upload (E) | tokens to read (E) | P(decisive evidence present) |
|---|---|---|---|
| now (one fat bundle) | 268 KB | ~600k | ~1.0 |
| **adaptive (proposed)** | 0.75x35 + 0.25x215 = **~80 KB** | 0.75x60k + 0.25x450k = **~160k** | **~1.0** |
| pure two-tier (`--full` only, no auto) | ~35 KB flat | ~60k flat | ~1.0 after one round-trip for the 25% |

Adaptive keeps P(decisive present) at ~1.0 with **no round-trip**, at ~3-4x less upload and ~4x
fewer tokens on average. The common 75% of reports cost 35 KB / ~60k tokens -- an 8-10x cut -- and
I only pay to read the heavy logs when the heavy logs are actually the point.

## What this drops, makes optional, and keeps

- **Kept, always, in full:** every small high-P source (config, state, flight, battery, crash,
  breadcrumbs, switch/AMPS, reboot-history, thermal, doze, bootreason, journals).
- **Kept, always, filtered:** dmesg, logcat, avc, getprop -- the decisive slice in core, the full
  raw only on signal or `--full`.
- **Optional (auto on signal):** pstore, last_kmsg, tombstones, anr, full dmesg/logcat, full
  init/install/accd-trace.
- **Truly redundant:** last_kmsg duplicates pstore; in `--full` we keep both (reboot insurance),
  in auto-reboot we can keep pstore + a short last_kmsg tail.

## No information is lost

The heavy data is never deleted from the device -- it is *deferred*. For the ~80% of reports the
core decides, the raw kernel dumps were never going to be read. For the ~20% that need them, a
cheap on-device signal pulls them in automatically, or `--full` gets everything. The only thing
removed is the cost of shipping 250 KB of previous-boot kernel log to debug a config typo.

## Recommendation

Build the adaptive collector: core always, heavy auto-attached on the reboot/crash signals the
summary already derives, with `--full` / `--core` overrides. It is the only option that cuts both
costs by ~4-10x while holding P(decisive evidence present) at ~1.0 and needing zero round-trips.
