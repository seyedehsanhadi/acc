# USB re-kick collapsing a fast-charge contract — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop ACC from silently renegotiating a live high-voltage charging contract down to 5 V when a current limit is cleared.

**Architecture:** ACC fires `apsd_rerun` / `rerun_aicl` from five places. Three are gated; the two inside `set_ch_curr`'s clear path are not — they bypass the user's `acc -sk off` switch, bypass the rate limiter, and write nothing to the ledger, so they are invisible in every diagnostic bundle. Route all five through one shared helper that honours the off switch, rate-limits, and logs; then teach that helper to leave a live negotiated contract alone.

**Tech Stack:** POSIX shell (mksh on device), ACC module scripts under `install/`, pure-unit test suites under `suites/accd/`.

## Global Constraints

- Target shell is **mksh** (`/system/bin/sh`). Every script must pass `sh -n` **on device**, not only `bash -n`. Verify with `dash -n` locally as a POSIX proxy.
- No code comments beyond what explains *why* — this repo documents reasoning, not mechanics. No AI attribution anywhere.
- The daemon runs under `set -eu`. An unguarded failing command exits the daemon, which fires the exit trap and drops the charging limit. Every new call site needs `|| :` or an `if` context.
- `_wlog` is not defined in every scope. Call it as `command -v _wlog >/dev/null 2>&1 && _wlog "..." || :`, matching `accd.sh:2050`.
- Never lower a live negotiated input-current node. This is the rc22 rule already applied at `accd.sh:2098` (`[ "$_ccn" -le 100000 ]`); the same rule is missing on the clear path.
- Tests are pure units: they reproduce a decision against fake values and write no device node. Run with `execDir=<path> bash suites/accd/tNN-*.sh`.
- Every test must be mutation-verified: it has to FAIL against `git show HEAD:install/<file>`.

---

## Background — the evidence

Field report, curtana (Redmi Note 9S, atoll, ACC rc22 202505302), bundle `acc-diag-curtana-20260804-132857`:

| time | observation |
|---|---|
| 13:25:01 | daemon exits, ledger records three exit-trap restores |
| 13:26:38 | ledger: `write battery/constant_charge_current <- 1500000 (was 500000)` and `main/constant_charge_current_max <- 1500000 (was 500000)`, with `maxChargingCurrent=()` — no limit configured |
| 13:28–13:30 | `flight.log` pinned at 1.03–1.54 A; `acc -i` shows `power_supply_volts 4.83`, `power_supply_watts 5.84`, `charge_type USB_PD` |
| ~13:40 | AMPS forces a physical unplug/replug; report then measures `Vbus=8656mV`, input 1766 mA, ~15.3 W |

The 13:26:38 writes are `set_ch_curr -` clearing a stale `.mcc-custom` marker. That path also fires `apsd_rerun` + `rerun_aicl` and then deletes the marker, which is why the daemon trace afterwards shows `set_ch_curr -` reaching `[ -z '' ] → return 0` and no-oping ever since. One shot, no ledger line.

`usb/pd_active|1|0` and `usb/real_type|USB_PD|Unknown` in the AMPS unplug diff confirm a real PD contract was live. A PD contract does not recover on its own; only a physical replug renegotiates it, which is exactly what AMPS's unplug prompt did.

**Not yet proven:** that the re-kick, rather than something else, caused the collapse. Task 2 is the gate. Do not merge Tasks 3–4 without it.

## File structure

| File | Responsibility | Change |
|---|---|---|
| `install/misc-functions.sh` | shared helpers, incl. `_rekick_due` | add `rekick_usb()`, the single gate for every re-kick |
| `install/set-ch-curr.sh` | current-limit set/clear | replace two raw re-kick loops with `rekick_usb`; stop lowering live input nodes on clear |
| `install/accd.sh` | daemon | `rekick_charger()` delegates to `rekick_usb` |
| `install/strings.sh` | CLI help | `-sk` text now true for every path |
| `suites/accd/t35-rekick-gate.sh` | new | the off switch, the rate limit, the logging |
| `suites/accd/t36-clear-live-nodes.sh` | new | a clear must not lower a live negotiated node |
| `CHANGELOG.md` | user-facing | rc22 entry |
| `LIMITS.md` | reference | note the interaction |

