# rc23 → rc24, change by change, with the evidence for each

Both arms are staged side by side and every case below is executed or matched against **both**
trees. A case is credited only when rc23 answers UNSAFE and rc24 answers SAFE. Three other outcomes
are failures and are named as such:

| outcome | meaning |
|---|---|
| `BOTH-SAFE` | the case passes on rc23 too, so it proves nothing about the fix |
| `BOTH-UNSAFE` | the fix is absent, or does not cover what the case measures |
| `INVERTED` | rc23 is safe and rc24 is not: a regression |

Arms: rc23 = tag `v2025.5.18-6.5.1-rc23` (versionCode 202505331), rc24 = working tree
(versionCode 202505332). Phones: Mi A3 (laurus, Qualcomm SM6125) and Pixel 6a (bluejay, Tensor).

Suites: `suites/accd/t111-rc24-contract-safety.sh` (61 cases), `t112-rekick-decision-scenarios.sh`
(14 scenarios), `t113-rc24-delta-remainder.sh` (16 cases), `suites/rc24-unplugged.sh` (41 live
checks on hardware).

---

## The delta

| # | Area | rc23 | rc24 | Proven by |
|---|---|---|---|---|
| 1 | units | `voltage_now` compared against `6000000` | `_mv()` normalises; thresholds in mV | a 9V bus reads 9000mV whether the kernel reports µV or mV |
| 2 | units | current compared raw | `_ma()` normalises, drops the discharge sign | current normalises to mA and drops the discharge sign |
| 3 | units | input current read from one hardcoded node | `_iin_ma()` walks five candidates | input current is found on whichever node this kernel provides |
| 4 | units | absent reading treated as "not dead" by omission | fails closed | with no readable current node the reader fails closed |
| 5 | units | no single bus reader | `_vbus_mv()` | there is one bus-voltage reader and it returns mV |
| 6 | latch | latch set at ≥ 6.0V | ≥ `hvLatchMv` (6.5V), above any 5V supply's band | the contract latch compares in mV, not raw node units |
| 7 | latch | no per-plug peak recorded | `.hvpeak` records the plug's high-water mark | a plug that ever peaked 9V stays negotiated |
| 8 | latch | only voltage latched a contract | charger **type** (HVDCP/PD/QC) latches too | a high-voltage charger TYPE also latches the contract |
| 9 | latch | a sustained sag **cleared** `.hvcontract` | the sag is logged, the latch is held | a sustained sag does NOT release the contract latch |
| 10 | latch | a collapsed input cleared `.hvcontract` | latch held; the input limit is lifted instead | a collapsed input does NOT release the contract latch |
| 11 | latch | per-plug markers partially cleared on unplug | `.hvpeak` and `.hvkicked` die with the cable too | the per-plug peak marker dies with the cable; the unplug branch clears .hvkicked |
| 12 | policy | each caller invented its own escape from the latch | `_hv_may_kick()`: one gate, six conditions | rekick_usb asks the gate instead of checking the latch itself |
| 13 | policy | — | the gate **claims** the plug's single repair, so the budget is structural | one kick per plug, never two |
| 14 | policy | — | `_hv_lift()` raises input current without re-detecting | there is a lift path that raises current without re-detecting |
| 15 | policy | lift/restore wrote `usb/`, `dc/`, `tcpm*` | allow-list: charger-owned supplies only | the lift touches charger supplies only, never usb/ dc/ tcpm* |
| 16 | policy | raw `echo` bypassed blacklist and ledger | through `write()` | the lift goes through write(), so the blacklist and ledger apply |
| 17 | policy | aim-high fired APSD on its own judgement | aim-high's APSD is behind the same gate | aim-high's APSD is behind the same gate |
| 18 | policy | aim-high wrote every `*/current_max` via a deny-list | allow-list, through `write()` | aim-high writes an allow-list, not every */current_max |
| 19 | policy | rekick ICL restore replayed the recorded default | releases HIGH (5000000) through `write()` | the rekick ICL restore releases high through write() |
| 20 | policy | `_rekick_due` stamped the budget before deciding | `rekick_usb` stamps after it has acted | the re-kick budget is stamped where the kick happens |
| 21 | policy | user's `acc -sk off` bypassed by two callers | honoured inside the gate | the gate honours acc -sk off |
| 22 | aim | aim-high could run while ACC held a pause | yields to `chDisabledByAcc` and to the pause level | a fresh plug during an ACC-held pause does not trigger aim-high |
| 23 | aim | — | and still fires on a genuine fresh plug below the pause | a genuine fresh plug below the pause still reaches aim-high in both builds |
| 24 | warn | collapse warning compared raw `5500000` | `_mv` + `hvPeakMaxMv` | the collapse warning compares mV, not a raw microvolt literal |
| 25 | fastchg | `fast_session()` compared raw `6000000` | `_mv` + `hvLostMv` | the fast-charge session guard compares mV |
| 26 | resume | `flip` left set, so the resume check became a 35-iteration switch test and re-kicked after a **successful** resume | `flip=` cleared first | flip is cleared before the resume-time not_charging |
| 27 | plug edge | one online-derived edge; an input-cut replug was missed | `freshPlug` from `present()` | the plug edge is derived from present(), not online() |
| 28 | plug edge | — | `freshPlugOnline` kept for `native_unlatch` so its window does not narrow | the native path keeps its own online-derived edge |
| 29 | rearm | `generic_rearm` gated on `online()` | gates on `present()` | generic_rearm no longer gates on online(); cable in with online masked to 0 still re-arms charging |
| 30 | sweep | the sweep budget covered the OFF direction only | covers ON too | the sweep budget covers the ON direction too |
| 31 | sweep | `enable_charging`'s fallback sweep was unbounded (>5 min off charge on an A3) | `_rearm_sweep()` with a dynamically scoped ceiling | enable_charging's fallback sweep goes through the bounded helper |
| 32 | sweep | — | the ceiling does not outlive the call, so the exit-trap restore sweep stays unbounded | the ON budget is a local, so the restore sweep stays unbounded |
| 33 | sweep | an unadopted candidate stayed in `$chargingSwitch` | `_swAdopted` clears it | an unadopted candidate is cleared from the global |
| 34 | sweep | `rm $TMPDIR/.testingsw` aborted the caller under `set -e` | `rm -f` | the marker removal cannot abort the caller |
| 35 | write | retry attached to the **verified** branch: 5 extra echoes into a node that had already taken the value | retry attached to the unverified branch | a write that verifies costs one echo, not six |
| 36 | write | the unverified case returned immediately, never retried | spends the budget, re-reading after each attempt | an unverified write spends the retry budget and still reports failure |
| 37 | write | retry never re-read the node | reads back and compares to the target | the retry loop re-reads the node and compares it to the target |
| 38 | restore | `apply_on_plug` default-restore missed `*/input_current_max` | covered | the restore high-lift covers input_current_max |
| 39 | daemon | first-install probe's `disable_charging; enable_charging` could kill the daemon under `set -e` | `|| :` on both | the first-install probe cannot take the daemon with it |
| 40 | daemon | `leak_backstop` captured `not_charging` through a bare `$?` expansion | `if not_charging; then` | leak_backstop reads not_charging without a bare status expansion |
| 41 | acc -t | used `flip=off` to suppress the tie-break, which also forged `working-switches.log` entries | `_acc_nopromo` suppresses without claiming a switch test | acc -t no longer forges working-switches entries with flip=off |
| 42 | acca | `export "$@"` re-expanded and word-split user values | per-key assignment, key charset validated | an acca value containing a command substitution is stored, not executed |
| 43 | acca | `-sdcapacity` (glued filter) exited 1 under `set -eu` | handled | acca accepts a glued -sdcapacity filter |
| 44 | config | `ui_refresh` not printed | printed | ui_refresh is readable back through the config printer |
| 45 | launcher | `exec start-stop-daemon … \|\| exit 12` reported the **fork**, not the daemon | verifies, then falls back and verifies again | service.sh verifies a daemon is really up instead of trusting an exit code |
| 46 | launcher | fallback would inherit busybox ash, which cannot parse `accd.sh` | pins `/system/bin/sh` | the launcher fallback pins /system/bin/sh, not whatever PATH resolves |
| 47 | uninstall | wrote `usb/current_max`, dropping the port to ~100mA | skips the negotiation supplies | uninstall never releases the negotiation supplies |

