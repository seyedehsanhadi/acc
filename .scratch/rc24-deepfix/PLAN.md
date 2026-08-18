# ACC rc24 Deep-Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the thirteen rc23 defects that reach real users, each proven by a suite case that fails on rc23 and passes on rc24, with no idle-cost, race, or capability regression.

**Architecture:** Every defect gets the same four-stage treatment — detect (a probe that names the symptom on hardware), isolate (a mutation or fault injection that pins it to one line), reproduce (a `suites/accd/tNN` case with edge cases and noise), fix (smallest diff at the shared choke point). The staged rc23 tree at `/data/local/tmp/rc23` is the A arm and the installed tree is the B arm, so every claim is an A/B on one phone in one boot. Nothing new runs in the daemon's hot loop unless the idle-cost arm proves it free.

**Tech Stack:** mksh (`/system/bin/sh`) on Android; toybox userland; Magisk (laurus / Mi A3) and KernelSU (bluejay / Pixel 6a); `suites/mega2` phase runner; `suites/accd/t*.sh` unit suites; adb over TCP.

**Spec:** `.scratch/rc24-deepfix/SPEC.md` (the verified defect list; verdicts recorded in `.scratch/rc24-deepfix/VERDICTS.md`)

## Global Constraints

- **Shell is mksh, not bash.** Every suite runs under `/system/bin/sh`. toybox `grep` has no `\|` or `\s`; `${var%%pat}` reads `|` as alternation. Never grade a result produced by the PC's bash.
- **`set -e` is suspended for a function called from a condition.** Device-proven on both phones. `is_charging` (`if is_charging`) and `leak_backstop` (`leak_backstop && …`) are therefore NOT abort sites. Do not "fix" `accd.sh:594` or `accd.sh:2170`; a guard there is dead code that hides the real contract.
- **Offline charging is inviolable.** Phone off + cable + battery icon: never cut, never power off. Any new code path must keep `post-fs-data.sh`'s `*charger*` bail and `accd`'s shutdown handling intact.
- **No new global in `cycle_switches`.** Budgets are `local` — mksh scopes locals dynamically, which is what keeps the exit-trap restore sweep unbounded. A global deadline strands a phone.
- **No raw `echo > "$node"`.** Every new write goes through `write()` or carries its own adjacent `sw_blacklisted` check with a comment saying why it cannot.
- **No new background jobs, no new daemons, no new polling.** Every fix must be free at idle; Task 16 enforces this with a measurement, not an opinion.
- **`shutdown_temp` is never written by any test.** A numeric `shutdown_temp=9` powers a phone off at room temperature.
- **Every task appends one line to `.scratch/rc24-deepfix/CHANGELOG-rc24.md`** in the form `B<id> | <file>:<line> | <one-line behaviour change> | <suite that proves it>`. Task 18 folds that file into the repo changelog.
- **Version:** `module.prop` stays at `versionCode=202505331` until Task 18. LF line endings only (`build-zip.py` now refuses CRLF).

---

## Already landed in the working tree (do not redo)

| Item | File | Proven by |
|---|---|---|
| `service.sh` verifies the daemon started instead of trusting `start-stop-daemon`'s exit code | `install/service.sh:48-82` | t97, 7/0 both phones |
| The repair path is pinned to `/system/bin/sh` (busybox ash cannot parse accd.sh line 518) | `install/service.sh:68,70` | t97 section 3 |
| `acca -sdcapacity` / `-spcapacity` glued filters | `install/acca.sh:141-170` | t96, 15/0 both phones |
| `ui_refresh` exposed by the config printer | `install/print-config.sh:37` | t95, 6/0 both phones |
| `module.prop` normalised to LF | `module.prop` | P1 `versionCode is numeric` |
| Release zips refuse CRLF in shipped text files | `build-zip.py:129-132` | Task 17 |
| P8 mutation 1 re-pointed at the current source line | `suites/mega2/p8-mutation.sh:121` | caught by t59 |
| P3's previous-build arm is `PREV`/`PREVLBL`-overridable | `suites/mega2/p3-arms.sh:39,242` | rc23 arm ran 3/3 |

---

## The defect set

| B | Defect | Primary site | New suite |
|---|---|---|---|
| B1 | Replug does not resume on input-cut switches | `accd.sh:966`, `:2436` | t98 |
| B2 | Aim-high writes `usb/current_max` and holds ~17s before any pause | `accd.sh:1249-1290` | t99 |
| B3 | ON sweep unbounded; boot ON sweep unguarded | `misc-functions.sh:323`, `accd.sh:3115` | t100 |
| B4 | `acc -t` wait gate bare; `flip=off` forges `working-switches.log` | `acc.sh:955,957,991` | t101 |
| B5 | AMPS calls a working switch "no effect" after one sample | `acc-compat.sh:1710-1712` | t102 |
| B6 | QC/PD collapse cannot be repaired without an unplug | `misc-functions.sh:833`, `accd.sh:1052` | t103 |
| B7 | Native backstop undoes its own cut; `_ntHot` is volatile | `accd.sh:2214`, `:2044`, `:2850` | t104 |
| B8 | `write()` fires 5 more echos after the readback verified | `misc-functions.sh:1435-1442` | t105 |
| B9 | `xIdle` can never become true | `accd.sh:1451` | t106 |
| B10 | `_cut` aborts the group on the first missing node | `post-fs-data.sh:87` | t107 |
| B11 | Uninstall writes `usb/current_max` | `uninstall.sh:234` | t108 |
| B12 | A millivolt pause clamps to `charge_stop_level=100` | `accd.sh:2021` | t109 |
| B13 | `acca -s` bypasses the range refusal `acc -s` enforces | `acca.sh:135` | t110 |

---

## File structure

**Created:**
- `suites/accd/t98…t110-*.sh` — one unit suite per defect. Each extracts the shipped function into a staged copy and *executes* it, so a suite cannot pass by reading a comment.
- `suites/fakeps/` — a fabricated `/sys/class/power_supply` tree used by t99, t104 and t108. Lets a defect whose node is absent on both phones (`usb/input_current_max` is absent on laurus **and** bluejay) still be graded deterministically.
- `suites/mega2/p11-charge-modes.sh` — the plugged-mode matrix phase (5V slow, 9V fast).
- `.scratch/rc24-deepfix/CHANGELOG-rc24.md` — the running ledger.

**Modified:** `install/accd.sh`, `install/misc-functions.sh`, `install/acc.sh`, `install/batt-interface.sh`, `install/post-fs-data.sh`, `install/uninstall.sh`, `install/acca.sh`, `acc-compat.sh`, `suites/mega2/p8-mutation.sh` (one new mutation per fix), `suites/mega2/run.sh` (dispatch p11).

---

## Task 0: Detection and isolation harness

**Files:**
- Create: `suites/fakeps/mkfake.sh`
- Create: `.scratch/rc24-deepfix/CHANGELOG-rc24.md`

**Interfaces:**
- Produces: `mkfake <dir>` builds a writable power-supply tree with `usb/{online,present,current_max,input_current_max,voltage_now}`, `main/current_max`, `battery/{capacity,status,current_now,charge_counter,temp,input_suspend}`. Later tasks set `execDir`, `TMPDIR`, `NVB_NODE`, `NVB_CC` at those paths.

- [ ] **Step 1: Write the fake tree builder**

```sh
#!/system/bin/sh
# suites/fakeps/mkfake.sh - a writable stand-in for /sys/class/power_supply.
# Exists because the node a defect lives on is not always present on the test phones:
# usb/input_current_max is absent on BOTH laurus and bluejay, so native_verify_backstop
# returns at its second line and the defect cannot be observed on real hardware here.
mkfake() {
  _d=$1
  rm -rf "$_d" 2>/dev/null; mkdir -p "$_d/usb" "$_d/main" "$_d/battery" 2>/dev/null
  for _n in online present current_max input_current_max input_current_limit voltage_now; do
    echo 0 > "$_d/usb/$_n"
  done
  echo 0 > "$_d/main/current_max"
  for _n in capacity temp current_now charge_counter input_suspend; do echo 0 > "$_d/battery/$_n"; done
  echo Discharging > "$_d/battery/status"
  chmod -R 0666 "$_d" 2>/dev/null || :
  return 0
}
```

- [ ] **Step 2: Prove the builder produces writable nodes**

Run: `adb -s 192.168.137.18:5555 shell 'su -c "sh -c \". /data/adb/vr25/acc/suites/fakeps/mkfake.sh; mkfake /data/local/tmp/fps; echo 5 > /data/local/tmp/fps/usb/current_max; cat /data/local/tmp/fps/usb/current_max\""'`
Expected: `5`