---

### Task 1: One gate for every re-kick

Standalone value: it makes `acc -sk off` actually work everywhere and makes the re-kick visible in diagnostics. It is also the instrument Task 2 needs, so it comes first.

**Files:**
- Modify: `install/misc-functions.sh:521-535` (beside `_rekick_due`)
- Modify: `install/set-ch-curr.sh:49-51`, `install/set-ch-curr.sh:95-97`
- Modify: `install/accd.sh:1412-1437`
- Test: `suites/accd/t35-rekick-gate.sh`

**Interfaces:**
- Produces: `rekick_usb <reason>` — returns 0 if it fired, 1 if suppressed. Honours `$dataDir/.rekick-off`, rate-limits via `_rekick_due`, logs every write and every suppression through `_wlog`.
- Consumes: `_rekick_due` (`misc-functions.sh:521`), `_wlog` (optional, guarded).

- [ ] **Step 1: Write the failing test**

Create `suites/accd/t35-rekick-gate.sh`:

```sh
#!/system/bin/sh
# t35 - every USB re-kick goes through one gate.
#
# apsd_rerun/rerun_aicl force the charger to re-run input detection. On a phone holding a USB-PD or
# QC contract that renegotiates it, and a PD contract only recovers on a physical replug -- so a
# stray re-kick strands the owner at 5V until they unplug. `acc -sk off` exists for exactly this.
#
# Two sites in set_ch_curr's clear path fired it raw: no off switch, no rate limit, and no ledger
# line, so it was invisible in diagnostics. Field bundle acc-diag-curtana-20260804-132857 shows the
# clear's FCC writes at 13:26:38 with no re-kick beside them, then 4.83V/5.84W until a replug
# restored 8.66V/15.3W.

ID=t35
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
SC=$execDir/set-ch-curr.sh
AD=$execDir/accd.sh
for _f in "$MF" "$SC" "$AD"; do [ -f "$_f" ] || { no "$_f not found"; fin; }; done

# ---- source level: no raw re-kick loops survive anywhere but the uninstaller ----
grep -q 'rekick_usb() {' "$MF" \
  && ok "the shared gate exists" || no "rekick_usb is not defined"

_raw=$(grep -c 'apsd_rerun' "$SC" 2>/dev/null)
[ "$_raw" = 0 ] \
  && ok "set-ch-curr has no raw re-kick left" \
  || no "set-ch-curr still writes apsd_rerun directly ($_raw occurrence(s)) - bypasses the off switch"

grep -q 'rekick_usb' "$SC" \
  && ok "set-ch-curr routes through the gate" || no "set-ch-curr does not call rekick_usb"

grep -q 'rekick_usb' "$AD" \
  && ok "the daemon stall path routes through the gate" || no "rekick_charger does not delegate"

sed -n '/rekick_usb() {/,/^}/p' "$MF" | grep -q 'rekick-off' \
  && ok "the gate honours acc -sk off" || no "the gate ignores the user's off switch"

sed -n '/rekick_usb() {/,/^}/p' "$MF" | grep -q '_rekick_due' \
  && ok "the gate rate-limits" || no "the gate does not rate-limit"

sed -n '/rekick_usb() {/,/^}/p' "$MF" | grep -q '_wlog' \
  && ok "the gate logs, so a re-kick is visible in a diagnostic bundle" \
  || no "the gate is silent - a re-kick leaves no trace in the ledger"

# ---- behavioural: reproduce the gate's decision ----
TD=$(mktemp -d); DD=$(mktemp -d)
_rekickMinInterval=30
gate() {   # $1 = "off" to simulate acc -sk off, $2 = seconds since last kick ("" = never)
  [ "$1" != off ] || return 1
  case "$2" in
    '') return 0;;
    *) [ "$2" -ge "$_rekickMinInterval" ];;
  esac
}
gate on ""   && ok "first kick fires with no delay"        || no "the first kick was suppressed"
gate on 60   && ok "a kick outside the window fires"       || no "a due kick was suppressed"
gate on 5    && no "a kick inside the window fired"        || ok "a repeat inside the window is dropped"
gate off ""  && no "a kick fired with the off switch set"  || ok "acc -sk off stops even the first kick"
gate off 600 && no "the off switch was ignored when due"   || ok "acc -sk off wins over the rate limit"
rm -rf "$TD" "$DD"

fin
```