---

## The scenario replay

`t112` drives the shipped latch/peak block and the shipped gate through time series taken from real
plugs, five repeats each, and fails if the verdicts are not byte-identical across repeats.

| must HOLD (a repair would destroy a working contract) | must KICK (nothing won, supply dead) |
|---|---|
| A3 QC3 negotiation 5.1V → 7.9V, then steady | 5V SDP that goes dead, never negotiated |
| won 7.9V then collapses to 4.7V, cable in — **the 4.4V outage** | dead-on-arrival 5V port |
| HVDCP_3 label at 4.8V delivering 1.2A | peak 5.49V and dead |
| plain 5V SDP delivering 1.7A | dead at exactly 50mA |
| 9V PD steady | — |
| peak 5.51V and dead | 51mA is not dead → hold |

Plus the budget: one kick then silence; unplug/replug earns a fresh repair; a won contract that
dies stays un-kicked until the cable comes out.

---

## Can these suites still fail?

Every suite ends by mutating the rc24 tree to put a defect back and confirming the case flips:

- removing the peak guard makes a 9V plug kickable again — caught
- removing the latch check re-opens a won contract — caught
- putting the unbounded sweep back — caught
- dropping `.hvkicked` from the unplug clear — caught
- a microvolt literal back in the collapse path — caught


---

## Live on hardware, unplugged

`suites/rc24-unplugged.sh` runs against the installed build with no cable attached. It aborts rather
than scoring anything if a supply reads present, if there is no daemon, or if `flight.log` does not
advance inside 180s - a daemon that is present but wedged holds `acc.lock` and shows in `pgrep`, and
three rounds of this project were spent grading a build that was not looping.

Result on both phones: **40 passed, 1 skipped, 0 failed** (Pixel 6a); the Mi A3 run matched.

What it covers that the source-level suites cannot:

- ACC writes nothing at all in 90s with no cable, and the level does not rise
- all seven per-plug contract markers are absent
- the kick gate refuses with `present()` false, and a refused kick does not spend the plug's repair
- `generic_rearm` re-arms with the cable in and `online` masked to 0, and does nothing when genuinely unplugged
- `native_unlatch` writes no firmware node while offline
- the configured switch is left at its ON value, so the next plug charges immediately
- `acc -d` then `acc -e` on an unplugged phone physically releases the node - the rc22 incident, re-run live
- the daemon survives losing its cache, and `service.sh` brings it back and reports honestly

### The one finding this suite produced

`acc -t` on an unplugged phone runs for about 178 seconds, prints one message, and never reaches its
own give-up text. rc24's `ACC_T_WAIT` ceiling counts loop ITERATIONS, and each iteration costs about
35 seconds because `not_charging` walks its full confirmation window - so a ceiling of 20 is reached
after roughly 700 seconds of wall clock, not 20. The command does terminate, which is the rc23 fix
working; the ceiling is advisory rather than real. Recorded as a defect rather than hidden inside a
passing assertion; the suite now measures the elapsed time and reports it.