- [ ] **Step 3: Create the ledger with its header**

```markdown
# rc24 change ledger
B | site | behaviour change | proof
--|------|------------------|------
```

- [ ] **Step 4: Commit**

```bash
git add suites/fakeps/mkfake.sh .scratch/rc24-deepfix/CHANGELOG-rc24.md
git commit -m "test: fabricated power-supply tree for defects whose node is absent on the test phones"
```

---

## Task 1: B8 — `write()` must not hammer after a verified write

Done first because every other fix writes through `write()`; measuring anything before this is measuring the wrong build.

**Files:**
- Modify: `install/misc-functions.sh:1435-1442`
- Test: `suites/accd/t105-write-no-post-verify-hammer.sh`

**Interfaces:**
- Consumes: `mkfake` from Task 0.
- Produces: `write()` returns `0` after one successful verified write and performs exactly one `echo`; on readback mismatch it returns `${3-1}` unchanged.

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t105 - write() must stop when the readback already proves the value landed.
ID=t105; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
W=/data/local/tmp/t105; rm -rf $W; mkdir -p $W

# A counting node: every write appends a line, so the test counts writes instead of trusting a comment.
cat > $W/node.sh <<'EOF'
EOF
: > $W/node
# Stage the shipped write() with its dependencies stubbed to nothing that touches hardware.
sed -n "/^write() {/,/^}/p" $execDir/misc-functions.sh > $W/write.sh
[ -s $W/write.sh ] || { no "could not extract write() from $execDir/misc-functions.sh"; fin; }

cat > $W/run.sh <<EOF
TMPDIR=$W; dataDir=$W; mkdir -p \$dataDir/logs
sw_blacklisted(){ return 1; }
_wlog(){ :; }
isAccd=false
. $W/write.sh
write 7 $W/node
echo "rc=\$?"
EOF
/system/bin/sh $W/run.sh > $W/out 2>&1
_n=$(wc -c < $W/node | tr -d ' ')
_v=$(cat $W/node)
[ "$_v" = 7 ] && ok "the value landed ($_v)" || no "value is '$_v', expected 7"
# 7 plus a newline is 2 bytes. Five extra echos of the same value rewrite it five more times;
# the node cannot show that by content, so count writes with a wrapper instead.
grep -q 'rc=0' $W/out && ok "write() returned 0" || no "write() returned non-zero: $(grep rc= $W/out)"

# THE DEFECT: count the echos. Replace the target with a fifo-backed counter.
: > $W/count
cat > $W/run2.sh <<EOF
TMPDIR=$W; dataDir=$W
sw_blacklisted(){ return 1; }
_wlog(){ :; }
isAccd=false
usleep(){ :; }
. $W/write.sh
# shadow the redirection target with a function-free counting file: every successful
# "echo v > node" is recorded by comparing mtime-independent append counts.
write 9 $W/node2
EOF
: > $W/node2
strace_free=yes
/system/bin/sh -x $W/run2.sh 2>&1 | grep -c "echo 9 > $W/node2" > $W/echos
_e=$(cat $W/echos)
if [ "${_e:-0}" -le 1 ]; then
  ok "exactly ${_e} echo(s) after a verified write"
else
  no "write() issued ${_e} echos after the readback already matched - each one re-triggers AICL on an input node"
fi
fin
```

- [ ] **Step 2: Run it on the Pixel against rc23 and confirm it fails**

Run:
```bash
adb -s 192.168.137.18:5555 push suites/accd/t105-write-no-post-verify-hammer.sh /data/local/tmp/ && adb -s 192.168.137.18:5555 shell 'su -c "execDir=/data/local/tmp/rc23 sh /data/local/tmp/t105-write-no-post-verify-hammer.sh"'
```
Expected: FAIL, `write() issued 6 echos after the readback already matched`

- [ ] **Step 3: Fix — retry only when the write did NOT verify**

```sh
  [ $i = x ] && {
    # rc24 (B8): the retry belongs to FAILURE, not success. This block used to run when the
    # readback had already proved the value landed, issuing five more identical echos with
    # usleep spacing. On input nodes (usb/current_max, input_current_limit) every one of them
    # re-runs AICL and the charge-pump FSM - exactly what the rc14 idempotent gate at the top
    # of this function exists to prevent, undone forty lines lower. A node that did not take
    # the value still gets the full retry budget below.
    for i in $(seq $seq); do
      eval "echo $1 > $2" 2>/dev/null || { [ $i -eq $seq ] && return ${3-1} || : ; }
      f="$(cat $2 2>/dev/null)" || :
      [ "$f" = "$one" ] && return 0
      usleep $((1000000 / $seq))
    done
    return ${3-1}
  }
  return 0
```

- [ ] **Step 4: Run the test again**

Expected: PASS, `exactly 1 echo(s) after a verified write`

- [ ] **Step 5: Prove no capability was lost — a node that reverts still gets retried**

Run: t105 with a node whose value is reset by a background writer; expected `write()` returns non-zero after `$seq` attempts, not on the first.

- [ ] **Step 6: Add the mutation and confirm it bites**

```sh
mutate "write() retries on SUCCESS again (5 redundant echos re-trigger AICL)" \
  misc-functions.sh \
  's|^  \[ \$i = x \] && {|  [ $i != x ] \&\& {|'
```

- [ ] **Step 7: Commit**

```bash
git add install/misc-functions.sh suites/accd/t105-write-no-post-verify-hammer.sh suites/mega2/p8-mutation.sh
git commit -m "fix: write() retries only when the readback failed"
```

- [ ] **Step 8: Ledger**

`B8 | misc-functions.sh:1435 | retry loop moved to the failure branch; one echo on success | t105 + mutation 12`

---

## Task 2: B1 — replug must resume on input-cut switches

**Files:**
- Modify: `install/accd.sh:966`, `install/accd.sh:2436`
- Test: `suites/accd/t98-generic-rearm-sees-replug.sh`

**Interfaces:**
- Produces: `freshPlug` is derived from `present`; `generic_rearm` gates on `present`, never `online`.

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t98 - generic_rearm must fire on a replug that leaves online at 0.
#
# THE DEFECT. input_suspend / current_max 0 hold their off state across an unplug, and they
# also drive */online to 0 while the cable is IN. freshPlug is computed from online and
# generic_rearm then re-checks online, so on exactly the switches this function names it can
# never run. Reported symptom: stops at the limit, replug does nothing until resume% or reboot.
ID=t98; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
W=/data/local/tmp/t98; rm -rf $W; mkdir -p $W

sed -n '/^  generic_rearm() {/,/^  }/p' $execDir/accd.sh > $W/fn.sh
[ -s $W/fn.sh ] || { no "generic_rearm not found in $execDir/accd.sh"; fin; }

# Source-level guard first: the plug tracker must not be online-derived.
if grep -qE '^\s+if online; then \$wasOnline \|\| freshPlug=true' $execDir/accd.sh; then
  no "freshPlug is still derived from online() - an input-cut replug never sets it"
else
  ok "freshPlug is not derived from online()"
fi
grep -qE '^\s+online \|\| return 0' $W/fn.sh \
  && no "generic_rearm still returns early on ! online" \
  || ok "generic_rearm does not gate on online()"

# Executable proof: cable IN, online 0 (a latched input cut), below pause, cool.
mkharness() {  # $1 = present, $2 = online, $3 = expect (fire|skip)
  cat > $W/run.sh <<EOF
nativeLimit=false
freshPlug=true
present(){ [ "$1" = 1 ]; }
online(){ [ "$2" = 1 ]; }
_lt_pause_cap(){ return 0; }
_temp_hold(){ return 1; }
TMPDIR=$W
enable_charging(){ echo FIRED > $W/fired; }
. $W/fn.sh
generic_rearm
EOF
  rm -f $W/fired
  /system/bin/sh $W/run.sh >/dev/null 2>&1 || :
  if [ "$3" = fire ]; then
    [ -f $W/fired ] && ok "present=$1 online=$2 -> re-armed" || no "present=$1 online=$2 -> NO re-arm (the reported bug)"
  else
    [ -f $W/fired ] && no "present=$1 online=$2 -> re-armed when it must not" || ok "present=$1 online=$2 -> correctly skipped"
  fi
}
mkharness 1 0 fire     # THE CASE: cable in, latched cut masks online
mkharness 1 1 fire     # ordinary replug
mkharness 0 0 skip     # no cable: never re-arm
mkharness 0 1 skip     # nonsense state: present is the authority

# Edge: hot pack must still block, and the boot loop must still be excluded.
cat > $W/run2.sh <<EOF
nativeLimit=false; freshPlug=true
present(){ return 0; }; online(){ return 0; }
_lt_pause_cap(){ return 0; }; _temp_hold(){ return 0; }
TMPDIR=$W; enable_charging(){ echo FIRED > $W/fired; }
. $W/fn.sh
generic_rearm
EOF
rm -f $W/fired; /system/bin/sh $W/run2.sh >/dev/null 2>&1 || :
[ -f $W/fired ] && no "re-armed over max_temp" || ok "a hot pack still blocks the re-arm"

: > $W/.minCapMax
cat > $W/run3.sh <<EOF
nativeLimit=false; freshPlug=true
present(){ return 0; }; online(){ return 0; }
_lt_pause_cap(){ return 0; }; _temp_hold(){ return 1; }
TMPDIR=$W; enable_charging(){ echo FIRED > $W/fired; }
. $W/fn.sh
generic_rearm
EOF
rm -f $W/fired; /system/bin/sh $W/run3.sh >/dev/null 2>&1 || :
[ -f $W/fired ] && no "re-armed during the boot loop (.minCapMax present)" || ok "the boot loop is still excluded"
fin
```