- [ ] **Step 2: Run it to verify it fails**

```bash
execDir="C:/Users/PC/Desktop/PROJECTS/ACC/install" bash suites/accd/t35-rekick-gate.sh
```

Expected: FAIL on `rekick_usb is not defined`, `set-ch-curr still writes apsd_rerun directly (2 occurrence(s))`, and the two routing assertions.

- [ ] **Step 3: Add the shared gate**

In `install/misc-functions.sh`, immediately after `_rekick_due()` (which currently ends at line 535):

```sh
rekick_usb() {
  # rc22: the ONE place a USB re-kick happens. apsd_rerun/rerun_aicl re-run charger input
  # detection: the thing that recovers a stalled charger, and the thing that renegotiates a live
  # QC/PD contract down to 5V. A PD contract does not recover on its own -- only a physical replug
  # does -- so a stray kick strands the owner at 5V until they unplug.
  #
  # set_ch_curr's clear path used to fire it raw, twice, which meant `acc -sk off` did not cover
  # it and no ledger line was written, so it was invisible in every diagnostic bundle we received.
  # Field bundle acc-diag-curtana-20260804-132857: the clear's own FCC writes are in the ledger at
  # 13:26:38 with no re-kick beside them, then 4.83V/5.84W until a replug restored 8.66V/15.3W.
  local _reason=${1:-unspecified} _rn=
  if [ -f "${dataDir:-/data/adb/vr25/acc-data}/.rekick-off" ]; then
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick skipped ($_reason): acc -sk off" || :
    return 1
  fi
  if ! _rekick_due; then
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick skipped ($_reason): too soon" || :
    return 1
  fi
  for _rn in */apsd_rerun */rerun_aicl; do
    [ -w "$_rn" ] || continue
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick $_rn <- 1 ($_reason)" || :
    echo 1 > "$_rn" 2>/dev/null || :
  done
  return 0
}
```

The glob `*/apsd_rerun` matches only with the working directory at `/sys/class/power_supply`, which is where the daemon and `acc.sh` both `cd` (`accd.sh:2243`, `acc.sh:75`, `misc-functions.sh:1105`). That is the same form `rekick_charger` and `enable_charging` already use.

- [ ] **Step 4: Route `set_ch_curr`'s two clear paths through it**

In `install/set-ch-curr.sh`, replace lines 49-51:

```sh
          rekick_usb clear-not-charging || :
```

and replace lines 95-97 (keeping the surrounding comment, which explains why a re-kick is wanted here at all):

```sh
        rekick_usb clear-resolved || :
```

- [ ] **Step 5: Delegate the daemon's stall re-kick**

In `install/accd.sh`, replace the body of `rekick_charger()` (lines 1424-1436) with:

```sh
    rekick_usb stall
```

Keep the function and its comment block: it is the documented name for the stall path and `accd.sh:1125` calls it. `REKICK_MIN_GAP` is dropped in favour of `_rekickMinInterval`; note this in the commit message, since the stall window moves from 300 s to 30 s. If the 300 s window must be preserved for the stall path specifically, pass it: `_rekickMinInterval=${REKICK_MIN_GAP:-300} rekick_usb stall`.

- [ ] **Step 6: Update the CLI help so it is true**

In `install/strings.sh:125`, the `-sk` line already promises this. No text change needed — verify by reading it that the promise now holds for all paths.

- [ ] **Step 7: Run the test**

```bash
execDir="C:/Users/PC/Desktop/PROJECTS/ACC/install" bash suites/accd/t35-rekick-gate.sh
```

