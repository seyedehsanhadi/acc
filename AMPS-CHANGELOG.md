# AMPS - Adaptive Multi-device Probe & Selector

Charge-switch finder shipped inside ACC (`acc-compat.sh`, identical to `amps.sh`) and bundled in AccA as "Find my switch". Its version line is its own; it does not follow ACC's or AccA's.

## v7.3.3

Folds v7.3.2 into the version bundled with ACC rc25 and AccA 2.0.1-rc24. Changes below are since v7.3.1.

Fixed
- Motorola MediaTek phones: the on/off current flag is recognised, written as 0 or 1, and released after an interrupted scan instead of staying latched.
- Firmware-owned nodes (thermal throttle, live charge-current vote) are reported and left alone instead of written.
- Charger re-detection runs only on a supply that is really dead, so a working fast-charge contract is never dropped.
- Phones that report battery current in mA and control nodes in uA (OnePlus 7 Pro, OnePlus 8 Pro) no longer fail the baseline. Battery and input current are read on separate, verified scales.
- A failed or malformed current read no longer counts as a hold or as charging recovered.
- A failed baseline asks you to check the charger and settings instead of blaming the charger's negotiation.

Added
- Every restore is logged to `amps-restore.log` with its reason.
- `AMPS_CURRENT_UNIT` and `AMPS_INPUT_UNIT` overrides for drivers whose units are known.

Changed
- Right after a restore, AMPS says the charging result is not in yet instead of reporting a failure.

## v7.3.1

Everything since v7.2.4, the version published with ACC rc23. Folded into one release.

Added
- Native `%`-limit finalists are functionally cycled instead of being confirmed on the engage reading alone: baseline first, then the start/stop pair, pause confirmed on the current anchor, a hold re-checked for leaks, the limit cleared and charging required back within 30 s, twice.
- Finalists are pause/resume cycled after the hammer, not only hammered.
- Verdicts that mean "could not measure" are separate from verdicts that mean "failed". `INCONCLUSIVE` and `NO-BASELINE` leave a finalist alone; `NO-PAUSE`, `LEAK`, `RESUME-FAIL`, `CYCLE-NO-PAUSE`, `CYCLE-RESUME-FAIL`, `WRITE-REJECTED` and `RESTORE-FAIL` discard it and re-pick.
- A finalist that was never verified downgrades the recommendation to needs-test.
- Multi-node picks are stressed as a group, written, held and restored together.
- A discarded finalist is removed from every candidate list and the next-best is promoted.
- Thermal-level nodes are discarded before the hammer runs, not after a cool run reads clean.
- Every copy of the engine prints a content id beside its version, so a stale copy cannot hide behind a truthful `V=` line.
- `--blacklist` remove exits 1 when the danger list cannot be rewritten, instead of printing success.

Fixed
- A probe-collapsed `0` was recorded as a current-limit node's original value, so a restore replayed `0` and left the port taking no input current with nothing reporting a fault.
- The charger-recovery path wrote `0` to a node it had never snapshotted.
- Charger speed was reported off a port the probes had left capped; the scan restores through `icl_repair` first.
- A battery-current sample above the charge IC's ceiling was blamed on the cable instead of being called stale, and it also wrongly flagged the input sample.
- The collapsed-contract verdict claimed "runs at 9V or more" for every port type; it is HVDCP-only.
- An unknown resume state read as `ok`, and a `STUCK` could be masked by a later `OK`.
- A discarded finalist survived in `CFG_LEVEL` and in the on-disk registry, so the same node could be recommended again.
- Picking the next-best finalist could return an empty entry.
- The group path rejected values containing a separator, skipped relative node names and could record an empty original.
- A `THROTTLE` hold ran a resume check that does not apply to it.
- Charger detection ignored a `usb` parent.
- The voltage-cap probe is gone: writing `battery/voltage_max` is not reversible enough to be a candidate.
- Resume-check labels name the group and node count they came from.

Changed
- Deny lists widened: `charging_policy`, `/maxfg/`, `dp_dm`, `apsd`, `hvdcp`, `pe_start`, `pairing`, `connector_type`, `adapter_cc`, `_state$`, `_status$`, `_type$`, `_reason$`, `force_.*update`, `_update_ops`, `first_usage`, `usage_date`, `comp_clamp`, `toggle_stat`.
- Comments stripped from the shipped script: 3943 lines to 3610, while code lines went up from 3384 to 3474.

Validated on Mi A3 and Pixel 6a at 5 V plus focused Pixel native-limit cycles at 9 V; self-test 175/175 on both, and deep scans on both reproduce their expected verdicts.

## v7.2.4 and earlier

Folded into the ACC release notes in `changelog.md`.
