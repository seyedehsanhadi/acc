# Diagnostic bundle: coverage, size, and test audit

Measured on the Mi A3 (laurus, Android 10, Magisk), collector 1.0, 2026-07-22.

## 1. Coverage: does the bundle carry every signal a report could need?

Grouped by source. "In bundle" is what a live `acc --diag` produced; "reachable" means the
data exists on-device and the collector reads it whenever it is present.

### Android native (already logged 24/7, read passively)

| Source | What it proves | In bundle | Notes |
|---|---|---|---|
| logcat crash buffer | app FATAL stacks (the exact exception) | yes | |
| logcat main+system | app + framework runtime around the fault | yes | whole ring (~2.4k lines) |
| dmesg (kernel ring) | charging driver, thermal, current-boot kernel | yes | recent 8000 lines |
| pstore / console-ramoops | previous-boot kernel log (panic, shutdown) | yes | the reboot smoking gun |
| last_kmsg | previous-boot kernel via the legacy path | yes | kept alongside pstore on purpose |
| DropBox (crash/anr/panic/watchdog) | crashes Android archived persistently | yes | index + the entry bodies |
| tombstones | native (C/C++) crash dumps | yes | |
| ANR traces | app-not-responding thread dumps | yes | |
| bootreason props | why the last boot ended | yes | |
| thermalservice + zones | thermal throttle / shutdown state | yes | |
| dumpsys battery + power_supply | charging hardware truth (current, status, csl) | yes | |
| deviceidle/doze + power | schedule miss, standby drain | yes | |
| SELinux avc denials | "won't start" / wrong-context bugs | yes | dmesg + logcat |
| getprop | every system property (ROM, SoC, flags) | yes | |
| full bugreport / dumpstate | everything, kitchen sink | no | minutes to run, 10-50 MB, ~90% redundant with the rows above |
| systrace / perfetto | scheduler/perf trace | no | huge, only for perf work, not charge-control bugs |
| batterystats full history | per-app battery timeline | partial | the charge-relevant slice is in doze-power; full history is bulky and rarely needed |

### ACC side (our own logs; the primary evidence)

| Source | What it proves | In bundle |
|---|---|---|
| flight.log | every charge-control decision | yes |
| write.log / write-ledger | every sysfs node write | yes |
| init.log | daemon init history | yes |
| install.log | flash/install history | yes |
| early-cap.log | the early-cap panic guard firing | yes |
| warnings.log | daemon warnings | yes (when non-empty) |
| accd loop trace (tmpfs) | the live daemon loop | yes |
| reboot-history (PERSISTENT) | previous boots' reason + pre-boot ACC state | yes |
| state.json | daemon snapshot at collect time | yes |
| config.txt (full + active) | exactly what the user set | yes |
| panic self-heal journals | blacklist / pending-node state | yes |
| AMPS verified + full report | switch-finder result | yes (when present) |

### AccA side (the app; the one genuinely new capture path)

| Source | What it proves | In bundle |
|---|---|---|
| last-crash.txt | app crash stack + the breadcrumb trail at the crash | yes (on any app crash) |
| breadcrumbs.txt | recent app events incl. `startup: root+acc detection=…` | yes (flushed on collect) |
| debug_log.txt | app file log | yes (only if the user turned it on) |

**Verdict:** every failure class we enumerated (18 of them: crash, ANR, native crash, kernel
panic, reboot, thermal shutdown, won't-start, charge-stuck, over/undercharge, daemon-down,
switch-not-found, config-corrupt, drain, schedule-miss, …) has at least one confirmed evidence
source in the bundle. The only omissions are the deliberately-excluded giants (full bugreport,
systrace), whose signal is already covered ~90% by the targeted sources at a fraction of the size.

## 2. Size: 268 KB, and why it is not "massive"

For reference: a full Android bugreport is 5-50 MB; one phone photo is 2-5 MB. This bundle is a
single chat attachment.

**Applied (free / safe, zero signal lost):**

| Lever | Before | After | How |
|---|---|---|---|
| compressor | gzip-6, 347 KB | **bzip2-9, 268 KB** | bzip2 is on-device and ~24% tighter on logs; gzip stays as the universal fallback |
| dmesg | 979 KB raw | 790 KB raw | cap to the recent 8000 lines (oldest boot spam only) |

Net: **347 KB -> 268 KB (-23%)**, nothing a report needs was dropped.

**Where the 268 KB goes (approx compressed contribution):**