Expected: PASS, all assertions.

- [ ] **Step 8: Mutation-verify**

```bash
mkdir -p /tmp/mut3 && git show HEAD:install/misc-functions.sh > /tmp/mut3/misc-functions.sh && git show HEAD:install/set-ch-curr.sh > /tmp/mut3/set-ch-curr.sh && git show HEAD:install/accd.sh > /tmp/mut3/accd.sh && execDir=/tmp/mut3 bash suites/accd/t35-rekick-gate.sh
```

Expected: FAIL on the source-level assertions. If it passes, the test is not testing the change.

- [ ] **Step 9: Syntax-check for the device shell**

```bash
for f in install/misc-functions.sh install/set-ch-curr.sh install/accd.sh; do dash -n "$f" && bash -n "$f" || echo "FAIL $f"; done
```

- [ ] **Step 10: Commit**

```bash
git add install/misc-functions.sh install/set-ch-curr.sh install/accd.sh suites/accd/t35-rekick-gate.sh
git commit -m "fix: route every USB re-kick through one gate that honours acc -sk off and logs"
```

---

### Task 2: Prove the re-kick is what collapses the contract

**This task is a gate.** Tasks 3 and 4 change behaviour on a hypothesis until this produces evidence. If it shows the re-kick is innocent, stop and re-plan.

A 5 V PC port cannot demonstrate a 9 V collapse. This needs a QC or PD **wall charger**. Two routes; either is sufficient.

**Files:**
- Create: `PROJECTS/SHIPPING/acc-rekick-probe.sh`

**Interfaces:**
- Consumes: `rekick_usb` logging from Task 1 — the ledger line is what pins the moment.
- Produces: a verdict recorded in `.scratch/pd-rekick-fix/evidence.md`.

- [ ] **Step 1: Write the probe**

Create `PROJECTS/SHIPPING/acc-rekick-probe.sh`:

```sh
#!/system/bin/sh
# acc-rekick-probe.sh - does a USB re-kick collapse this charger's negotiated voltage?
#
# Needs a QC/PD WALL charger. A 5V PC port has no contract to lose and will show nothing.
# Read-mostly: sets and clears a current limit, which is a normal user action. Restores it.

OUT=/sdcard/Download/acc-rekick-$(date +%Y%m%d-%H%M%S).txt
[ -d /sdcard/Download ] || OUT=/data/local/tmp/acc-rekick-$(date +%Y%m%d-%H%M%S).txt
U=/sys/class/power_supply/usb
log(){ echo "$*" | tee -a "$OUT"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
vbus(){ _v=$(rd $U/voltage_now); case "${_v:-x}" in ''|*[!0-9]*) echo "";; *) echo $((_v / 1000));; esac; }
snap(){ echo "vbus=$(vbus)mV pd_active=$(rd $U/pd_active) real_type=$(rd $U/real_type) icl=$(rd $U/current_max)"; }

S_MCC=$(sed -n 's/^maxChargingCurrent=//p' /data/adb/vr25/acc-data/config.txt | tr -d '()' | cut -d' ' -f1)
trap 'acc -s max_charging_current="$S_MCC" >/dev/null 2>&1; log "restored max_charging_current=($S_MCC)"; exit 0' EXIT INT TERM HUP

log "=== rekick probe $(date) ==="
log "BEFORE  $(snap)"
V0=$(vbus)
if [ -z "$V0" ] || [ "$V0" -lt 7000 ]; then
  log "vbus is ${V0:-unreadable}mV. This is not a high-voltage contract, so there is nothing to"
  log "collapse and this probe cannot answer the question. Use a QC or PD wall charger."
  exit 0
fi
log "high-voltage contract confirmed at ${V0}mV"

acc -s max_charging_current=1000 >/dev/null 2>&1
sleep 30
log "CAPPED  $(snap)"

acc -s max_charging_current= >/dev/null 2>&1
sleep 45
log "CLEARED $(snap)"
V1=$(vbus)
log "--- ledger around the clear ---"
tail -12 /dev/.vr25/acc/.write-ledger 2>/dev/null | tee -a "$OUT"

if [ -n "$V1" ] && [ "$V1" -lt $(( V0 * 3 / 4 )) ]; then
  log "VERDICT: collapsed ${V0}mV -> ${V1}mV across the clear. If a 'rekick' line appears above,"
  log "         the re-kick is the cause."
else
  log "VERDICT: held at ${V1}mV (was ${V0}mV). The re-kick did NOT collapse this contract."
fi
log "saved: $OUT"
```

