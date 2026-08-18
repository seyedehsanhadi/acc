# rc24 Spec — the verified rc23 defect set

Authority for `.scratch/rc24-deepfix/PLAN.md`. Every claim below was checked against the live
tree at `install/`, and the ones marked *device* were reproduced on hardware: laurus (Mi A3,
Magisk, `192.168.137.79`) and bluejay (Pixel 6a, KernelSU, `192.168.137.18`), both on
rc23 `versionCode=202505331`.

## Binding requirements

1. A fix is accepted only when a suite case fails on the staged rc23 arm and passes on rc24, on
   both phones. A suite that passes on rc23 proves nothing.
2. No fix may add measurable idle cost. The gate is P3's arm comparison, not judgement.
3. No fix may introduce a new background job, daemon, poll, or global-scoped budget.
4. Every new sysfs write goes through `write()`, or carries an adjacent `sw_blacklisted` check and
   a comment saying why it cannot.
5. Offline charging (phone off, cable in, battery icon) must never be cut or powered off.
6. `shutdown_temp` is never written by any test.
7. Commits and comments carry no engine names and no co-author trailers.

## Confirmed defects

| B | Site | Defect | Proof |
|---|---|---|---|
| B1 | `accd.sh:966`, `:2436` | `freshPlug` is derived from `online`; `generic_rearm` then re-requires `online`. Input-cut switches mask `online` to 0 with the cable in, so the function can never fire for the switches it exists for | source; matches the reported Motorola/Qualcomm symptom |
| B2 | `accd.sh:1249-1259`, `:1229` | Aim-high writes `*/current_max` with a raw echo, excluding only battery/gauge, so `usb/`, `dc/` and `tcpm-*` are written; runs before the pause with no `chDisabledByAcc` or level gate, and holds the loop up to 17s | source; `accd.sh:2815-2818` records `usb/current_max` dropping a port to 100 mA |
| B3 | `misc-functions.sh:323`, `accd.sh:3115` | The sweep deadline applies to `off` only, so the ON walk is unbounded; the boot re-enable has no level or temperature guard | source; five-minute stall measured on laurus |
| B4 | `acc.sh:955,957`, `batt-interface.sh:154-177` | The gate deciding whether to wait is bare `not_charging` while only the loop sets `flip=off`; and `flip=off` makes `not_charging` append to `working-switches.log` | source; Mi A3 signature |
| B5 | `acc-compat.sh:1710-1712` | On a strong charger one sample above `NEAR` forces `held=0` and returns | source |
| B6 | `misc-functions.sh:833-837`, `accd.sh:1052` | `.hvcontract` is an unconditional return, so a collapsed contract cannot be repaired; the collapse detector requires `online` and `! chDisabledByAcc`, which an input-cut pause reproduces | source; laurus collapse incident |
| B7 | `accd.sh:2214`, `:2044-2048`, `:2850` | The backstop restores its own input cut because it gates on `! online`; `_ntHot` is in-memory only | source. **`usb/input_current_max` is absent on BOTH test phones**, so the function returns at its second line here and the defect is only observable through `NVB_NODE`/`NVB_CC` against a fabricated tree |
| B8 | `misc-functions.sh:1435-1442` | After the readback verifies the write, `write()` issues `$seq` (5) more echos; the retry-loop failure path returns `1`, ignoring the best-effort `$3` | source; contradicts the rc14 idempotency gate 40 lines above |
| B9 | `accd.sh:1451` | `xIdle` is decided from a `_status` set before the cut, inside the `is_charging` branch, and the cut runs in a subshell — so it can never be true and the re-idle at `:1753` is dead | source; shipped default is `allowIdleAbovePcap=false` |
| B10 | `post-fs-data.sh:87` | `[ -f "$1" ]` is the `while` condition, so the first absent triplet ends the whole group | source |
| B11 | `uninstall.sh:234-236` | The release sweep writes every `*/current_max`, including `usb/` | source |
| B12 | `accd.sh:2021` | A millivolt pause (>100) is clamped to `stop=100`, which firmware reads as "never stop" | source |
| B13 | `acca.sh:135` | `export "$@"` hands values straight to write-config, bypassing the range refusal `acc -s` enforces | **device**: `acca -s pause_capacity=999` → exit 0, stored 80; `acc -s pause_capacity=999` → exit 2 |

## Rejected claims — do not "fix" these

| Claim | Why it is wrong |
|---|---|
| `accd.sh:594` unguarded `disable_charging` exits the daemon | The call is inside `is_charging`, invoked as `if is_charging`. **Device-proven on both phones**: mksh suspends `set -e` for the whole call. `accd.sh:1453-1460` already says so |
| `accd.sh:2170` bare `not_charging` aborts `leak_backstop` | Same mechanism; called as `leak_backstop && {…}`. Device-proven |
| `acca.sh:135` `export "$@"` executes `$(cmd)` as root | **Device-proven on both phones**: stored literally, nothing executed |
| AMPS fallback labels a node it did not pin | `CFG_BYPASS` and `pick1` both take the first hit, assigned in the same statement |

## Already landed before this plan

`service.sh` daemon verification and `/system/bin/sh` pinning (t97), `acca` glued filters (t96),
`ui_refresh` exposure (t95), `module.prop` LF, `build-zip.py` CRLF gate, P8 mutation 1 re-point,
P3 `PREV`/`PREVLBL` override.
