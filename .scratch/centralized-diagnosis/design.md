# ACC + AccA — one future-proof diagnostic log

Goal: any user (CLI-only or AccA) sends ONE file, and from that file alone we can debug ANY class of
problem — now and for bugs we haven't seen yet. Passive, on-demand, near-zero battery: it READS what
Android and ACC already log for free, it never runs a logger of its own.

## Design principles

- One collector, two front-ends. A single script is the source of truth; `acc --diag` (CLI) and AccA's
  one "Collect diagnostics" button both call it. A CLI user and an app user send the identical bundle.
- Passive only. No daemon, no polling, no wakelock. Everything below already exists on the device; the
  collector snapshots it on demand. The one new always-present piece is a small bounded in-memory
  breadcrumb ring (a few KB), never a persistent log.
- Read Android's free 24/7 sources. logcat ring buffer, pstore (kernel panic), DropBox (crash/ANR/
  watchdog/panic archive), tombstones, ANR traces, bootreason. All are produced by the OS whether we
  ask or not — we only extract.
- Self-describing + future-proof. A schema version, a collector version, and a completeness manifest
  (what was collected, what was absent and why). A missing section is explained, never ambiguous. The
  source list is data-driven, so adding a source later is one line.
- Privacy-scoped. Our package + charging subsystem only. Never other apps, never the whole system log,
  never PII. State what was redacted.

## The mass calculation: every failure class -> the exact evidence needed to debug it 100%

Each row is a distinct way ACC/AccA can fail, and the minimum evidence that makes it debuggable from
the log alone. The union of the "evidence" column IS the log spec.

| # | Failure class | Evidence the log MUST carry | Primary source |
|---|---|---|---|
| 1 | Overcharge (cap not enforced) | config caps+switch, live level/status/current over a short window, flight-recorder tail, switch-verdict | ACC flight.log + state.json + a 20s sample |
| 2 | Won't charge / undercharge | switch OFF value stuck, input_suspend / charge_stop_level / current nodes, restore evidence, charger online/negotiation | sysfs node dump + write-ledger |
| 3 | Daemon won't start | init.log, tmpfs (/dev/.vr25/acc) state, acquire-lock outcome, busybox/applet presence, service.sh reached?, bootreason | init.log + env probe |
| 4 | Reboot / boot-loop / EDL | bootreason history, pstore/console-ramoops/last_kmsg panic trace, early-cap.log + write-ledger (what ACC wrote pre-Android), thermal zones, DropBox kernel_panic, the 3 self-heal journals (.probe-blacklist/.earlycap-pending/.early-boot-count) | pstore + DropBox + bootreason + early-cap.log |
| 5 | #197 /system/bin soft-brick | root manager, /system real mount type (overlay vs magic-mount), overlayMount decision, skip_mount, install.log | install.log + /proc/mounts |
| 6 | App crash (uncaught exception) | full stack trace + thread, app version, the crash timestamp, breadcrumbs before it | AccA crash handler + DropBox data_app_crash |
| 7 | ANR / UI freeze | main-thread stack at the hang, ANR reason, breadcrumbs | DropBox data_app_anr + /data/anr |
| 8 | UI glitch / wrong value shown | state.json vs what the card rendered, breadcrumb trail, (optional) one screenshot | state.json + breadcrumbs |
| 9 | Switch detection wrong / verified-switch demands retest | AMPS verified artifact, last finder run log, applyMode decision, the observation table (native vs engaged mA/mV) | acc-compat-verified + switch-finder log |
| 10 | Config corruption / torn write | config.txt content, defensive-load fallback events, write-config trace, the atomic-publish outcome | config.txt + warnings.log + write.log |
| 11 | Schedule missed (DJS) | djs version, schedule list, last-fire timestamp per schedule, doze state, catch-up log | djs logs + schedule store |
| 12 | Fast-charge drop (Xiaomi/Realme/OnePlus) | mcc/cooldown config, write-ledger (what toggled the pump), charger/pump nodes, fast-charge guard state | config + write-ledger + sysfs |
| 13 | Battery drain caused by ACC | daemon poll/wakeup cadence, standby dumpsys-call count, next_sleep/nap behavior | flight.log + a short steady-state sample |
| 14 | Native-limit (Tensor) mis-behavior | google,charger nodes, allowIdleAbovePcap / prioritizeBattIdleMode, current-verified auto-lock outcome | sysfs + config + state.json |
| 15 | Thermal shutdown (shutdown_temp) | temperature band + runtime band-clamp, thermal zones, battery temp history | config + thermal + flight.log |
| 16 | Install/upgrade failure | install.log (full stderr trace), busybox resolution, root-manager branch taken | install.log |
| 17 | Uninstall left charging broken | uninstaller restore trace, which switch class it replayed, post-condition result | uninstall log (if run) + sysfs |
| 18 | Front-end <-> daemon desync | ACC handler/API version vs AccA expectation, acca bridge state, /dev symlink presence | About + state.json |