- [ ] **Step 2: Route A — reproduce on the Mi A3**

The A3 (laurus) has both `usb/apsd_rerun` and `battery/rerun_aicl`; both were observed firing in its own ledger on 2026-08-04. Move it to a QC wall charger, battery near 60%, then:

```bash
adb -s 4799111728be shell 'su -c "sh /data/local/tmp/acc-rekick-probe.sh"'
```

- [ ] **Step 3: Route B — capture on curtana**

Send the same script to the reporter with: replug to get fast charge back, confirm the report shows a high voltage, then run it. His phone is the one with the confirmed PD contract.

- [ ] **Step 4: Record the verdict**

Write `.scratch/pd-rekick-fix/evidence.md` with the probe output and a one-line conclusion. If the contract held, **stop here and re-plan** — the cause is elsewhere, and the FCC write over the ROM's live `fcc_thermal` vote is the next suspect.

- [ ] **Step 5: Commit the probe**

```bash
git add ../SHIPPING/acc-rekick-probe.sh .scratch/pd-rekick-fix/evidence.md
git commit -m "test: probe whether a USB re-kick collapses a negotiated charging contract"
```

---

### Task 3: Leave a live negotiated contract alone

Only after Task 2 confirms the collapse.

**Files:**
- Modify: `install/misc-functions.sh` (inside `rekick_usb` from Task 1)
- Test: `suites/accd/t35-rekick-gate.sh` (extend)

**Interfaces:**
- Consumes: `rekick_usb` from Task 1.
- Produces: no signature change. `rekick_usb` gains a third suppression reason.

- [ ] **Step 1: Extend the test**

Append to `suites/accd/t35-rekick-gate.sh` before `fin`:

```sh
# ---- a live high-voltage contract must be left alone ----
sed -n '/rekick_usb() {/,/^}/p' "$MF" | grep -q 'pd_active' \
  && ok "the gate checks for a live PD contract" \
  || no "the gate will still renegotiate a live PD contract down to 5V"

# $1 = pd_active, $2 = vbus mV -> 0 means "safe to re-kick"
safe() {
  [ "$1" = 1 ] && return 1
  case "${2:-x}" in ''|*[!0-9]*) return 0;; esac
  [ "$2" -lt 6000 ]
}
safe 1 9000 && no "re-kicked a live PD contract at 9V"      || ok "a live PD contract is left alone"
safe 0 9000 && no "re-kicked a 9V non-PD contract"          || ok "a 9V QC contract is left alone"
safe 0 5000 && ok "a plain 5V source is still re-kicked"    || no "a 5V source was wrongly skipped"
safe 0 ''   && ok "an unreadable vbus still re-kicks (recovery beats caution)" \
            || no "an unreadable vbus disabled the recovery re-kick"
```

The unreadable case matters: the re-kick's other job is recovering a stalled charger. Failing toward silence there would strand someone not charging at all, which is worse than a slow charge.

- [ ] **Step 2: Run it to verify it fails**

```bash
execDir="C:/Users/PC/Desktop/PROJECTS/ACC/install" bash suites/accd/t35-rekick-gate.sh
```

Expected: FAIL on `the gate will still renegotiate a live PD contract down to 5V`.

- [ ] **Step 3: Add the check**

In `rekick_usb`, after the `_rekick_due` block and before the write loop:

