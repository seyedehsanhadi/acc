# rc24 — what each fault would have cost a user

The 50 code changes collapse into 14 distinct faults a person could actually notice. Rated 0–10 for
user impact, with the symptom stated as the user would describe it rather than as the code does.

**Read the "seen" column first.** Only three of these were ever observed on real hardware. The rest
were found by reading code and then reproduced in a harness, which is why nobody has complained
about rc23: most of these need a specific charger, a specific kernel, or a specific install path to
show up at all.

| # | What the user would see | Sev | Seen | Cause |
|---|---|---|---|---|
| 1 | **Phone charges slowly after installing ACC.** A 9 V charger drops to ~4.4 V and stays there until you unplug. | **9** | **measured, Mi A3** | Thresholds written in microvolts were unreachable on a millivolt kernel, so a live contract read as unnegotiated and ACC re-ran USB detection on it. |
| 2 | **No charge limit at all, silently.** Phone charges to 100% as if ACC were not installed. Nothing in the UI says anything is wrong. | **9** | **field report** | `service.sh` reported the fork's exit code, not the daemon's, and the `exec` meant nothing could check afterwards. |
| 3 | **Limit stops being enforced part-way through a session.** | **8** | code-read | A `set -e` abort inside the first-install probe or the leak backstop could take the daemon down mid-run. |
| 4 | **Port drops to ~100 mA. Phone charges at a trickle on a good charger.** | **8** | measured, Pixel | Writing `usb/current_max` renegotiates the port down. rc23's ceiling release wrote every `*/current_max` including the negotiation side. |
| 5 | **Phone barely charges after you uninstall ACC.** Blamed on ACC, correctly. | **7** | code-read | The uninstaller wrote the same negotiation supplies on the way out. |
| 6 | **Charging renegotiates every time it resumes from a pause.** Fast charge lost after the first pause. | **7** | code-read | `flip` left set turned the resume check into a switch test, which fired a re-kick after a *successful* resume. |
| 7 | **Plug in, phone does not charge.** Common on phones whose switch is an input cut. | **7** | code-read | The re-arm gated on `online`, which an input cut masks to 0 while the cable is still in. |
| 8 | **Plugged in, "not charging" for five minutes, then it starts.** | **6** | measured, Mi A3 | An unbounded candidate sweep ran as the resume path when no switch was configured. |
| 9 | **Charge limit silently not enforced — battery sails past the limit.** | **6** | code-read | An untried candidate left in the global could be used as the configured switch: a voltage float ceiling instead of a pause. |
| 10 | **Fast charging stops working.** Drops to the main charger's rate. | **6** | code-read | `write()` re-asserted an already-correct value five extra times, re-triggering AICL and the charge-pump state machine. |
| 11 | **Stuck at 500 mA after any current limit is cleared.** | **6** | measured, Mi A3 | The restore replayed a "default" snapshotted from whenever ACC first saw the node — on a laptop port that is 500000. |
| 12 | **A collapsed charger is never repaired** on phones reporting microamps. | **5** | measured, Mi A3 | 5353 µA was read as 5353 mA, so a dead supply looked like five amps and the collapse detector never reached its threshold. |
| 13 | **`acc -t` appears to hang.** Runs for roughly two hours instead of three minutes, printing nothing. | **5** | measured, both | The wait counted loop passes, and a pass costs ~36 s on an unplugged phone. |
| 14a | **The diagnostic accuses a working switch.** The bundle says "switch may be broken" while its own detail section says the limit is active and holding. | **6** | reported, Pixel 4a 5G | The verdict judged the hold from the configured `chargingSwitch`, which a phone with a native firmware limit never writes, and compared a level against the literal string `pcap`. |
| 14b | **The bug report cannot answer the question it was collected for.** | **5** | reported, Pixel 4a 5G | The index advertised a `SYSTEM_LAST_KMSG` event from an abnormal reboot nine minutes before the fault; the body glob could not match that name, so it was never attached. |
| 14 | **`acca` quirks** — "show config" fails in the app; a config value containing `$(…)` is re-expanded. | **4** | code-read | `export "$@"` re-expands, and a glued `-sdcapacity` filter aborted under `set -eu`. |

## How to read the ratings

**9** — defeats the product silently, or costs the user charging they cannot diagnose.
**7–8** — visible, wrong, and would be blamed on ACC.
**5–6** — visible but intermittent, or confined to one class of phone.
**≤4** — annoyance, or affects scripting rather than charging.

## Why rc23 has no complaints despite all of this

Faults 1 and 12 need a kernel whose `power_supply` nodes report a different unit scale from the one
ACC assumed — that is a per-device property, and on a device where the units matched, neither fault
can occur. Fault 2 needs a specific install path. Fault 4 needs the ceiling-release path to run at
all, which needs an unnegotiated plug. Fault 8 needs a phone with no configured switch.

So the honest summary is that rc23 is fine on most phones most of the time, and rc24 closes the
cases where it is not. That is also the argument for shipping rc24 as a staged release rather than
as an urgent fix: nothing here is on fire.

## What rc24 costs in exchange

Almost every change makes ACC do **less** — do not renegotiate, do not write the negotiation side,
fail closed when the supply cannot be proven dead, bound the sweep. The price is a rarer *missed
repair*: a stalled charger that rc23 might have kicked back to life, and rc24 will only answer by
lifting the input current limit.

For a user base reporting no problems, that is the right direction. Nobody is asking for more
aggressive repair; the 9 V → 4.4 V drop was real and reproducible.

## Found during rc24 testing, NOT an rc24 change

| # | What the user sees | /10 | Evidence | Cause |
|---|---|---|---|---|
| P1 | **`maxChargingCurrent` does nothing on a Pixel 6a.** The value is accepted, stored and displayed; no current limit is applied. | **7** | measured, Pixel 6a | ACC never builds `ch-curr-ctrl-files` on this device, and `set_ch_curr` is gated behind `grep -q / $TMPDIR/ch-curr-ctrl-files`, so it is never called. `.mcc-read` is never set either, so the daemon retries the discovery every loop and never succeeds. |

Run standalone against the same phone, the discovery script finds six perfectly good writable
candidates, including `battery/constant_charge_current` at 2410000:

```
battery/constant_charge_current::v000::2410000
dc/current_max::v000::687500
main-charger/current_max::v000::2200000
tcpm-source-psy-i2c-max77759tcpc/current_max::v000::2200000
usb/current_max::v000::2200000
usb/input_current_limit::v::2000
```

So the builder is sound and simply never completes inside the daemon. The most likely reason is the
`[01]` rejection filter in `read-ch-curr-ctrl-files-p2.sh`: it runs "once and while charging only"
because the values would otherwise read zero, and on this device they still read zero at the moment
the gate opens, so every candidate is rejected and nothing is written.

**This is older than rc24.** `read-ch-curr-ctrl-files-p2.sh`, `ctrl-files.sh`, `set-ch-curr.sh` and
the `accd.sh` gate are all byte-identical to `origin/dev` (rc23). rc24 neither causes nor worsens it,
and fixing it is separate work.

The Mi A3 is unaffected: it discovers nine nodes and a 500 mA cap takes the input from 1994 mA to
433 mA and back to 2891 mA on release.