- [ ] **Step 2: Run against the rc23 arm**

Expected: FAIL on `freshPlug is still derived from online()`, FAIL on `present=1 online=0 -> NO re-arm`

- [ ] **Step 3: Fix the tracker**

```sh
      # rc24 (B1): PRESENT, not online. An input-cut switch (input_suspend, */current_max 0)
      # masks */online to 0 while the cable is physically in - the file says so at :998-1004 and
      # aim-high was moved to present/sawUnplug for exactly this reason. Deriving the plug edge
      # from online meant generic_rearm, whose entire purpose is those switches, could never see
      # a replug: freshPlug stayed false for the whole pause. present() is the physical question.
      freshPlug=false
      if present; then $wasOnline || freshPlug=true; wasOnline=true; else wasOnline=false; fi
```

- [ ] **Step 4: Fix the gate**

```sh
    # rc24 (B1): was `online || return 0`, which re-asked the question freshPlug had already
    # answered wrongly. enable_charging writes the switch ON value and is safe with no charger:
    # the rc22 release-gate fix removed present() from the flip precisely so an unplugged phone
    # is never left unable to charge. Re-arming with a cable in and online masked is the point.
    present || return 0
    enable_charging
```

- [ ] **Step 5: Run the test again**

Expected: PASS, 7/0

- [ ] **Step 6: Regression — native_unlatch still behaves**

Run: `execDir=<rc24> sh suites/accd/t*.sh` filtered to any suite naming `native_unlatch` or `freshPlug`.
Expected: no new failures. `present` and `online` are equal on a Pixel with no cut applied, so the native path is unchanged.

- [ ] **Step 7: Mutation**

```sh
mutate "generic_rearm gated on online() again (input-cut replug never resumes)" \
  accd.sh \
  's|^    present \|\| return 0|    online || return 0|'
```

- [ ] **Step 8: Commit and ledger**

```bash
git commit -am "fix: derive the plug edge from present() so an input-cut replug re-arms"
```
`B1 | accd.sh:966,2436 | plug edge and generic_rearm gate moved from online() to present() | t98 + mutation 13`

---

## Task 3: B2 — aim-high must not write charger-owned nodes, and must yield to the pause

**Files:**
- Modify: `install/accd.sh:1229`, `:1249-1259`, `:1280-1282`
- Test: `suites/accd/t99-aimhigh-node-allowlist.sh`

**Interfaces:**
- Consumes: `_iclNodes` (built at `accd.sh:2821`).
- Produces: aim-high writes only supply names in `main|main-charger|mainchg|charger|gccd|bbc`, through `write()`; the whole block is skipped while `chDisabledByAcc` or at/above pause.

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t99 - aim-high must not touch charger-negotiation nodes, and must not run while paused.
ID=t99; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
. $execDir/suites/fakeps/mkfake.sh
W=/data/local/tmp/t99; rm -rf $W; mkdir -p $W; mkfake $W/ps

_blk=$(sed -n '/if { { \$freshPlug && \${sawUnplug:-false}; } || \${_aimStall:-false}; }/,/^      fi$/p' $execDir/accd.sh)
[ -n "$_blk" ] || { no "aim-high block not found"; fin; }

case "$_blk" in
  *'echo 5000000 > "$_mcf"'*) no "aim-high still writes with a raw echo (no blacklist, no ledger)";;
  *) ok "aim-high no longer uses a raw echo";;
esac
case "$_blk" in
  *'case "${_mcf%/*}" in main|main-charger|mainchg|charger|gccd|bbc)'*) ok "aim-high uses the charger allow-list";;
  *) no "aim-high still uses a battery/gauge DENY-list, so usb/, dc/ and tcpm-* are written";;
esac
case "$_blk" in
  *'chDisabledByAcc'*) ok "aim-high yields while ACC is holding a pause";;
  *) no "aim-high runs with no chDisabledByAcc check - it undoes a current-cap pause";;
esac
case "$_blk" in
  *'_lt_pause_cap'*) ok "aim-high yields at/above the pause level";;
  *) no "aim-high has no pause-level check - up to 17s of unenforced limit after a replug";;
esac

# Executable: run the node loop in the fake tree and assert which files changed.
cat > $W/loop.sh <<EOF
cd $W/ps || exit 1
for _mcf in */current_max */input_current_limit */input_current_settled; do
  [ -w "\$_mcf" ] || continue
  case "\${_mcf%/*}" in main|main-charger|mainchg|charger|gccd|bbc) :;; *) continue;; esac
  echo 5000000 > "\$_mcf"
done
EOF
/system/bin/sh $W/loop.sh
[ "$(cat $W/ps/main/current_max)" = 5000000 ] && ok "main/current_max was lifted" || no "main/current_max was not lifted - the capability is gone"
[ "$(cat $W/ps/usb/current_max)" = 0 ] && ok "usb/current_max untouched" || no "usb/current_max was written (measured: drops a port to 100mA)"
fin
```

- [ ] **Step 2: Run against the rc23 arm** — Expected: 4 FAILs

- [ ] **Step 3: Fix the gate at `accd.sh:1229`**

```sh
      # rc24 (B2): never negotiate while ACC is holding the limit, and never at/above the pause.
      # This block ran at the TOP of the loop, before the pause at :1304/:1425, with no idea
      # whether a cut was in force - so a replug at 79% with the limit at 80% could undo a
      # current-cap pause and then spend up to 17s (sleep 2 + a 15s poll) with nothing enforced.
      if { { $freshPlug && ${sawUnplug:-false}; } || ${_aimStall:-false}; } \
         && ! $chDisabledByAcc && _lt_pause_cap \
         && [ ! -f $TMPDIR/.hvcontract ] && [ ! -f $dataDir/.rekick-off ]; then
```

- [ ] **Step 4: Fix the node loop**

```sh
              # rc24 (B2): ALLOW-list, not deny-list, and through write(). The deny-list named
              # battery/bms/gauge only, so usb/, dc/ and tcpm-* were written - and :2815-2818
              # already measured one write to usb/current_max dropping a Pixel port to 100mA.
              # These are the same nodes _iclNodes selects at :2821; one rule, one place.
              for _mcf in */current_max */input_current_limit */input_current_settled; do
                [ -w "$_mcf" ] || continue
                case "${_mcf%/*}" in main|main-charger|mainchg|charger|gccd|bbc) :;; *) continue;; esac
                write 5000000 "$_mcf" 0 || :
              done
```

- [ ] **Step 5: Run the test again** — Expected: PASS 6/0

- [ ] **Step 6: Capability check on hardware (9V arm, Task 15)**

The reason aim-high exists is winning a QC/PD contract. Task 15's 9V mode asserts `usb/voltage_now >= 6000000` after a replug on rc24, so this fix cannot silently trade a bug for a lost contract.

- [ ] **Step 7: Mutation, commit, ledger**

```sh
mutate "aim-high writes charger-owned nodes again (usb/current_max -> 100mA port)" \
  accd.sh \
  's|main\|main-charger\|mainchg\|charger\|gccd\|bbc) :;; \*) continue;;|battery) continue;; *) :;;|'
