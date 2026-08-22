# What the firmware-limit branch swallows

`accd.sh:1369` — `if $nativeLimit; then … continue`. The branch exits the loop before
`is_charging()` is ever called, so anything living inside `is_charging()` is skipped on every phone
with a firmware charge limit. `nativeLimit` is true whenever `google,charger/charge_stop_level`
exists and the user has not dropped `.no-native-limit`.

The file already records four features found and restored one at a time. This audit walks the whole
loop and settles every remaining one.

| feature | before | now | why |
|---|---|---|---|
| allowIdleAbovePcap | lost | restored (rc21) | Pixel 3a report |
| idleApps | lost | restored (rc22c) | "did nothing whatsoever on a phone with a native limit" |
| mask_capacity | lost | restored (rc23c) | Pixel 9a, "did nothing at all, silently" |
| auto_shutdown | lost | restored (rc23c) | the branch "has never reached" it |
| **maxChargingCurrent** | **lost** | **restored** | two Pixels measured inert; see below |
| **maxChargingVoltage** | **lost** | **restored** | same branch, same cause |
| **cooldownCurrent / cooldownRatio** | **lost** | **declared unavailable** | works by cycling charge against a limit the firmware is holding |
| **forceOff** | **lost** | **declared unavailable** | drives `flip_sw`, and this branch refuses the generic switch logic on purpose |
| resetBattStats | lost | left alone | cosmetic; restoring it needs the plug-edge state that lives in `is_charging()`, poor risk for the benefit |
| temperature | fine | fine | `sync_native_limit` enforces max_temp with its own hysteresis |
| capacity levels | fine | fine | `sync_native_limit` writes them into the firmware |
| generic switch logic | skipped | skipped | deliberate: every candidate costs a 35-iteration verification and none of them hold here |

## Evidence for the two restored ones

| device | SoC | nativeLimit | mcc before |
|---|---|---|---|
| Pixel 6a (bluejay) | Tensor gs101 | true | inert — 500 mA cap, pack stayed at 1.9 A, no node written |
| Pixel 4a 5G (bramble) | SM7250 | true | inert — `maxChargingCurrent=(925)` never expanded; ledger holds 22 voltage writes, 0 current |
| Mi A3 (laurus) | SM6125 | false | works — 1994 mA to 433 mA, back to 2891 mA on release |

200 s of live daemon trace on the Pixel, charging at +3.06 A with the cap set: `is_charging` appears
zero times, and there is no `set +x` anywhere in that region, so it genuinely never ran.

## The fix

The two limits are applied inside the branch, above its exits, exactly as `idle_apps_check` and
`mask_capacity` were. Discovery is gated on `present()` and a `Charging` status, because
`read-ch-curr-ctrl-files-p2.sh` records each node's default and off-charge most of them read zero —
recording that would cap the phone at zero for the session.

Cool-down and force-off are NOT implemented here. Both need a charging switch this hardware does not
honour, and faking one would fight the firmware. They warn once per day instead. The temperature
limit still pauses and resumes normally, so nothing is left unprotected.

`is_charging()` keeps owning both limits for every phone without a firmware limit, so the Mi A3's
path is byte-for-byte unchanged.

## Live result, and the blocker it exposed

Plugged, Pixel 6a, cap 500 mA:

| | before the fix | after |
|---|---|---|
| `.mcc-read` / `ch-curr-ctrl-files` | absent / absent | SET / 6 nodes |
| config | `maxChargingCurrent=(500)` | expanded with node entries |
| `usb/current_max` | 2200000 | **500000** |
| `main-charger/current_max` | 5000000 | **500000** |
| pack current | ~2.5 A | ~0.8 A |

500 mA of input at 9 V is about 4.5 W, which at a 4 V pack is roughly 1.1 A minus system load. The
cap is physically effective, not just recorded.

**The interaction that worried me is clean.** With the cap active, the firmware limit still paused:
`charge_stop_level=37`, `charge_start_level=35`, and at level 37 the phone went `Not charging` at
13 mA. Applying a current cap alongside the firmware limit does not stop it holding.

### BLOCKER: clearing a cap does not release it

`acc -s maxChargingCurrent=` leaves the nodes pinned and the config malformed -- the scalar is
dropped while the node entries survive:

    maxChargingCurrent=( battery/constant_charge_current::500000::3450000 ... )

**Measured on BOTH phones**, including the Mi A3, which has `nativeLimit=false` and therefore never
executes any of the new code. So this is pre-existing and general, not a regression from this change.

It is still a blocker for shipping this change, and the reason is the direction of harm. Before, a
Pixel user's current limit did nothing at all, which is harmless. After, it applies correctly and
then cannot be cleared -- the phone stays at 500 mA with a UI reporting no limit, recoverable only
by editing config and restarting the daemon. Fixing the apply without the release makes Pixels worse
than leaving them alone.

**Do not ship the native-branch fix until the clear path is fixed.** They belong in the same release.

## The blocker, root-caused

It is a shell-semantics bug, and it is device-independent.

In mksh, assigning a scalar to an array NAME writes element 0 and leaves the rest alive:

    maxChargingCurrent=(500 usb/current_max::500000::2200000 main/current_max::500000::2000000)
    export maxChargingCurrent=
    -> count is STILL 3, [0] is empty, [1..2] untouched

`set-prop.sh` clears a config key with `export "$@"`, so `acc -s maxChargingCurrent=` dropped the
user's value and kept every derived node entry. write-config then published

    maxChargingCurrent=( usb/current_max::500000::2200000 main/current_max::500000::2000000)

and `apply_on_plug` iterates `${maxChargingCurrent[@]}`, not `[0]` — so the survivors were re-applied
on every loop. The cap could not be cleared by any means short of editing the config by hand.

Reproduced identically on a Tensor Pixel 6a and a Snapdragon Mi A3, because it is a property of the
shell rather than of any charger driver. It is also the mechanism behind the Mi A3 that sat at a
3.9 V float on a 4.4 V pack after its `maxChargingVoltage` was "cleared".

### Two fixes, because there are two populations

**New corruption** — `set-prop.sh` now clears the whole array after the export, for both keys and
all their aliases. Ordering matters: clearing before the export leaves a stray empty element
(count 1); after, the array is genuinely empty (count 0). Measured both ways before choosing.

**Configs already corrupted by an older build** — fixing set-prop cannot repair what is on disk, and
an upgrading user carries a key that would keep being re-applied. `write-config.sh` now drops these
keys when the first token is not a number. The check is on the FIRST TOKEN, not on a leading space:
re-reading `( usb/current_max::... )` from disk gives an array whose element 0 IS that entry, because
the space is only whitespace to the parser. A wrong space-based guard was written first and the test
caught it.

Live on both phones, unplugged: set 500 -> `(500)`, clear -> `()`; set 4000 mV -> `(4000)`,
clear -> `()`; and a planted `maxChargingCurrent=( usb/current_max::500000::2200000)` healed to `()`
on the next config write.

t122 grades all of it dual-armed, including the shell fact it rests on, and is mutation-checked.
