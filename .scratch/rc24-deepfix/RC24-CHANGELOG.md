# ACC rc24 — changelog

`v2025.5.18-6.5.1-rc23` (202505331) → `v2025.5.18-6.5.1-rc24` (202505332)
8 files, 475 insertions, 83 deletions. 50 changes.

rc23 is what people are running and nobody has reported a problem with it. Everything below was
found by testing rather than by a user complaint, which is worth saying plainly: these are latent
faults, not a backlog of things users are suffering through.

---

## Charging is never renegotiated any more

The largest group, and the reason rc24 exists. A Mi A3 on a 9 V charger dropped to 4.4 V because ACC
decided the contract was not negotiated and re-ran USB detection on a live supply.

- Bus voltage and current are normalised before comparison. `usb/voltage_now` is microvolts on one
  test phone and millivolts on another from the identical path, so every threshold written in
  microvolts was unreachable on half the fleet.
- The contract bar moved from 6.0 V to **6.5 V**. A QC3 contract under ~2 A load measured
  6433–6712 mV, so 6.0 V sat inside the operating band of a *healthy* supply.
- The highest voltage seen on a plug is recorded. A plug that has been high once is treated as
  negotiated for the rest of that plug, however far it later sags.
- A high-voltage charger **type** (HVDCP / PD / QC) latches a contract on its own, so a labelled
  supply in a low-voltage phase is left alone.
- A sustained sag no longer releases the latch. Neither does a collapsed input. **Only the cable
  coming out clears it.**
- All re-detection now goes through one gate, `_hv_may_kick`, which requires six conditions
  simultaneously and claims the plug's single repair when it says yes. Previously each caller
  invented its own escape, and the escapes were the bug.
- A stalled supply is answered by **lifting the input current limit**, which cannot disturb a
  voltage contract, instead of by re-detecting the charger.
- Input current is read from whichever node the kernel provides, and the node's **unit scale is
  learned** rather than guessed per reading. A collapsed 5353 µA input was being read as 5353 mA —
  five amps — so the collapse detector never fired on a microamp phone.
- With no readable current node the gate fails **closed**. A kick is only ever justified against a
  supply proven dead, and absence of a measurement is not proof.

## Nothing writes the negotiation supplies

- The current-limit lift uses an allow-list of charger-owned supplies. It never writes `usb/`,
  `dc/`, `pc_port/` or `tcpm*`, because one write to `usb/current_max` was measured dropping a port
  to 100 mA.
- The same rule now applies on uninstall, which previously left the phone trickle-charging after ACC
  was removed.
- The re-kick's current restore releases the limit **high** instead of replaying a recorded default.
  That default is a snapshot from whenever ACC first saw the node; taken on a laptop port it is
  500000, and replaying it pinned the phone at 500 mA on a 2 A charger.
- Both paths go through `write()`, so the blacklist and the write ledger apply to them.

## The daemon starts, and stays up

- `service.sh` used `exec start-stop-daemon … || exit 12`. That reports the **fork**, not the
  daemon, and the `exec` replaced the shell so nothing could check afterwards. A field report showed
  it exiting 0 with no daemon and nothing logged. It now verifies the daemon is really up, repairs
  the one cause seen in the field, relaunches without the applet, and verifies again.
- The fallback launcher spells out `/system/bin/sh`. By that point busybox is ahead of `/system/bin`
  on PATH, and busybox ash cannot parse `accd.sh`.
- The first-install probe can no longer take the daemon down with it under `set -e`.
- `leak_backstop` captures `not_charging` through an `if`, not a bare `$?` expansion.

## Pausing and resuming

- `flip` is cleared before the resume-time charge check. Left set, that check became a 35-iteration
  switch test and fired a re-kick **after a successful resume**.
- The plug edge is derived from `present()`, so an input-cut replug re-arms — an input cut masks
  `online` to 0 while the cable is still in. The native path keeps its own online-derived edge,
  because Tensor firmware needs exactly that transition.
- `generic_rearm` gates on `present()` rather than `online()`.
- Aim-high yields while ACC is holding a pause and at or above the pause level, and still fires on a
  genuine fresh plug below it.

## Switch discovery

- The sweep budget covers both directions, not just the off-sweep.
- `enable_charging`'s fallback sweep has a ceiling. Unbounded, an empty switch held a plugged Mi A3
  off charge for over five minutes.
- That ceiling is a local, so mksh's dynamic scoping hands it to one call only — the exit-trap
  restore sweep stays unbounded, which is what lets a stranded phone get its switch back.