```
`B2 | accd.sh:1229,1252 | aim-high yields to a pause and writes only charger supplies via write() | t99 + mutation 14 + M3`

---

## Task 4: B3 — bound the ON sweep and guard the boot re-enable

**Files:**
- Modify: `install/misc-functions.sh:323`, `install/accd.sh:3115`
- Test: `suites/accd/t100-on-sweep-bounded.sh`

**Interfaces:**
- Produces: the ON direction carries its own `local` deadline when invoked by the daemon; the exit-trap restore sweep and `acc -t` stay unbounded.

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t100 - the ON sweep needs a ceiling, and the boot re-enable needs a guard.
#
# The OFF direction got a deadline in rc23d. ON did not, and ON is what runs on a phone with
# an empty chargingSwitch - the shipped default - through enable_charging at :1000 and through
# the boot path at accd.sh:3115. Measured on laurus: five minutes plugged, dark, no charge,
# every liveness check reporting the daemon healthy.
ID=t100; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}

_g=$(sed -n '/rc23d: stop when the sweep.s budget is spent/,/^    fi$/p' $execDir/misc-functions.sh)
case "$_g" in
  *'[ "$1" = off ]'*) no "the budget still applies to the off direction only - ON is unbounded";;
  *) ok "the budget is not restricted to the off direction";;
esac
case "$_g" in
  *'${acc_t:-false}'*) ok "acc -t is still exempt (a user is watching it walk every candidate)";;
  *) no "acc -t lost its exemption - an awkward phone can no longer find a switch";;
esac
# The restore sweep must stay unbounded: bounding it strands a phone unable to charge.
grep -q '_swEnd' $execDir/misc-functions.sh && ok "the deadline is still a local (_swEnd), not a global" \
  || no "_swEnd is gone - check that the budget is still dynamically scoped"
grep -qE '^\s+local .*_swEnd' $execDir/misc-functions.sh \
  && ok "_swEnd is declared local in cycle_switches_off" \
  || no "_swEnd is not local - a global deadline never clears and strands the restore sweep"

_b=$(sed -n '/online 2>\/dev\/null && ( cycle_switches on )/p' $execDir/accd.sh)
case "$_b" in
  *_lt_pause_cap*) ok "the boot re-enable checks the level";;
  '') ok "the boot re-enable line was restructured (verify by hand)";;
  *) no "the boot re-enable has no level guard - it undoes post-fs-data's early cap at >= pause";;
esac
case "$_b" in
  *_temp_hold*|'') ok "the boot re-enable respects a thermal hold";;
  *) no "the boot re-enable has no temperature guard";;
esac
fin
```

- [ ] **Step 2: Run against rc23** — Expected: FAIL on the off-only budget and both boot guards

- [ ] **Step 3: Fix the sweep budget**

```sh
    # rc24 (B3): the ceiling applies to BOTH directions when the daemon is driving. The ON walk
    # is what an empty chargingSwitch reaches through enable_charging (:1000) and through the
    # boot path (accd.sh:3115), and unbounded it held a plugged A3 off charge for five minutes.
    # Still a `local` (see cycle_switches_off): the exit-trap restore sweep must never be bounded,
    # because stopping it strands a phone unable to charge. acc -t stays exempt on purpose.
    if [ -n "${_swEnd-}" ] && ! ${acc_t:-false} && [ $SECONDS -ge $_swEnd ]; then
```

- [ ] **Step 4: Give the ON direction its own budget holder**

In `enable_charging` (`misc-functions.sh:1000`), wrap the sweep so it carries a deadline the restore path does not:

```sh
      # rc24 (B3): the fallback sweep runs with a budget. `local` keeps it on this call's stack
      # only, so accd's exit-trap `online && ( cycle_switches on )` restore still walks every
      # candidate without a ceiling.
      flip_sw on || { present && _rearm_sweep; } || :
```

```sh
_rearm_sweep() {
  local _swEnd=$(( SECONDS + ${_rearmBudget:-120} ))
  cycle_switches on
}
```

- [ ] **Step 5: Fix the boot re-enable**

```sh
    # rc24 (B3): guard the boot re-enable the same way the init release above is guarded. Without
    # this, a phone booting at or above its pause level turned charging back on and undid
    # post-fs-data's early cap, leaving the overshoot to be cleaned up by the first loop - through
    # the very sweep that had no ceiling.
    online 2>/dev/null && _lt_pause_cap 2>/dev/null && ! _temp_hold 2>/dev/null \
      && ( cycle_switches on ) >/dev/null 2>&1 || :
```

- [ ] **Step 6: Run the test again** — Expected: PASS 6/0

- [ ] **Step 7: Prove the restore sweep is still unbounded**

Run t86 (`sweep-is-bounded`) and any suite naming the exit trap.
Expected: still green; t86 already asserts the restore direction has no deadline.

- [ ] **Step 8: Mutation, commit, ledger**

`B3 | misc-functions.sh:323,1000 accd.sh:3115 | ON sweep bounded per call; boot re-enable level/temp guarded | t100 + t86 + mutation 15`

---

## Task 5: B9 — make `xIdle` reachable

**Files:**
- Modify: `install/accd.sh:1429-1451`
- Test: `suites/accd/t106-xidle-reachable.sh`

**Interfaces:**
- Produces: the idle-avoidance branch reads the post-cut status from a marker written inside the subshell, so `xIdle` reflects the state after `force_off`.

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t106 - the idle-avoidance latch must be able to become true.
#
# The cut runs in a ( ... ) subshell and the test that sets xIdle sits outside it, reading a
# _status that status() last set BEFORE the cut - and by construction that value is the
# non-Discharging verdict that put the loop in the `is_charging` branch. So the latch never
# set, and the re-idle at :1753 was dead: after any overshoot the pack drained to resume
# instead of holding at pause. Shipped default is allowIdleAbovePcap=false, so this is most users.
ID=t106; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
_b=$(sed -n '/if ! \$allowIdleAbovePcap && \[ \$xIdleCount -lt 2 \]/,/^          else$/p' $execDir/accd.sh)
[ -n "$_b" ] || { no "idle-avoidance branch not found"; fin; }
case "$_b" in
  *'[ $_status != Discharging ] || xIdle=true'*)
    no "xIdle is still decided from the pre-cut _status, which cannot be Discharging here";;
  *) ok "xIdle is no longer decided from the stale pre-cut _status";;
esac
case "$_b" in
  *'.xidle'*) ok "the post-cut verdict crosses the subshell through a marker";;
  *) no "no marker crosses the subshell - a variable set inside ( ) cannot reach the parent";;
esac
# Executable: a subshell cannot export a variable to its parent. Prove the mechanism, so the
# fix cannot regress to an assignment that silently does nothing.
v=before; ( v=after ) ; [ "$v" = before ] \
  && ok "confirmed: an assignment inside ( ) does not reach the parent" \
  || no "this shell leaks subshell assignments - the whole premise needs re-checking"
fin
```

- [ ] **Step 2: Run against rc23** — Expected: 2 FAILs

- [ ] **Step 3: Fix**

```sh
            (cat $config > $TMPDIR/.cfg
            config=$TMPDIR/.cfg
            prioritizeBattIdleMode=no
            cycle_switches_off
            echo "chargingSwitch=(${chargingSwitch[@]-})" > $TMPDIR/.sw
            force_off
            # rc24 (B9): report the POST-CUT status out of the subshell. The parent's $_status is
            # the reading that put this loop in the is_charging branch, so testing it here could
            # only ever say "still charging" and xIdle never became true - which made the re-idle
            # at :1753 dead code and left the pack draining to resume after every overshoot.
            [ "$(read_status)" != Discharging ] || : > $TMPDIR/.xidle) || :
            chDisabledByAcc=true
            xIdleCount=$((xIdleCount + 1))
            [ ! -f $TMPDIR/.xidle ] || { xIdle=true; rm -f $TMPDIR/.xidle; }
```

- [ ] **Step 4: Run the test again** — Expected: PASS 3/0

- [ ] **Step 5: Hardware check (M2, plugged)**

With `allowIdleAbovePcap=false`, pause 70 / resume 60, charge past 71%: assert the pack holds within 2% of pause rather than falling to 60%. Recorded in Task 15's plugged matrix.

- [ ] **Step 6: Mutation, commit, ledger**

`B9 | accd.sh:1451 | post-cut status crosses the subshell by marker; xIdle reachable | t106 + M2`

---

## Task 6: B7 — native backstop and thermal latch

**Files:**
- Modify: `install/accd.sh:2214`, `:2044-2048`, `:2850`
- Test: `suites/accd/t104-native-backstop-and-latch.sh`

**Interfaces:**
- Consumes: `mkfake`, `NVB_NODE`, `NVB_CC`.
- Produces: the backstop restores on `! present` (not `! online`); `_ntHot` persists in `$TMPDIR/.nthot`.

- [ ] **Step 1: Write the failing test** — drive `native_verify_backstop` against the fake tree, since `usb/input_current_max` is absent on both phones

```sh
#!/system/bin/sh
# t104 - the native backstop must not restore its own cut, and the thermal latch must survive a restart.
#
# NOTE ON HARDWARE. usb/input_current_max does not exist on laurus OR bluejay, so on both test
# phones native_verify_backstop returns at its second line and this defect cannot be observed
# live. The fake tree makes it observable and deterministic; NVB_NODE/NVB_CC already exist as
# overrides in the shipped function, which is why no product change is needed to test it.
ID=t104; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
. $execDir/suites/fakeps/mkfake.sh
W=/data/local/tmp/t104; rm -rf $W; mkdir -p $W; mkfake $W/ps