| File | raw KB | ~comp KB | keep-full reason |
|---|---|---|---|
| dmesg | 790 | ~80 | charging driver + thermal, live boot |
| logcat main+system | 335 | ~40 | app+framework around the fault |
| pstore-console | 254 | ~28 | reboot/panic evidence |
| last_kmsg | 254 | ~28 | reboot/panic evidence (2nd path) |
| accd loop trace | 165 | ~22 | the daemon's actual behavior |
| avc denials | 98 | ~9 | context / won't-start |
| init.log | 77 | ~13 | our init history |
| tombstones x2 | 106 | ~15 | native crashes |
| anr | 57 | ~8 | app hangs |
| install.log | 48 | ~9 | our install history |
| getprop | 47 | ~11 | device/ROM facts |
| everything else | ~90 | ~5 | config, state, journals, breadcrumbs |

**Optional aggressive mode (NOT applied; each trades away debuggability):**

| Extra lever | Saves | What you lose |
|---|---|---|
| drop last_kmsg when pstore present | ~27 KB | the redundant 2nd copy of the reboot log (low risk, but it is the evidence we care most about) |
| dmesg tail-4000 instead of 8000 | ~40 KB | more current-boot kernel history |
| avc sort-unique | ~5 KB | denial timing/correlation |

Aggressive would reach ~190 KB. Recommendation: **stay at 268 KB.** The floor is set by
irreducible high-value data (kernel + crash logs), and the aggressive cuts chip at exactly the
reboot evidence this whole thing was built to preserve.

## 3. Tests, stress, and edge cases

| # | Case | Type | Device | Result |
|---|---|---|---|---|
| 1 | `acc --diag` (CLI front-end) | functional | A3 | 34 sources, 268 KB, 0 absent-ambiguous |
| 2 | AccA "Deep diagnostic" button | functional | A3 | proven earlier (saved 30-src bundle); re-verifying after the `.tar.bz2` parser fix |
| 3 | both front-ends -> identical bundle | equivalence | A3 | same collector, same manifest |
| 4 | `--sample` 20s live loop | functional | A3 | +1 source (sample-20s.txt) |
| 5 | app crash capture (`am crash`) | functional | A3 | last-crash.txt (651b) = full FATAL stack + breadcrumbs |
| 6 | startup breadcrumb | functional | A3 | `startup: root+acc detection = ok` recorded |
| 7 | reboot archiver per-boot guard | functional | A3 | archives once/boot; rides in bundle as reboot-history |
| 8 | bzip2 present -> used | functional | A3 | `.tar.bz2`, 268 KB |
| 9 | bzip2 absent -> gzip fallback | edge | code | `command -v bzip2` guard; gzip path is the original, already proven |
| 10 | manifest zero-ambiguity | correctness | A3 | every source is OK / EMPTY / ABSENT with a reason |
| 11 | `.tar.bz2` path parsing in the app | edge | code | regex widened from `\.tgz` to `\S+`; MIME -> octet-stream |
| 12 | `acc` not on PATH (Tensor) | edge | code | app falls back to the module path `/data/adb/vr25/acc/diag-collect.sh` |
| 13 | /sdcard not writable | edge | code | output falls back to /data/local/tmp |
| 14 | no root | edge | code | app returns null + export-failed; CLI needs root by contract |
| 15 | daemon under churn (dozens of flash cycles) | stress | A3 | still collects; state.json + trace intact |
| 16 | zero background cost | non-functional | A3 | passive reads only; no daemon/wakelock/alarm/poll added |
| 17 | AccA button end-to-end (UI-driven) | functional | A3 | tapped "Deep diagnostic"; app parsed `.tar.bz2`, copied 284 KB / 41 entries into filesDir; carries breadcrumbs + last-crash |
| 18 | redaction masks serial/MAC/email | privacy | A3 | `[ro.serialno]: [REDACTED]`; real serial absent from the whole bundle |
| 19 | redaction keeps signal / no corruption | privacy | A3 | device=laurus intact; getprop 1168 lines, uncorrupted |
| 20 | `--diag-verbose on` -> auto-sample | functional | A3 | armed 2h; next collect auto-took the 20s sample (21 lines) |
| 21 | `--diag-verbose off` / expiry cleanup | functional | A3 | disarm clears it; a 0h flag is auto-removed on next collect |
| 22 | verbose flag = zero battery | non-functional | A3 | flag only steers the on-demand collector; daemon loop untouched |
| 23 | DJS last-run/schedule capture | coverage | A3 | djs.txt: module version + schedule files + running (DJS installed) |

Open (Pixel/Tensor, device not currently connected): pstore-absent FBE path, acc-not-on-PATH live via Termux, crash capture on Tensor. Collector is device-agnostic and the Tensor-specifics are already handled, so this is confirmation rather than new risk.
