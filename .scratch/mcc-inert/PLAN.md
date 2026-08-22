# maxChargingCurrent is silently inert on Pixels

Status: open. Not an rc24 change; rc23 behaves identically.

## Symptom

A user sets a charging-current limit. ACC stores it, `acc -i` and AccA display it, and no node is
ever written. ACC's own source already names this shape, in `accd.sh` beside the `.mcc-custom`
rebuild: *"the cap was configured, displayed as active, and enforced nowhere."*

## Who is affected

| device | SoC | chargingSwitch | mcc | mcv |
|---|---|---|---|---|
| Pixel 4a 5G (bramble) | SM7250 | native `charge_stop_level` | **inert** | works (22 ledger writes) |
| Pixel 6a (bluejay) | Tensor gs101 | native `charge_stop_level` | **inert** | unsupported (no battery float node) |
| Mi A3 (laurus) | SM6125 | `battery/input_suspend` | works | works |

bramble is a real user's phone, from the diagnostic bundle: `maxChargingCurrent=(925)` never expanded
to node entries, and its write-ledger holds 22 voltage writes and **zero** current writes. He has
been running a 925 mA limit that has never done anything.

Two different chipsets, so this is not one phone's quirk. The strongest correlation is the switch
class: both affected phones drive the native firmware limit, the unaffected one drives an input cut.
That is a correlation across three devices, not a proven cause.

**Severity: 7/10 for deception, 0/10 for danger.** Nothing overcharges — the pause and the native
level limit still work, verified across a full plugged suite on both phones. The harm is that ACC
reports a limit it is not enforcing.

## Ruled out, with evidence

| hypothesis | how it died |
|---|---|
| Wrong cwd in the daemon | `/proc/<pid>/cwd` reads `/sys/class/power_supply` on both phones |
| Polarity arbitration mis-reading charge direction | t119: 8/8 on both arms with the Pixel's exact flip pattern |
| The sign-flip heuristic deciding unchallenged | the kernel tie-break promotes it back; t119 case 1 |
| Discovery never runs | built `ch-curr-ctrl-files` (6 nodes) by hand + `.mcc-read`, restarted the daemon: still inert |
| The apply path is broken | t120: 6/6 on both phones, both arms — given an expanded config it writes every node |
| `.mcc-custom` guard blocking | present on the Pixel, which DISABLES the skip; absent on the working A3 |
| `.mccrej-*` backoff | no reject files exist on the Pixel |

## What is left

The config is never **expanded**. A working cap looks like

    maxChargingCurrent=(500 usb/current_max::500000::2000000 battery/constant_charge_current::500000::3000000)

and on the Pixel it stays `maxChargingCurrent=(500)`. Expansion happens in `apply_current` inside
`set-ch-curr.sh`, which the daemon calls from the `if $isCharging` branch in `accd.sh`. Both phones
leave it unexpanded when set from the CLI while unplugged, so the CLI is not the path that expands
it — the daemon is, and only while charging.

So the remaining question is narrow: **does the Pixel's daemon ever execute that branch while
charging, and if it does, what does `set_ch_curr` do there?**

## Next experiment

Plugged, on the Pixel, with a cap configured. Instrument the branch itself rather than infer it:
log entry to `if $isCharging`, the value of `maxChargingCurrent[0]`, the result of
`grep -q / ch-curr-ctrl-files`, and the return of `set_ch_curr`. One charging session answers it.

If the branch is never entered, the fault is in `is_charging` on this device and the fix belongs
there. If it is entered and `set_ch_curr` returns without expanding, the fault is in `apply_current`
and the fix is local and testable with t120 already in place.

## Recommendation

Ship rc24 without this. It fails safe, it is byte-identical to rc23, and the code around it records
three previous failed attempts at marker-race fixes. Fix it in its own cycle, test-first, on both
phones.

A cheap interim honesty fix, if wanted before the cause is known: after applying a cap, verify at
least one node actually changed and report the limit as unsupported when none did. That is detection
by measurement rather than by theory, and it cannot make charging worse because it only changes what
is reported.