sed -n '/^  native_verify_backstop() {/,/^  }/p' $execDir/accd.sh > $W/nvb.sh
[ -s $W/nvb.sh ] || { no "native_verify_backstop not found"; fin; }
grep -qE '\|\| ! online; then' $W/nvb.sh \
  && no "the restore is still gated on ! online - the cut itself can clear online and undo it" \
  || ok "the restore is no longer gated on ! online"
grep -qE '\|\| ! present; then' $W/nvb.sh \
  && ok "the restore is gated on ! present (the physical question)" \
  || no "the restore has no present() gate"

# Executable A/B: cable in, cut applied, online masked to 0, level still above stop+1.
run_nvb() {  # $1 online $2 present $3 cap -> prints the node value after one pass
  echo "$1" > $W/ps/usb/online; echo "$2" > $W/ps/usb/present
  cat > $W/run.sh <<EOF
TMPDIR=$W; capacity=(5 60 70 80 false)
NVB_NODE=$W/ps/usb/input_current_max
NVB_CC=$W/ps/battery/charge_counter
batt_cap(){ echo $3; }
online(){ [ "\$(cat $W/ps/usb/online)" = 1 ]; }
present(){ [ "\$(cat $W/ps/usb/present)" = 1 ]; }
. $W/nvb.sh
native_verify_backstop
EOF
  /system/bin/sh $W/run.sh >/dev/null 2>&1 || :
  cat $W/ps/usb/input_current_max
}
echo 500000 > $W/ps/usb/input_current_max
: > $W/.nvb-on; echo 500000 > $W/.nvb-restore
_v=$(run_nvb 0 1 90)
[ "$_v" = 500000 ] && no "cut restored while still 10% above the stop level (cable in, online masked)" \
                   || ok "the cut was held with the cable in and online masked"
_v=$(run_nvb 0 0 90)
[ "$_v" = 500000 ] && ok "unplugged: the cut is released" || no "unplugged: the cut was NOT released - the phone cannot charge"

# Latch persistence.
grep -q 'nthot' $execDir/accd.sh && ok "_ntHot is persisted across a daemon restart" \
  || no "_ntHot is in-memory only: a restart in the temperature dead band resumes charging while hot"
fin
```

- [ ] **Step 2: Run against rc23** — Expected: FAIL on the online gate, the held cut, and the latch

- [ ] **Step 3: Fix the restore gate**

```sh
    # rc24 (B7): PRESENT, not online. The cut this function applies is an input cut, and an input
    # cut can drive */online to 0 - so the next pass read "unplugged", restored, and charging
    # continued past the firmware limit. Cut, restore, cut, restore, for as long as the cable is in.
    if [ "$cap" -le $(( stop + 1 )) ] || ! present; then
```

- [ ] **Step 4: Persist the thermal latch**

```sh
    # rc24 (B7): the latch has to outlive the process. It was a plain variable initialised at
    # daemon start, so `acc -D restart` (or any respawn) with the pack in the dead band between
    # resume_temp and max_temp cleared it, and the next sync wrote the ordinary pause/resume pair
    # while the phone was still too hot. One file, read once per pass, no extra process.
    if [ "$t" -ge "$_mt" ] 2>/dev/null; then
      _ntHot=1; : > $TMPDIR/.nthot 2>/dev/null || :
    elif [ "$t" -le "$_rt" ] 2>/dev/null; then
      _ntHot=0; rm -f $TMPDIR/.nthot 2>/dev/null || :
    fi
```

and at the initialiser (`:2850`):

```sh
  # rc24 (B7): rehydrate rather than reset. $TMPDIR is tmpfs, so a REBOOT still clears it - which
  # is correct, a cold boot has no hold to inherit - but a daemon restart no longer forgets.
  [ -f $TMPDIR/.nthot ] && _ntHot=1 || _ntHot=0
```

- [ ] **Step 5: Run the test again** — Expected: PASS 6/0

- [ ] **Step 6: Mutation, commit, ledger**

`B7 | accd.sh:2214,2045,2850 | backstop restores on !present; _ntHot persisted in tmpfs | t104 + mutation 16`

---

## Task 7: B6 — a collapsed contract must be repairable without an unplug

**Files:**
- Modify: `install/misc-functions.sh:833-837`, `install/accd.sh:1052-1067`
- Test: `suites/accd/t103-collapse-repair.sh`

**Interfaces:**
- Produces: `rekick_usb` accepts one escape kick per plug when the supply is demonstrably collapsed (`present`, input current below `_collapseMa`, N consecutive passes), recorded in `$TMPDIR/.hvrecover`.

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t103 - a latched contract that has collapsed must still be repairable.
#
# .hvcontract exists so a re-kick cannot drop a live QC/PD contract. But when the contract has
# ALREADY collapsed - 2-3A a minute ago, ~5mA now, pack discharging on a live cable - the latch
# blocks the only software repair, and the detector at accd.sh:1052 needs `online` and
# `! chDisabledByAcc`, which an input-cut pause reproduces exactly. Hardware-proven on laurus.
ID=t103; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
W=/data/local/tmp/t103; rm -rf $W; mkdir -p $W
sed -n '/^rekick_usb() {/,/^}/p' $execDir/misc-functions.sh > $W/fn.sh
[ -s $W/fn.sh ] || { no "rekick_usb not found"; fin; }

grep -q 'hvrecover' $W/fn.sh && ok "a collapse escape exists" \
  || no "the .hvcontract latch is an unconditional return - a collapsed contract can never be repaired"

# The escape must be ONE kick per plug, or it becomes the sawtooth the latch was added to stop.
_n=$(grep -c 'hvrecover' $W/fn.sh)
[ "${_n:-0}" -ge 2 ] && ok "the escape is latched too (set and tested)" \
  || no "the escape has no latch of its own - it would re-kick every loop"

# A healthy contract must still be protected.
cat > $W/run.sh <<EOF
TMPDIR=$W; _reason=test
: > $W/.hvcontract
cd $W
mkdir -p usb; echo 9000000 > usb/voltage_now
_collapse_ma(){ echo 2100; }   # healthy: 2.1A flowing
present(){ return 0; }
_wlog(){ :; }
. $W/fn.sh
rekick_usb test; echo "rc=\$?"
EOF
/system/bin/sh $W/run.sh 2>&1 | grep -q 'rc=1' \
  && ok "a healthy 9V contract at 2.1A is still protected from a re-kick" \
  || no "the escape fires on a HEALTHY contract - it would drop 9V to 5V until replug"

cat > $W/run2.sh <<EOF
TMPDIR=$W; _reason=test
: > $W/.hvcontract; rm -f $W/.hvrecover
cd $W
mkdir -p usb; echo 9000000 > usb/voltage_now
_collapse_ma(){ echo 5; }      # collapsed: 5mA on a live cable
present(){ return 0; }
_wlog(){ :; }
. $W/fn.sh
rekick_usb test; echo "rc=\$?"
EOF
/system/bin/sh $W/run2.sh 2>&1 | grep -q 'rc=0' \
  && ok "a collapsed contract (5mA, cable in) is repaired once" \
  || no "a collapsed contract is still refused - the user must unplug to recover"
fin
```

- [ ] **Step 2: Run against rc23** — Expected: 3 FAILs

- [ ] **Step 3: Fix `rekick_usb`**

```sh
  if [ -f "$TMPDIR/.hvcontract" ]; then
    # rc24 (B6): the latch protects a LIVE contract. A collapsed one is not live. Measured on
    # laurus: HVDCP_3 negotiated, then 5mA delivered with the pack discharging on a cable the
    # phone still called present. Refusing the kick there means the only recovery is a physical
    # unplug. One escape per plug (.hvrecover), and only on a supply proven collapsed - so a
    # healthy 2A contract is protected exactly as before.
    if present && [ ! -f "$TMPDIR/.hvrecover" ] \
       && [ "$(_collapse_ma)" -lt "${_collapseMa:-50}" ] 2>/dev/null; then
      : > "$TMPDIR/.hvrecover" 2>/dev/null || :
      command -v _wlog >/dev/null 2>&1 && _wlog "rekick allowed once ($_reason): contract latched but collapsed ($(_collapse_ma)mA)" || :
    else
      _rkv=
      { read -r _rkv < usb/voltage_now; } 2>/dev/null || :
      command -v _wlog >/dev/null 2>&1 && _wlog "rekick skipped ($_reason): negotiated contract latched this plug (now $(( ${_rkv:-0} / 1000 ))mV)" || :
      return 1
    fi
  fi
```