- A candidate that was **not** adopted is cleared from the global. Left there, the next cut could
  treat a leftover voltage node as the configured switch: a float ceiling, not a pause.

## The write path

- `write()`'s retry was attached to the branch where the write had already **verified** — five extra
  echoes into a node that had taken the value, which is exactly the re-assertion that re-triggers
  AICL and the charge-pump state machine on fast-charge phones. The case that needed retrying
  returned immediately instead.
- The retry now re-reads the node and compares it to the target after every attempt.

## CLI and config

- `acc -t`'s wait ceiling reads the clock. It counted loop passes, and a pass costs about 36 seconds
  on an unplugged phone, so the 180 default meant closer to two hours than three minutes and the
  progress line was wrong by the same factor.
- `acc -t` hands its lock over before restarting the daemon. It wrote its own pid into `acc.lock`,
  and the daemon it started then released the lock by killing that pid — itself. It reported 143
  (SIGTERM) after doing its whole job correctly.
- `acc -t` suppresses the kernel-status tie-break with a dedicated flag instead of `flip=off`, which
  also meant "record this candidate", so an interrupted wait left forged picker entries behind.
- `acca` assigns config values without `export`, so a value is taken literally — no re-expansion, no
  word splitting, and only a real config key can be written.
- `acca` accepts a glued `-sdcapacity` filter, which previously exited 1 under `set -eu`.
- `ui_refresh` is readable back through the config printer.
- `apply_on_plug`'s default restore covers `*/input_current_max`.

### Diagnostics (from a Pixel 4a 5G field report)

- The diagnostic verdict no longer calls a working firmware limit a broken switch. On a phone with a
  native limit the daemon drives `charge_stop_level` and never touches the configured
  `chargingSwitch`, so judging the hold from that switch read as "switch may be broken" while the
  same bundle's detail section said the limit was active and holding. The verdict now consults the
  native limit first, and resolves the `pcap`/`rcap` keywords instead of comparing a level against
  the literal string `pcap`.
- The collector can now carry the kernel log its own index advertises. Android drains
  `/sys/fs/pstore` into DropBox as `SYSTEM_LAST_KMSG`, so after an abnormal reboot the pstore tier
  finds an empty directory and the body sits in DropBox — which the body glob
  (`crash|anr|panic|tombstone`) could never match. Bundles listed a `SYSTEM_LAST_KMSG` event and
  shipped without it. Kernel bodies are now collected on their own budget, so a burst of ANRs cannot
  crowd out the decisive file, and they are collected in the reboot tier rather than under `--full`:
  the pstore they stand in for was never gated on the mode, so gating the substitute meant a normal
  bundle from a phone that had just rebooted abnormally carried no kernel log at all.
- The reboot note counts what landed instead of asserting it. It claimed "attached full dmesg + all
  pstore variants + last_kmsg" regardless of what was actually attached, the same defect this file
  had already fixed one tier down for `/proc/last_kmsg`.
- The redactor no longer eats DropBox filenames. `data_app_anr@1786997280406.txt.gz` satisfied the
  address pattern, so manifest lines came back as `dropbox-body -> [EMAIL]` and named nothing. The
  domain must now begin with a letter, which costs redaction of the rare digit-leading domain
  (`foo@1and1.com`) and buys back every filename.
- A zero-byte artifact is never announced as collected. DropBox leaves an empty `.lost` placeholder
  where it has purged a body, and `/data/anr` keeps empty traces; both were reported as `OK` with a
  filename behind them. The crash tier now copies through `cpf`, the one helper that reports what
  landed rather than what was attempted, so an empty source reads `EMPTY` and says why. The
  tombstone tally counts files that landed.

---

## Verification

| | Mi A3 (SM6125) | Pixel 6a (Tensor) |
|---|---|---|
| accd suites | 77/77 | 77/77 |
| live unplugged | 39/39 | 39/39 |
| live plugged | 22/22 | 23/23 |
| driven coverage | 22/22 | 22/22 |
| thermal (plugged) | 17/17 | 18/18 |

49 of the 50 changes are executed against the shipped code. The one exception is the uninstall
change, matched by source only, because running it would remove ACC from the phone.

The dual-arm suites (`t111`, `t112`, `t113`, `t117`, `t118`) run every case against **both** rc23
and rc24 and score a case that passes on rc23 as a failure, so a "fix" that changes nothing cannot
be credited.
