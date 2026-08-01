# Diagnostic bundle: the definitive scope

What to keep, drop, and tag, decided from evidence: real-device profiling, cross-condition cycle
tests, four web-research passes, and what the ACC maintainer actually asks users for in issue
threads. Scope is locked to three domains: **charging, reboot/boot, root management.** Privacy first.

## Method

- **Profiled** a live `acc --diag` bundle on the Mi A3 (Android 10, Qualcomm): per-source bytes,
  signal density, unique-line ratio, compressibility.
- **Cycle-tested** conditions on the A3 and measured which sources actually carry the evidence:
  - app crash (`am crash`): logcat-crash +1, DropBox +1, app last-crash fresh; tombstone NOT touched
    (proves tombstones are native-only).
  - real reboot (`adb reboot`): the boot-time archiver fired (reboot-history 1->2), captured the
    previous boot's shutdown line + ACC pre-boot state; daemon auto-started; detector classified the
    normal reboot as core-only.
- **Researched** (four parallel passes): charging debug at the kernel/PMIC level; reboot/panic
  evidence and its volatility; Android 10-15 source variance; and the ACC/AccA maintainer's real
  debugging asks (grounded in VR-25/acc issues #148/#197/#267/#307 and AccA #204/#207).
- **Probed** the A3 for research-flagged sources we do not yet collect, and measured their size.

## The tags

- **CORE** - always collected. Small, high signal, decisive for the majority of reports.
- **CONDITIONAL** - auto-attached only when a cheap on-device signal fires (fresh crash or abnormal
  reboot). Big and rarely relevant, but decisive for exactly the case that triggers it.
- **EXTRA** - `--full` only. Large, rarely decisive.
- **ADD** - high value, currently missing; found via research + device probe. Costs ~1 KB total.
- **DROP** - never worth its size.

## Condition -> the sources that actually decide it

| Report class | detected by | decisive sources | where they live |
|---|---|---|---|
| charge won't stop/start at limit | (always suspect) | config, acc -s (enforced switch), acc -i, battery nodes, pmic-votable, flight/write log | CORE |
| overcharge / undercharge / wear | (always) | voltage_now vs constant_charge_voltage_max, charge_full vs design, charge_counter, flight | CORE |
| switch not found / not controlled | (always) | acc -t results, charging-switches.txt, acc-p.txt, power_supply-*.log | CORE (ADD) |
| app crash / stuck / won't open | fresh last-crash / DropBox crash | logcat-crash, acca-last-crash, breadcrumbs, DropBox index | CORE |
| native (C/C++) crash | fresh tombstone mtime | tombstones, DropBox native_crash | CONDITIONAL |
| daemon won't start / not running | (always suspect) | init.log, install.log, accd-trace, state.json, selftest | CORE (tails) |
| reboot / bootloop after flash | abnormal bootreason OR pstore panic-density | reboot-history (persistent), bootreason set, pon/poff, pstore, write.log, full dmesg | CORE (reboot-history) + CONDITIONAL (raw) |
| standby drain | (always) | doze-power, flight, enforced-switch idle capability, thermal | CORE |
| thermal throttle/shutdown | thermal in bootreason / high temp | thermal, dmesg thermal lines, pmic FCC thermal voter | CORE (filtered) + CONDITIONAL |

Key measured finding: **the common report classes are decided by small sources.** An app crash needs
2 KB (logcat-crash + last-crash), not the 39 KB full logcat. A charge bug needs config + acc -i +
pmic-votable (~3 KB), not 800 KB of dmesg. The heavy raw logs matter only for native crashes and
abnormal reboots, and both announce themselves with a cheap signal.

## Master source table

Sizes are compressed, measured on the A3. "Privacy" flags anything needing redaction.

| Source | tag | when | comp | privacy | why (evidence) |
|---|---|---|---|---|---|
| _SUMMARY / _MANIFEST | CORE | always | 2 KB | clean | triage top-sheet; decides where to look |
| config (full+active) | CORE | always | 9 KB | clean | the limiter's intent; maintainer ask #2 |
| acc -i snapshot | CORE ADD | always | <1 KB | clean | maintainer's #1 live-state ask (#307); STATUS/CURRENT_NOW/INPUT_SUSPEND |
| battery + power_supply (full nodes) | CORE ADD | always | 1 KB | clean | health/charge_type/charge_control_limit/charge_counter/charge_full; A1 essential |
| pmic-votable (charge votables) | CORE ADD | always (Qualcomm) | 1 KB | clean | "THE won't-charge tool" - min-wins voters; A1 essential |
| flight.log | CORE | always | 6 KB | clean | 100% unique charge decisions |
| write.log (panic-write ledger) | CORE | always | <1 KB | clean | acc's own reboot-cause record; maintainer #7 |
| charging-switches / acc-p / working switches | CORE ADD | always | 1 KB | clean | the ~50-switch DB result; switch-not-found #3 |
| state.json | CORE | always | <1 KB | clean | daemon snapshot |
| reboot-history (persistent) | CORE | always | 4 KB | clean | the reliable reboot record; archiver-proven |
| bootreason set + pon/poff | CORE ADD | always | <1 KB | clean | canonical + raw + PMIC latch; A2 essential |
| init / install / accd-trace | CORE | tails | 12 KB | clean | daemon-start evidence; 33-67% is repetition |
| thermal / doze-power | CORE | always | 2 KB | clean | drain + throttle |
| logcat-crash | CORE | always | <1 KB | low | app FATAL stack; separate buffer |
| acca-last-crash / breadcrumbs | CORE | always | <1 KB | clean | app crash + event trail |
| modules list + root method + busybox | CORE ADD | always | <1 KB | clean | maintainer #4/#5 - what else is installed |
| amps / env / djs(trim) | CORE | always | 2 KB | clean | switch engine, environment |
| dmesg (charge/thermal/panic filter) | CORE | always | 21 KB | low | 77% noise dropped; all 878 charge lines kept |
| logcat main+system (our pkg + errors) | CORE | always | 13 KB | med | 70% other-app noise dropped (size AND privacy) |
| avc-denials (our SELinux context) | CORE | always | 1 KB | clean | 93% other-app noise dropped |
| getprop (curated ~25 keys) | CORE | always | 3 KB | med | 70% irrelevant; serial redacted |
| pstore-console (full) | CONDITIONAL | abnormal reboot | +28 KB | low | 1% signal on clean boot; the panic when it matters |
| last_kmsg | DROP->60-line tail | reboot | 2 KB | low | 99% identical to pstore (measured) |
| pstore variants (dmesg/pmsg-ramoops) | CONDITIONAL | if present | var | low | grab all /sys/fs/pstore/* on reboot |
| full dmesg (unfiltered) | CONDITIONAL/EXTRA | abnormal reboot / --full | +40 KB | low | kernel context for a real panic |
| full logcat | CONDITIONAL/EXTRA | fresh crash / --full | +26 KB | med | surrounding context for a crash |
| tombstones | CONDITIONAL | fresh native crash | +15 KB | low | native crash dump; not for Java crashes (measured) |
| anr | CONDITIONAL | fresh ANR | +8 KB | low | app hang threads |
| power_supply-*.log (raw mining dump) | EXTRA | --full | var | clean | switch candidate mining; big |
| DropBox entry bodies | DROP | - | 0 | - | "(contents lost)" on A3; index kept |
| dropbox .lost empties | DROP | - | 0 | - | zero-byte bodies |
| full getprop | EXTRA | --full | 12 KB | med | curated subset covers 95% |
| full avc (all apps) | EXTRA | --full | 7 KB | low | our-context covers our bugs |

## What to ADD (the gaps), validated on the A3 at ~1 KB total

pmic-votable (1567 B), fuller power_supply nodes (711 B), acc -i, write.log, charging-switches /
acc-p, PON/POFF reason (conditional - absent on A3, present on many Qualcomm), all `/sys/fs/pstore/*`
variants, installed-modules list (97 B), root method + busybox presence. Every one maps to a real
maintainer ask or a kernel/PMIC essential, and the lot compresses to 827 bytes.

## Privacy model

Collect only what the three domains need; mask the rest.

- **Never collected:** contacts, messages, accounts, location, installed-app inventory beyond root
  modules, SSIDs, browsing, keystore contents, file listings of user storage.
- **Redacted (implemented):** device serial (bracket rule + literal scrub), MAC, email, IMEI/IMSI/
  ICCID/MEID/android_id.
- **Filtered logcat is a privacy win as well as a size win:** dropping the 70% of logcat that is other
  apps removes exactly where third-party PII would appear. Same for avc (93% other apps).
- **getprop curated** to ~25 device/charge/boot keys, so radio/telephony/account props never ship.

## Cross-Android and cross-vendor portability (10-15, Qualcomm/MediaTek/Samsung/Tensor)

The collector must not assume the A3's layout. Rules from the version research:

- **No `logcat -b kernel` on any version** (10-15); kernel logs come only from dmesg/pstore. We never
  use it, so nothing to change.
- **pstore is not guaranteed.** It needs a vendor kernel with `CONFIG_PSTORE_RAM`. Probe
  `/sys/fs/pstore/*`; fall back to MediaTek (`/sdcard/mtklog/aee_exp`, `expdb`) and Samsung
  (`sec_debug`) vendor mechanisms; accept that some devices offer neither. Grab ALL pstore variants
  (console/dmesg/pmsg-ramoops), not just console.
- **`/proc/last_kmsg` has been gone since ~Android 6.** Keep it as a harmless if-present grab, never a
  primary source.
- **Tombstones gain a protobuf `.pb` sibling from Android 11.** Grab it as raw bytes and decode
  off-device; the schema is not wire-stable across releases, so never parse on-device.
- **ANR files:** glob both `/data/anr/anr_*` (A11+) and legacy `/data/anr/traces.txt`.
- **bootreason:** read `ro.boot.bootreason` and `sys.boot.reason`, expect them to disagree, prefer
  `sys.boot.reason` once `sys.boot_completed=1` (it is the canonical value; `ro.boot.bootreason` is the
  raw PON latch, which is why the A3 shows `hard-reset` there but `reboot,adb` in `sys.boot.reason`).
- **DropBox "(contents lost)" is normal**, not a bug (3-day / quota rotation). Keep the index as a
  signal; poll bodies promptly after the event. Android 15's `READ_DROPBOX_DATA` gates only the app
  API, not the root `dumpsys dropbox` path, so no permission logic is needed.
- **Output path:** write to `/data/local/tmp` first (root-writable at any boot stage, not FUSE/scoped),
  mirror to `/sdcard/Download` only after a write-and-read-back probe. The boot-time archiver already
  writes to `/data` (persistent), so it survives an unmounted `/sdcard` early in boot.
- **App CE data** (`/data/data/<pkg>`) is unreadable before first unlock (FBE, all of 10-15); the app
  breadcrumbs/last-crash may be missing on a locked-device collect - expected, not a bug.
- **power_supply discovery:** enumerate `/sys/class/power_supply/*` and read each `*/type`; never
  hardcode `battery`/`usb`/`ac` (the set varies by OEM even on the same Android release). Sanity-check
  `current_now`/`voltage_now` magnitude; some drivers report mA in a µA-named node.
- **avc:** absence of a denial is not proof nothing was blocked (the `dontaudit` list grows every
  release). Best-effort passive read is the ceiling without injecting a live `auditallow`.

## Net result

| | now | scoped + tiered |
|---|---|---|
| common report | 285 KB | **~90 KB** |
| charging/reboot signal | partial | **more** (pmic-votable, acc -i, fuller nodes, pon/poff, write.log) |
| privacy exposure | full logcat/getprop/avc | **filtered to our domains** |
| debuggability | ~1.0 | ~1.0, and closer to first-log-solves-it (maintainer asks pre-answered) |

## Recommendation

Ship the scoped + tiered collector: CORE always (~90 KB, now including the ~1 KB of charging/reboot
sources maintainers actually ask for), CONDITIONAL heavy auto-attached on a detected crash/reboot,
EXTRA behind `--full`, and the filters doubling as the privacy boundary. It is smaller, more
relevant, and more private than the current bundle, and it pre-answers the maintainer's first three
questions so a user's single log is more likely to solve their problem on the first round.