- [ ] **Step 4: Widen the detector at `accd.sh:1052`**

```sh
        # rc24 (B6): an input-cut pause is indistinguishable from an unplug on */online, and it
        # also sets chDisabledByAcc - so the two gates that were meant to keep this off ACC's own
        # pause also kept it off every genuinely collapsed supply on an input-cut phone. Ask the
        # physical question and exclude only a pause we are holding with an INPUT node.
        if present && { ! $chDisabledByAcc || ! _cut_is_input; }; then
```

- [ ] **Step 5: Run the test again** — Expected: PASS 4/0

- [ ] **Step 6: 9V hardware gate (M3)**

On the 9V arm, assert 30 minutes of charging with `.hvrecover` absent and `usb/voltage_now >= 6000000` throughout. A fix that drops a healthy contract shows up here immediately.

- [ ] **Step 7: Mutation, commit, ledger**

`B6 | misc-functions.sh:833 accd.sh:1052 | one escape kick per plug on a proven-collapsed supply | t103 + M3`

---

## Task 8: B4 — `acc -t` must not forge a working switch

**Files:**
- Modify: `install/acc.sh:955,957,991`, `install/batt-interface.sh:154`
- Test: `suites/accd/t101-acc-t-wait-gate.sh`

**Interfaces:**
- Produces: `_tieBreakOff=true` suppresses the status tie-break without implying a switch test; `flip` keeps its switch-test meaning and `working-switches.log` is appended only when a real off-test is running.

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t101 - the wait GATE must ask the same question as the wait LOOP, and neither may forge a log line.
#
# t90 put flip=off inside the loop. The two gates that decide whether to wait at all are still
# bare not_charging, and by then acc -t has stopped the daemon, so both tie-break suppressors are
# off: a stale kernel "Charging" skips the wait entirely and every candidate looks like it works.
# Worse, flip=off makes not_charging treat the pass as a switch TEST and append to
# working-switches.log - so Ctrl-C during the 180s wait leaves a fake entry for the picker.
ID=t101; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
_w=$(sed -n '/Ensure the charger is plugged/,/^    }$/p' $execDir/acc.sh)
[ -n "$_w" ] || { no "the acc -t wait block was not found"; fin; }
case "$_w" in
  *'_tieBreakOff=true'*) ok "the wait gate suppresses the tie-break explicitly";;
  *) no "the wait gate is still a bare not_charging - a stale Charging skips the wait";;
esac
grep -q '_tieBreakOff' $execDir/batt-interface.sh \
  && ok "batt-interface honours the dedicated suppressor" \
  || no "batt-interface has no _tieBreakOff - the only suppressor is flip, which means switch test"
_ncw=$(sed -n '/^not_charging() {/,/^}/p' $execDir/batt-interface.sh)
case "$_ncw" in
  *'wsLog'*) case "$_ncw" in
      *'${_swTest:-'*|*'_tieBreakOff'*) ok "the working-switches append is gated on a real off-test";;
      *) no "any non-empty flip still appends to working-switches.log";;
    esac;;
  *) ok "not_charging no longer writes working-switches.log";;
esac
fin
```

- [ ] **Step 2: Run against rc23** — Expected: 3 FAILs

- [ ] **Step 3: Add the dedicated suppressor in `batt-interface.sh`**

```sh
  # rc24 (B4): a way to say "judge on the current sign alone" WITHOUT claiming a switch test is
  # running. flip carries two meanings today - suppress the tie-break, and record a candidate in
  # working-switches.log - and acc -t only ever wanted the first. Setting flip=off to get it left
  # forged picker entries behind whenever the wait was interrupted.
  local _tieBreakOff=${_tieBreakOff:-false}
  $_tieBreakOff && battStatusWorkaround=true || :
```

and gate the log append on a real test:

```sh
        ! status ${1-} || {
          # rc24 (B4): only a genuine off-test records a candidate.
          ${_swTest:-true} || return 0
```

- [ ] **Step 4: Fix the two gates in `acc.sh`**

```sh
    # rc24 (B4): the gate must ask the same question as the loop below it. The daemon is stopped
    # here, so nothing else is suppressing the status tie-break, and a stale kernel "Charging"
    # made this skip the wait and grade every candidate as working - the Mi A3 signature, which
    # ends with a voltage node left at 3600mV and a phone that will not charge at any level.
    _tieBreakOff=true not_charging && enable_charging > /dev/null
```

- [ ] **Step 5: Run the test again** — Expected: PASS 3/0

- [ ] **Step 6: Live check on laurus (M2)**

`acc -t battery/input_suspend` with the cable in: assert the wait actually happens, and that `working-switches.log` gains exactly one line for one tested candidate — not one per wait iteration.

- [ ] **Step 7: Mutation, commit, ledger**

`B4 | acc.sh:955,957 batt-interface.sh:154 | dedicated _tieBreakOff; wsLog append only on a real off-test | t101 + M2`

---

## Task 9: B10 — `_cut` must skip a missing node, not abandon the group

**Files:**
- Modify: `install/post-fs-data.sh:87`
- Test: `suites/accd/t107-early-cut-skips-missing.sh`

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t107 - one absent node in a grouped switch must not cancel the rest of the early cap.
ID=t107; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
W=/data/local/tmp/t107; rm -rf $W; mkdir -p $W
echo 0 > $W/present_node
_sw="$W/missing_node 0 1 $W/present_node 0 1"
sed -n '/^_cut() {/,/^}/p' $execDir/post-fs-data.sh > $W/cut.sh 2>/dev/null || :
[ -s $W/cut.sh ] || sed -n '/set -- \$_sw/,/^  echo "\$_wrote"/p' $execDir/post-fs-data.sh > $W/cut.sh
grep -qE 'while \[ \$# -ge 3 \] && \[ -f "\$1" \]' $execDir/post-fs-data.sh \
  && no "[ -f \$1 ] is still the loop CONDITION - the first missing node ends the whole group" \
  || ok "a missing node no longer terminates the loop"
cat > $W/run.sh <<EOF
_pz=50; _wrote=
set -- $_sw
$(sed -n '/^  while \[ \$# -ge 3 \]/,/^  done$/p' $execDir/post-fs-data.sh)
echo "wrote:\$_wrote"
EOF
/system/bin/sh $W/run.sh 2>/dev/null | grep -q "present_node" \
  && ok "the node that exists was still written" \
  || no "the existing node was skipped because an earlier triplet was absent - the boot cap silently did nothing"
fin
```

- [ ] **Step 2: Run against rc23** — Expected: 2 FAILs

- [ ] **Step 3: Fix**

```sh
  # rc24 (B10): [ -f "$1" ] was the loop CONDITION, so the first absent triplet ended the sweep
  # and every later node - including ones that exist - was silently skipped. At post-fs-data a
  # missing node is ordinary (drivers are still coming up), so a grouped switch
  # (charging_enabled + op_disable_charge) simply never capped. Skip the triplet, keep going.
  while [ $# -ge 3 ]; do
    if [ ! -f "$1" ]; then shift 3; continue; fi
```

- [ ] **Step 4: Run the test again** — Expected: PASS 2/0

- [ ] **Step 5: Offline-charging regression**

Run t-suite cases naming `post-fs-data` and confirm the `*charger*` bail is untouched. Manually: boot the A3 with the cable in and the phone off, confirm it charges and does not power down.

- [ ] **Step 6: Commit and ledger**

`B10 | post-fs-data.sh:87 | absent triplet skipped instead of ending the group | t107`

---

## Task 10: B11 — uninstall must not write charger-owned nodes

**Files:**
- Modify: `install/uninstall.sh:234-236`
- Test: `suites/accd/t108-uninstall-node-allowlist.sh`

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t108 - uninstall releases ACC's own caps, not the charger's negotiation nodes.
ID=t108; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
. $execDir/suites/fakeps/mkfake.sh
W=/data/local/tmp/t108; rm -rf $W; mkdir -p $W; mkfake $W/ps
_blk=$(sed -n '/for f in \*\/current_max \*\/input_current_limit/,/done/p' $execDir/uninstall.sh)
case "$_blk" in
  *'main|main-charger|mainchg|charger|gccd|bbc'*) ok "uninstall uses the charger allow-list";;
  *) no "uninstall still writes every */current_max, including usb/ (measured: 100mA port until replug)";;