```sh
  # rc22: never re-run source detection on a contract the charger already negotiated up. apsd_rerun
  # renegotiates, and PD/QC land back at 5V and STAY there -- only a physical replug recovers, which
  # is why the field fix was always "unplug and replug". Fails toward re-kicking: an unreadable vbus
  # still fires, because the other half of this function's job is recovering a stalled charger and
  # silence there strands someone not charging at all.
  local _pd= _vb=
  _pd=$(cat usb/pd_active 2>/dev/null || echo 0)
  { read -r _vb < usb/voltage_now; } 2>/dev/null || _vb=
  case "${_vb:-x}" in ''|*[!0-9]*) _vb=;; *) _vb=$(( _vb / 1000 ));; esac
  if [ "${_pd:-0}" = 1 ] || { [ -n "$_vb" ] && [ "$_vb" -ge 6000 ]; }; then
    command -v _wlog >/dev/null 2>&1 \
      && _wlog "rekick skipped ($_reason): live contract pd_active=${_pd:-?} vbus=${_vb:-?}mV" || :
    return 1
  fi
```

- [ ] **Step 4: Run the test**

Expected: PASS.

- [ ] **Step 5: Re-run the device probe from Task 2**

Same command, same charger. Expected: `VERDICT: held`, and a `rekick skipped ... live contract` line in the ledger.

- [ ] **Step 6: Commit**

```bash
git add install/misc-functions.sh suites/accd/t35-rekick-gate.sh
git commit -m "fix: do not re-run charger detection on an already-negotiated high-voltage contract"
```

---

### Task 4: A clear must not lower a live input node

Independent of Task 2's verdict — this is the same rc22 rule already applied at `accd.sh:2098`, missing on the clear path. `apply_on_plug default` writes probe-time snapshots, and its back-off guard is deliberately skipped on a restore (`misc-functions.sh:67`, `[ "$arg" = value ]`), so every recorded default is written unconditionally. A default captured on a PC-USB probe is 500000; writing that over a wall charger's negotiated 2450000 caps the phone at 500 mA.

**Files:**
- Modify: `install/misc-functions.sh:44-77` (`apply_on_plug`)
- Test: `suites/accd/t36-clear-live-nodes.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature change. `apply_on_plug default` skips a node whose live value already exceeds the recorded default.

- [ ] **Step 1: Write the failing test**

Create `suites/accd/t36-clear-live-nodes.sh`:

```sh
#!/system/bin/sh
# t36 - clearing a current limit must never LOWER a live negotiated input node.
#
# apply_on_plug default writes the value recorded at probe time. Those snapshots are taken whenever
# the probe happened to run: on a PC-USB port usb/current_max reads 500000, and writing that back
# over a wall charger's negotiated 2450000 caps the phone at 500mA for the rest of the session.
# The back-off guard that would catch a rejected write is deliberately skipped on a restore
# (misc-functions.sh: [ "$arg" = value ]), so nothing bounded this.
#
# Same rule as the init restore already carries (accd.sh: _ccn -le 100000): only ever raise, never
# lower, a node the charger driver owns.

ID=t36
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }

grep -q 'never lower a live' "$MF" \
  && ok "the restore path documents the never-lower rule" \
  || no "no never-lower guard on the restore path"

# $1 = live node value, $2 = recorded default -> 0 means "write it"
wr() {
  _live=$1; _def=$2
  case "${_def:-x}" in ''|*[!0-9]*) return 1;; esac
  case "${_live:-x}" in ''|*[!0-9]*) return 0;; esac
  [ "$_live" -lt "$_def" ]
}

wr 2450000 500000 && no "a live 2450000 was lowered to a 500000 probe snapshot (the field bug)" \
                  || ok "a live negotiated 2450000 is left alone"
wr 3000000 1500000 && no "a live 3000000 was lowered to 1500000" || ok "a live 3000000 is left alone"
wr 0 2600000       && ok "a node ACC zeroed IS restored"         || no "the clear no longer un-caps"
wr 500000 2600000  && ok "a node ACC capped low IS raised"       || no "a low cap is no longer lifted"
wr 2600000 2600000 && no "an equal value was rewritten"          || ok "equal value -> no write"
wr abc 2600000     && ok "an unreadable live value still restores (never strand a capped node)" \
                   || no "an unreadable live value blocked the restore"