If a future bug is none of these, the same bundle still carries the raw material (logcat + DropBox +
pstore + state + config + breadcrumbs), so it is debuggable without a new capture path.

## The log: one bundle, versioned sections

Format: a single gzipped tar (`acc-diag-<device>-<UTC>.tgz`) OR, when a tarball is awkward, one text
file with `===== SECTION =====` banners. Header carries `schema=1  collector=<ver>`.

Sections (each optional + manifest-tracked):

- HEADER — schema, collector version, UTC time + a random case-id, uptime.
- IDENTITY — device/model/SoC, ROM, Android, kernel, root manager+version, ACC module ver, ACC
  handler/API ver, AMPS engine ver, AccA versionName+code, DJS ver.
- ENV — /system mount type, applet presence (start-stop-daemon/flock/setsid/timeout), /dev runtime
  dirs, disable/opt-out flags, FBE state.
- CONFIG — config.txt (verbatim) + the parsed interpretation.
- STATE — state.json (the daemon's own live snapshot: battery block, switch, native, sensing).
- SAMPLE — a bounded 15-20s read-only sample of level/status/current/voltage + a verdict
  (steady-charge / steady-pause / switch-fight). Only when the user picks "capture", not by default.
- ACC-LOGS — tails of flight.log, write.log, warnings.log, early-cap.log, init.log, the write-ledger.
- SWITCH — acc-compat-verified artifact + the last switch-finder log + the 4 legacy switch logs folded
  into one canonical verdict.
- ANDROID-NATIVE — logcat slice (`-d -b main,system,crash`, filtered to our package + charge tags,
  size-capped), pstore/console-ramoops/last_kmsg tails, `dumpsys dropbox --print` for our app-crash /
  app-anr / system-server-watchdog / kernel-panic tags, tombstones list, bootreason props.
- DJS — schedule list + per-schedule last-fire/last-result + djs version.
- BREADCRUMBS — the in-memory event ring (daemon flight-recorder is one; AccA user-action ring is the
  other), dumped only into the report.
- MANIFEST — every section: collected / absent (+ why). This is what makes the log honest and
  future-proof: we always know what we DID and DIDN'T get.

Coverage over brevity — collect it ALL. Length does not matter; a debug log exists to debug, so grab
the ENTIRE available buffer of every source, not a small tail: the full logcat crash+main+system rings
(they are finite already), the full pstore, every matching DropBox entry, the whole ACC log set, the
full state + config. On a real device (A3, measured) that is roughly 0.6-5 MB raw and gzips to a few
hundred KB, so "full" is still a small file to share. The MANIFEST records what was grabbed so size is
never a mystery. Only truly unbounded live streams would be time-boxed (there are none here).

## Battery model — the hard rule: zero background, never wakes the phone

The whole thing has NO background component. Spell it out so nobody can ever say "it drains battery":
- No daemon of its own. No polling. No wakelock. No AlarmManager, no JobScheduler, no periodic work.
  Nothing is scheduled, nothing wakes the CPU or the modem. Between reports the collector does not exist
  as a running thing.
- It runs ONLY when the user taps "Collect" (or runs `acc --diag`): a one-shot read that finishes in a
  few seconds and fully exits. That is the entire lifecycle.
- It only READS what the OS and the ACC daemon already produce during normal operation. logcat, pstore,
  DropBox, tombstones, ANR traces, bootreason are Android's own 24/7 outputs — reading them costs the
  same whether we exist or not. ACC's flight-recorder / write-ledger are already written by the daemon's
  loop (rc19 standby work made that near-free); we reuse them and add nothing to the daemon.
- Cross-reboot evidence (a panic wipes our tmpfs) is carried by Android's PERSISTENT stores — pstore,
  DropBox, bootreason — which survive the reboot for free.
- The ONLY thing that is ever resident: a small in-memory breadcrumb ring (~200 entries, a few KB, no
  disk I/O, no wakeups) plus an uncaught-exception handler in AccA. Both idle at effectively zero; the
  crash handler does work only while the app is already crashing. Confirmed on-device: an app crash is
  captured by logcat's crash buffer + DropBox with no help from us, so even the crash handler is a
  belt-and-suspenders, not a requirement.

Net: a user who never opens Diagnostics pays literally nothing. A user who taps it pays a few seconds of
reads, once.

### DECISION: zero-background default + opt-in auto-expiring verbose (decided, with the numbers)

Expected-value analysis (per user, per release, V=100 utils/debuggable report): zero-bg EV = +2.76,
always-on background EV = -4.53. Background buys ~7% more coverage (only the "intermittent + can't-
reproduce + reported late" tail) but pays a battery/trust cost on 100% of users; that extra coverage
reaches ~0.2% of users while the cost hits everyone -- a ~35x-worse trade. Sensitivity: zero-bg wins
across every realistic input; background only wins if intermittent bugs are the majority of reports AND
literally nobody judges a charge-control app on battery (impossible corner).

So the shipped model is a hybrid that dominates both (EV ~ +3.0):
- DEFAULT = zero-background for 100% of users. The collector above, on demand only.
- OPT-IN "verbose capture" = a switch the user flips ONLY while actively reproducing a specific bug.
  It turns on a richer trail for that session and AUTO-EXPIRES after a few hours (a timestamp the
  collector checks; no alarm, no daemon -- expiry is just "ignore the flag if older than N hours").
  Implementation: while armed, the ACC daemon's existing flight-recorder writes at a higher rate / more
  fields, and AccA flushes its breadcrumb ring to disk; both stop the moment the flag expires. Only the
  few chasing the intermittent tail pay, knowingly and briefly. Recovers the missing 7% at ~zero cost.

This resolves the battery question permanently: nobody pays for a capture they didn't ask for.

## Implementation plan

Phase 1 — the collector (ACC module, single source of truth)
- New `install/diag-collect.sh`. Data-driven: a list of {section, command, cap}. Emits the bundle +
  the manifest. Pure read except it may (optionally) run the 15-20s SAMPLE and read DropBox.
- Wire `acc --diag` (a new flag) and `acca --diag` to call it. Retire the scattered exporters
  (`acc -le` stays as an alias; the 4 switch logs collapse to the SWITCH section).
- Ship it inside the module so a CLI-only user has it with zero app dependency.

Phase 2 — AccA front-end
- One "Collect & share diagnostics" button in LogViewerActivity that runs the collector as root and
  hands back the file via FileProvider share. The existing quick-report / 20s-capture / deep-diag /
  export buttons redirect into it (or become options of the one flow).
- Add the two missing pieces: a global uncaught-exception handler (writes a crash section + flushes
  breadcrumbs) and the bounded breadcrumb ring. These are the only genuinely NEW capture paths.

Phase 3 — future-proofing + cleanup
- Schema/collector versioning + the MANIFEST so old logs stay interpretable and gaps are explained.
- Disambiguate the three "selftest" names; document the one canonical switch-verdict log.
- One redaction pass (scope to our package + charging; drop anything that isn't).

Phase 4 — validation (the "sensitivity" proof)
- Run the collector on A3 (Qualcomm) + Pixel (Tensor) and confirm EVERY row of the failure-matrix has
  its evidence present in the bundle (or a manifest line saying why it's absent on that device).
- Size + timing check (must finish in a few seconds, stay under budget).
- Deliberately trigger a crash, an ANR, and a reboot; confirm each is captured from the native sources.

## Open questions to settle before build (the maturity/accuracy pass)
- logcat slice size vs completeness (how many lines is "enough" without bloating).
- Collector lives in the module vs duplicated in the app (module = one source of truth; app-only users
  don't exist, so module wins — but confirm).
- Which DropBox tags exactly (vendor ROMs name them differently).
- Tarball vs single text file for the share target.
- Whether the SAMPLE (the only non-instant part) is opt-in per report or always run.