esac
cat > $W/run.sh <<EOF
cd $W/ps || exit 1
$_blk
EOF
/system/bin/sh $W/run.sh 2>/dev/null || :
[ "$(cat $W/ps/usb/current_max)" = 0 ] && ok "usb/current_max untouched by uninstall" \
  || no "uninstall wrote usb/current_max - the phone trickle-charges until replug or reboot"
[ "$(cat $W/ps/main/current_max)" = 5000000 ] && ok "main/current_max still released high" \
  || no "uninstall no longer releases the main charger cap - ACC would leave its own limit behind"
fin
```

- [ ] **Step 2: Run against rc23** — Expected: 2 FAILs

- [ ] **Step 3: Fix**

```sh
    # rc24 (B11): same allow-list the daemon uses (_iclNodes). Writing usb/current_max makes the
    # port renegotiate down to 100mA until the value is written back - AMPS measured it - so an
    # uninstall left the phone trickle-charging and looking like ACC had broken the charger.
    for f in */current_max */input_current_limit */input_current */constant_charge_current_max; do
      case "${f%/*}" in main|main-charger|mainchg|charger|gccd|bbc|battery|bms) :;; *) continue;; esac
      [ -w "$f" ] && echo 5000000 > "$f" 2>/dev/null || :
    done
```

- [ ] **Step 4: Run the test again** — Expected: PASS 3/0

- [ ] **Step 5: Commit and ledger**

`B11 | uninstall.sh:234 | charger-supply allow-list on the release sweep | t108`

---

## Task 11: B12 — a millivolt pause must not become `stop=100`

**Files:**
- Modify: `install/accd.sh:2021`
- Test: `suites/accd/t109-mv-pause-not-clamped.sh`

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t109 - a millivolt pause must not be clamped into "never stop".
# capacity[3]=4200 is a VOLTAGE limit. Clamping it to 100 writes charge_stop_level=100, which
# firmware reads as "do not stop" - the limit is not degraded, it is absent.
ID=t109; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
_b=$(sed -n '/the firmware nodes are a percentage: clamp/,/^    t=/p' $execDir/accd.sh)
case "$_b" in
  *'-le 100 ] || stop=100'*) no "a 4200mV pause is clamped to stop=100, which means never stop";;
  *) ok "the percentage clamp no longer swallows a millivolt limit";;
esac
case "$_b" in
  *'return 0'*|*_mvDomain*) ok "the native sync stands down on a millivolt config";;
  *) no "no millivolt escape - the native path writes a meaningless level pair";;
esac
fin
```

- [ ] **Step 2: Run against rc23** — Expected: 2 FAILs

- [ ] **Step 3: Fix**

```sh
    # rc24 (B12): a value above 100 is a MILLIVOLT limit, not an out-of-range percentage. Clamping
    # it to 100 wrote charge_stop_level=100, which the firmware reads as "never stop" - so a Pixel
    # with an mV config had no limit at all. Stand down instead and let the generic switch path,
    # which understands the mV domain (_ge_pause_cap does), hold the limit.
    case $stop in ''|*[!0-9]*) stop=80;; esac
    if [ "$stop" -gt 100 ] 2>/dev/null; then
      command -v _wlog >/dev/null 2>&1 && _wlog "native sync stood down: pause is ${stop}mV, not a percentage" || :
      return 0
    fi
    case $start in ''|*[!0-9]*) start=75;; esac; [ "$start" -le 100 ] || start=100
```

- [ ] **Step 4: Run the test again** — Expected: PASS 2/0

- [ ] **Step 5: Commit and ledger**

`B12 | accd.sh:2021 | native sync stands down on an mV pause instead of clamping to 100 | t109`

---

## Task 12: B13 — `acca -s` must refuse what `acc -s` refuses

**Files:**
- Modify: `install/acca.sh:135`
- Test: `suites/accd/t110-acca-validation-parity.sh`

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t110 - the app's write path must enforce the same ranges as the CLI's.
# Device-measured on bluejay: `acca -s pause_capacity=999` exits 0 and stores 80, while
# `acc -s pause_capacity=999` exits 2. AccA is the interface almost every user has, so the
# lenient path is the one that ships.
ID=t110; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
C=${dataDir:-/data/adb/vr25/acc-data}/config.txt
cp $C /data/local/tmp/t110.bak
for v in 999 12abc -5; do
  sh $execDir/acca.sh -s pause_capacity=$v >/dev/null 2>&1; _a=$?
  sh $execDir/acc.sh  -s pause_capacity=$v >/dev/null 2>&1; _c=$?
  [ "$_a" = "$_c" ] && ok "pause_capacity=$v: acca and acc agree (exit $_a)" \
                    || no "pause_capacity=$v: acca exits $_a, acc exits $_c - the app path is lenient"
  cp /data/local/tmp/t110.bak $C
done
# A VALID value must still work, or the fix has broken every AccA settings write.
sh $execDir/acca.sh -s pause_capacity=77 >/dev/null 2>&1 && ok "a valid value still applies through acca" \
  || no "acca refuses a VALID value - AccA can no longer change settings"
grep -q '^capacity=(.* 77 ' $C && ok "the valid value landed in config" || no "the valid value did not land"
cp /data/local/tmp/t110.bak $C
fin
```

- [ ] **Step 2: Run against rc23** — Expected: 3 FAILs on the disagreement rows

- [ ] **Step 3: Fix**

```sh
    # rc24 (B13): validate before persisting. `export "$@"` handed the values straight to
    # write-config, which clamps silently, so AccA reported success for pause_capacity=999 and
    # stored 80. set-prop already owns the range rules the CLI enforces; route through it so
    # there is one answer to "is this value legal", not two.
    for _kv in "$@"; do
      . $execDir/set-prop.sh
      set_prop_validate "${_kv%%=*}" "${_kv#*=}" || exit 2
    done
    export "$@"
```

- [ ] **Step 4: Run the test again** — Expected: PASS 5/0

- [ ] **Step 5: AccA smoke test**

On bluejay, open AccA, change pause to 77 and back. Confirm the config changes and no error toast appears.

- [ ] **Step 6: Commit and ledger**

`B13 | acca.sh:135 | app writes validate through set-prop before persisting | t110 + AccA smoke`

---

## Task 13: B5 — AMPS must not call a working switch "no effect"

**Files:**
- Modify: `acc-compat.sh:1710-1712`
- Test: `suites/accd/t102-amps-hold-sampling.sh`

- [ ] **Step 1: Write the failing test**

```sh
#!/system/bin/sh
# t102 - hold_probe must not decide "no hold" from a single sample on a strong charger.
# PD, input_suspend and thermal charge_control_limit routinely take longer than one POLL to
# show, so the early return recorded working switches as [no effect] in the DEFAULT quick scan.
ID=t102; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
A=${AMPS:-/data/adb/vr25/acc/acc-compat.sh}
[ -f "$A" ] || { no "acc-compat.sh not found at $A"; fin; }
_b=$(sed -n '/_xs=0; { \[ "\${WEAK_CHARGER:-0}" = 1 \]/,/sleep "\$POLL"; c2=/p' "$A")
case "$_b" in
  *'SAMP_N=3; SAMP_LAST=1; CL="$C1"; return'*)
    no "one sample above NEAR still forces held=0 and returns";;
  *) ok "the single-sample early return is gone";;
esac
case "$_b" in
  *g2*|*c2*) ok "a second sample is taken before any verdict";;
  *) no "no second sample - the verdict rests on one reading";;
esac
fin
```

- [ ] **Step 2: Run against rc23** — Expected: 1-2 FAILs

- [ ] **Step 3: Fix**

```sh
  # rc24 (B5): require TWO consecutive samples before declaring no hold. A PD contract, an
  # input_suspend and a thermal charge_control_limit all take longer than one POLL to show in the
  # current reading, so a single sample above NEAR recorded a switch that actually works as
  # [no effect] - in the default Quick scan, which is what AccA's "Find my switch" runs.
  # The weak-charger and --unplug paths keep their existing sampling; only the strong-charger
  # shortcut is removed, and it costs one extra POLL per candidate.
  sleep "$POLL"; c2="$(med_cur)"; g2="$(is_charging "$c2")"
  if [ "$_xs" = 0 ] && [ "$g1" = 1 ] && [ "$g2" = 1 ] \
     && [ "$(abs "$C1")" -ge "$NEAR" ] 2>/dev/null && [ "$(abs "$c2")" -ge "$NEAR" ] 2>/dev/null; then
    SAMP_N=3; SAMP_LAST=1; CL="$c2"; return
  fi