wr 500000 ''       && no "a non-numeric default was acted on"    || ok "a garbage default is ignored"

fin
```

- [ ] **Step 2: Run it to verify it fails**

Expected: FAIL on `no never-lower guard on the restore path`.

- [ ] **Step 3: Add the guard**

In `install/misc-functions.sh`, inside `apply_on_plug`'s loop, immediately before `set +e` / `write \$$arg $file 0 &`:

```sh
    # rc22: on a RESTORE, never lower a live value. The recorded default is a snapshot from whenever
    # the probe ran -- on a PC-USB port usb/current_max reads 500000 -- and writing that back over a
    # wall charger's negotiated 2450000 caps the phone at 500mA for the session. Only ever raise.
    # An unreadable live value still writes: leaving a node capped is the failure this path exists
    # to prevent. Same rule the init restore carries.
    if [ "$arg" = default ]; then
      _lv=; { read -r _lv < "$file"; } 2>/dev/null || _lv=
      case "${_lv:-x}" in
        ''|*[!0-9]*) : ;;
        *) case "${default:-x}" in
             ''|*[!0-9]*) : ;;
             *) [ "$_lv" -lt "$default" ] 2>/dev/null || continue;;
           esac;;
      esac
    fi
```

Add `_lv=` to the `local` list at line 42.

- [ ] **Step 4: Run the test**

Expected: PASS.

- [ ] **Step 5: Mutation-verify**

```bash
execDir=/tmp/mut3 bash suites/accd/t36-clear-live-nodes.sh
```

Expected: FAIL on the source assertion.

- [ ] **Step 6: Regression-check the reports this path exists for**

Both were real field bugs; neither may come back.

```bash
adb -s 4799111728be shell 'su -c "acc -s max_charging_current=800; sleep 20; acc -i | grep -i current"'
adb -s 4799111728be shell 'su -c "acc -s max_charging_current=; sleep 20; grep maxChargingCurrent /data/adb/vr25/acc-data/config.txt; cat /sys/class/power_supply/battery/constant_charge_current_max"'
```

Expected: the config clears, and the node is **not** left at 800000. "Disabled it but it still sticks" must not return.

- [ ] **Step 7: Commit**

```bash
git add install/misc-functions.sh suites/accd/t36-clear-live-nodes.sh
git commit -m "fix: clearing a current limit no longer lowers a live negotiated input node"
```

---

### Task 5: Verify on both phones and document

**Files:**
- Modify: `CHANGELOG.md`, `LIMITS.md`
- Test: full suite on device

- [ ] **Step 1: Install on both phones**

Push each changed file, `sh -n` on device before replacing, restart the daemon in its **own** adb call — `acc -D restart` chained in the same `su -c` SIGTERMs the calling shell (exit 143).

```bash
adb -s <serial> push install/misc-functions.sh /data/local/tmp/misc.new
adb -s <serial> shell 'su -c "tr -d \"\r\" < /data/local/tmp/misc.new > /data/local/tmp/misc.lf; sh -n /data/local/tmp/misc.lf && { cat /data/local/tmp/misc.lf > /data/adb/vr25/acc/misc-functions.sh; chmod 755 /data/adb/vr25/acc/misc-functions.sh; echo ok; }"'
adb -s <serial> shell 'su -c "acc -D restart >/dev/null 2>&1 &"'
```

- [ ] **Step 2: Run the suites on device**

```bash
adb -s <serial> shell 'su -c "for t in /data/local/tmp/t3*.sh; do sh \$t; done"'
```

Expected: t33 22/0, t34 13/0, t35 all pass, t36 all pass.

- [ ] **Step 3: Confirm the daemon survives**

```bash
adb -s <serial> shell 'su -c "P=\$(cat /dev/.vr25/acc/acc.lock); [ -d /proc/\$P ] && echo alive || echo DOWN"'
```

A `set -eu` abort from a new call site shows up here and nowhere else.

- [ ] **Step 4: Re-run the limit matrix on the Pixel**

```bash
adb -s 28291JEGR14804 shell 'su -c "sh /data/local/tmp/mx2.sh"'
```

Expected: 10 of 10 pause-dominant rows still correct. The Pixel is the control — it has no `apsd_rerun`, so nothing here should change its behaviour at all.

- [ ] **Step 5: Changelog**

Add to the rc22 `Fixed` section of `CHANGELOG.md`, in the established voice — bold lead sentence naming the symptom the owner saw, then what was wrong:

```markdown
- **Turning off the charging current limit could drop your phone to slow charging until you unplugged it.** Clearing that limit made ACC ask the charger to re-run its input detection, so the nodes it had just restored would settle to what the charger can really deliver. On a phone holding a fast-charge agreement that request renegotiates it, and USB-PD and Quick Charge both land back at 5 V and stay there: nothing recovers it except physically unplugging the cable. The same request is also what recovers a genuinely stalled charger, so it is not simply removed. It is now skipped whenever the charger has already negotiated a higher voltage, it obeys `acc -sk off` from every path rather than only some, and it is recorded, so a diagnostic bundle shows when it happened. Reported on a Redmi Note 9S charging at 5.8 W where the same phone did 15.3 W a minute after a replug.
- **Clearing a current limit could cap charging at whatever the phone was drawing when ACC first looked.** The values ACC restores are a snapshot from the moment it identified the control nodes. Taken on a computer's USB port that snapshot is 500 mA, and writing it back later on a wall charger held the phone at 500 mA for the rest of the session. A restore now only ever raises one of these nodes, never lowers it.
```

- [ ] **Step 6: Update LIMITS.md**

Add to the "Settings that are accepted but cannot act" table:

```markdown
| clearing a current limit on a fast charger | re-negotiates down to 5 V until you replug | **fixed rc22** |
```

- [ ] **Step 7: Prose check**

```bash
python "C:/Users/PC/.claude/skills/sloptrim/scripts/detect.py" CHANGELOG.md
```

Expected: `ai_tell_band` clean, score ≤ 40.

- [ ] **Step 8: Commit**

```bash
git add CHANGELOG.md LIMITS.md
git commit -m "docs: rc22 charger re-kick and current-restore fixes"
```

---

## Self-review

**Spec coverage.** The two unguarded sites are Task 1. The PD collapse is Task 3, gated on Task 2's evidence. The probe-snapshot restore is Task 4. Verification and docs are Task 5. The FCC-over-`fcc_thermal` observation is deliberately **not** in scope — it needs its own evidence, and Task 2 Step 4 names it as the next suspect if the re-kick turns out innocent.

**Placeholders.** Every code step carries real code. Every test step carries the assertions. Every command is runnable as written.

**Type consistency.** `rekick_usb <reason>` is introduced in Task 1 Step 3 and used unchanged in Task 1 Steps 4-5 and extended in Task 3 Step 3. `_rekickMinInterval` is the existing name from `misc-functions.sh:527`; `REKICK_MIN_GAP` is called out in Task 1 Step 5 as the value that changes meaning. `apply_on_plug`'s `$arg`, `$file`, `$default` in Task 4 Step 3 match the names at `misc-functions.sh:41-51`.

## Open risks

- **Task 2 may exonerate the re-kick.** Then Tasks 1 and 4 still stand on their own merits — an off switch that does not switch everything off, and a restore that lowers live values, are both defects regardless — but Task 3 must be dropped and the FCC write investigated instead.
- **Changing the stall window from 300 s to 30 s** (Task 1 Step 5) is a behaviour change on a path that is currently working. The alternative is spelled out in that step; prefer it unless there is a reason not to.
- **Neither of my test phones is on a wall charger.** Every current-related measurement on a PC USB port is untrustworthy: the A3 draws 157 mA and tapers below ACC's 10 mA idle threshold, and ACC's smallest current cap is 300 mA, so there is nothing to cap. Task 2 cannot be done without one.
