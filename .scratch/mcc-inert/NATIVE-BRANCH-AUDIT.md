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