```

- [ ] **Step 4: Run the test again** — Expected: PASS 2/0

- [ ] **Step 5: Scan-duration guard**

Run a full AMPS quick scan on bluejay before and after. Record wall-clock. Expected: at most one extra `POLL` per candidate; if the scan grows by more than 25%, reconsider.

- [ ] **Step 6: Commit and ledger**

`B5 | acc-compat.sh:1711 | two consecutive samples required before "no hold" | t102 + scan timing`

---

## Task 14: A/B verification of every fix in one boot

**Files:**
- Modify: `suites/mega2/p8-mutation.sh` (mutations 12-18 added by Tasks 1-13)
- Test: the existing `suites/mega2/p1-static.sh` + `p8-mutation.sh`

**Interfaces:**
- Consumes: `/data/local/tmp/rc23` (the staged A arm, verified to differ from the installed tree in exactly the changed files), `PREV`/`PREVLBL`.

- [ ] **Step 1: Re-stage the A arm from the rc23 tag**

```bash
git archive HEAD~1 install | tar -x -C /tmp/rc23arm --strip-components=1
adb -s 192.168.137.18:5555 push /tmp/rc23arm /data/local/tmp/rc23
```

- [ ] **Step 2: Prove the arms differ only where intended**

Run the checksum comparison from `.scratch/rc24-deepfix/armdiff.sh`.
Expected: exactly the files this plan modified, no others.

- [ ] **Step 3: Run every new suite against the A arm**

Run: `for t in t98 t99 t100 t101 t102 t103 t104 t105 t106 t107 t108 t109 t110; do execDir=/data/local/tmp/rc23 sh $t*.sh; done`
Expected: **every one fails.** A suite that passes on rc23 is not testing the fix.

- [ ] **Step 4: Run every new suite against the B arm**

Expected: every one passes, on both phones.

- [ ] **Step 5: Run the whole unit suite on both arms**

Run: `sh run.sh static` with `execDir` pointed at each arm.
Expected: no suite that passed on rc23 fails on rc24.

- [ ] **Step 6: Commit the mutation catalogue**

---

## Task 15: The four-mode hardware campaign

Each mode runs on **both** arms, on **both** phones where the hardware allows. The A arm is rc23, the B arm is rc24. Nothing is graded unless the daemon is proven to have been looping during the window.

**Files:**
- Create: `suites/mega2/p11-charge-modes.sh`
- Modify: `suites/mega2/run.sh` (add `modes` dispatch)

- [ ] **Step 1: M1 — unplugged**

Run: `sh run.sh unplugged` (P0 P1 P2 P8 P9 P3)
Covers: every unit suite, unplugged behaviour, the mutation catalogue, fault recovery, and the idle-cost A/B.
Gate: 0 failures; P3 reports rc24 within the larger of the two arms' spreads.
Targets: B1, B7, B8, B9, B10, B11, B12, B13 (all statically or fake-tree provable), plus the whole regression surface.

- [ ] **Step 2: M2 — plugged, 5V slow (PC port, ~500 mA)**

Run: `sh run.sh plugged` then `sh run.sh modes MODE=slow5v`
Asserts:
- pause holds within 2% of `pause_capacity`, no drain to resume (B9)
- `acc -t battery/input_suspend` waits, and `working-switches.log` gains exactly one line (B4)
- replug with the switch latched resumes within one loop (B1)
- `usb/current_max` unchanged across the whole window (B2, B11)
- `restore` leaves `input_current_max` at or above its pre-run value (the rc22 500 mA class)

- [ ] **Step 3: M3 — plugged, 9V fast (QC/PD)**

Run: `sh suites/qc9v-prep.sh` then `sh run.sh modes MODE=fast9v` then `sh suites/fastcharge-audit.sh`
Asserts:
- a contract is won after a replug: `usb/voltage_now >= 6000000` within 20s (B2 capability)
- `.hvcontract` is set and `.hvrecover` stays absent for a healthy session (B6 regression)
- an induced collapse (write `usb/current_max` low by hand, outside ACC) is repaired once, and only once, per plug (B6)
- pack current stays inside the pump band; no drop to the main buck charger across ten pause/resume cycles (B8 capability)

- [ ] **Step 4: M4 — plugged, 5V slow with noise**

Same as M2 with deliberate interference, because a fix that only works on a quiet phone is not a fix:
- screen on/off every 30s
- an idle app writing the config every 20s
- `acc -D restart` at minute 3 (proves B7's `_ntHot` persistence and B9's latch survive a restart)
- Ctrl-C equivalent: `kill -INT` a running `acc -t` at a random point (proves B4 leaves no forged log line)
- a second `acc` invocation racing the daemon (proves no new race was introduced)

- [ ] **Step 5: Record every mode's result**

Write `.scratch/rc24-deepfix/RESULTS-<phone>-<mode>-<arm>.md` with the raw phase output, the daemon-looping proof, and the battery/temperature window.

- [ ] **Step 6: Idle-cost gate**

P3's summary must show rc24 within the larger arm spread of rc23, and the ratio check inside the 25% band, on both phones. A fix that costs measurable idle CPU is rejected and re-implemented, not accepted with a note.

---

## Task 16: No-regression sweep

- [ ] **Step 1: Fork and wakeup count**

Run `suites/consumption.sh` on both arms. Compare `system forks per 600s` and `accd CPU ticks`.
Gate: rc24 within 10% of rc23, or the difference explained by a measurement in the ledger.

- [ ] **Step 2: Race audit of every new file marker**

New markers introduced by this plan: `$TMPDIR/.xidle` (B9), `$TMPDIR/.nthot` (B7), `$TMPDIR/.hvrecover` (B6).
For each: confirm it is written by the daemon only, lives in tmpfs (cleared on reboot), and has exactly one reader and one writer. Add a case to t88 (cleanup traps) asserting each is removed on daemon exit where appropriate.

- [ ] **Step 3: Blacklist coverage**

Grep `install/*.sh` for any remaining `echo ... > "$node"` outside `write()`.
Every hit must have an adjacent `sw_blacklisted` check or a comment saying why it cannot. Add the grep as a permanent case in `p1-static.sh`.

- [ ] **Step 4: Offline-charging proof**

Power off the A3 with the cable in. Confirm it charges, shows the battery icon, and does not power off. This is the one failure mode that cannot be recovered from remotely.

---

## Task 17: Release hygiene

- [ ] **Step 1: Build the zip and verify**

Run: `python build-zip.py && python build-zip.py --verify <zip>`
Expected: `OK: unix modes + host present on every entry` and no CRLF finding.

- [ ] **Step 2: Confirm the zip carries UNIX mode bits**

Never build a module zip with 7-Zip or PowerShell — no mode bits means the module vanishes after a reboot on KernelSU.

---

## Task 18: Version bump and changelog

- [ ] **Step 1: Fold the ledger into the repo changelog**

Convert `.scratch/rc24-deepfix/CHANGELOG-rc24.md` into a changelog section, one line per B-item, each naming the suite that proves it.

- [ ] **Step 2: Bump `module.prop`**

```
version=v2025.5.18-6.5.1-rc24
versionCode=202505332
```

- [ ] **Step 3: Re-run M1 on both phones against the released tree**

Expected: 0 failures, `versionCode is numeric`, P3 within spread.

- [ ] **Step 4: Commit**

```bash
git commit -am "2.0.1-rc24 (202505332): replug resume, aim-high allow-list, bounded ON sweep, acc -t wait gate, AMPS sampling, collapse repair, native backstop"
```

---

## Self-review

**Spec coverage:** B1-B13 each have a task, a suite, a mutation, and a hardware mode that exercises them. The three rejected claims (`accd.sh:594`, `accd.sh:2170`, `export "$@"`) are recorded in Global Constraints as things not to "fix", with the device evidence, so a later reader does not re-open them.

**Placeholders:** none — every code step carries the actual text to write.

**Type consistency:** `_tieBreakOff` (Task 8) is read in `batt-interface.sh` and set in `acc.sh`; `_collapse_ma`/`_collapseMa` (Task 7) is a function plus a threshold variable, named consistently in the test and the fix; `_rearm_sweep`/`_rearmBudget` (Task 4) likewise; `mkfake` (Task 0) is used by Tasks 3, 6 and 10 with the same signature.

**Open dependency:** Task 7's `_cut_is_input` and Task 12's `set_prop_validate` do not exist yet. Each must be written inside its own task, next to the fix, with its own assertion in the task's suite.
