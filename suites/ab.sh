#!/system/bin/sh
# ab.sh - differential regression suite: rc21 (published) against rc22 (candidate).
#
#   sh ab.sh                 run everything
#   sh ab.sh batt            one group: accd | misc | batt | curr | scan
#
# WHAT THIS IS
#   Every assertion runs the SAME code path in BOTH builds and compares the two answers. A result
#   that reads identically on rc21 and rc22 has demonstrated nothing, whatever it says, so this
#   suite reports three columns - assertion, rc21, rc22 - and the verdict is about the DIFFERENCE.
#
#   Two outcomes are failures:
#     - a fix that does not FLIP  (rc21 and rc22 agree where they should differ)
#     - a behaviour that does not HOLD (they differ where nothing was meant to change)
#
# WHY IT IS FAST
#   It does not wait for a daemon, a charger, or a battery. Each test extracts the changed function
#   from each build, evals it with stubs, and drives it with synthetic inputs. The whole suite is
#   about two minutes; the behavioural equivalent was tens of minutes per build and could only ever
#   cover what the two test phones happen to be able to reach.
#
# WHY IT IS ALSO DEEPER THAN A LIVE TEST
#   Synthetic inputs reach states no phone here can hold on demand: a half-written cache, a gauge
#   that returns nothing, a device with no usb/present node, a pause value in the millivolt domain.
#   Bug 28 lived in a branch neither test phone can execute - it was found from a reporter's logs
#   and proven this way.
#
# REQUIREMENTS
#   Both build trees on the device:
#     $ROOT/rc21/   install/ from commit 1406274
#     $ROOT/rc22/   install/ from the candidate
#   Run it under /system/bin/sh on a phone. bash on a PC does not share toybox's grep, mksh's
#   parameter expansion, or its arithmetic, and this project has been burned by each of those.
#
# SAFETY
#   Touches no sysfs node, no config, and no daemon. Everything happens on synthetic fixtures under
#   a scratch directory. It is safe to run on a charging phone, an idle phone, or no phone at all.

set -u

ROOT=${ROOT:-/data/local/tmp/ab}
AWKF=${AWKF:-$ROOT/xf.awk}
export AWKF
W=$ROOT/work
WANT=${1:-all}
DL=/sdcard/Download; [ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
OUT=$DL/ab-$(date +%Y%m%d-%H%M%S).txt
TSV=$DL/ab-$(date +%Y%m%d-%H%M%S).tsv
T0=$(date +%s)

FLIP=0; HOLD=0; BAD=0; SKIP=0
log(){ echo "$*"; echo "$*" >> "$OUT"; }
row(){ printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$TSV"; }
hdr(){ log ""; log "===== $* ====="; }

for _d in "$ROOT/rc21/install" "$ROOT/rc22/install"; do
  [ -d "$_d" ] || { echo "missing $_d - see the header for what this suite needs"; exit 1; }
done
: > "$TSV"

# ---------------------------------------------------------------------------------------------
# The primitive.
#
#   dt <id> <expect> <file> <driver>
#
# <expect> is FLIP (the builds must disagree) or HOLD (they must agree). Naming the expectation at
# the call site is the whole point: a test that cannot say which it wants is not testing anything.
#
# The driver is shell text run once per build with that build's install/ dir in $B. It prints a
# single line. Two identical lines mean the builds behave identically for that input.
#
# Stubs and fixtures live in the driver, not here, so each test states its own world.
# ---------------------------------------------------------------------------------------------
dt(){
  _id=$1; _exp=$2; _file=$3; _drv=$4
  _a=$( B="$ROOT/rc21/install" F="$_file" sh -c "$_drv" 2>/dev/null || echo "<error>" )
  _b=$( B="$ROOT/rc22/install" F="$_file" sh -c "$_drv" 2>/dev/null || echo "<error>" )
  _a=$(printf '%s' "$_a" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')
  _b=$(printf '%s' "$_b" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')
  if [ "$_exp" = FLIP ]; then
    if [ "$_a" != "$_b" ]; then
      FLIP=$((FLIP+1)); log "  FLIP  $_id"; log "          rc21: $_a"; log "          rc22: $_b"
      row "$_id" FLIP "$_a" "$_b"
    else
      BAD=$((BAD+1)); log "  SAME  $_id  <- expected a change, both builds say: $_a"
      row "$_id" NO-CHANGE "$_a" "$_b"
    fi
  else
    if [ "$_a" = "$_b" ]; then
      HOLD=$((HOLD+1)); log "  hold  $_id  ($_a)"
      row "$_id" HOLD "$_a" "$_b"
    else
      BAD=$((BAD+1)); log "  DRIFT $_id  <- expected no change"; log "          rc21: $_a"; log "          rc22: $_b"
      row "$_id" DRIFT "$_a" "$_b"
    fi
  fi
}

# Extract a function from $B/$F and define it here. Handles both top-level and 2-space-indented
# definitions, which accd.sh mixes.
# cnt: grep -c prints its count AND exits 1 when the count is zero, so the idiom
# `grep -c x f || echo 0` emits TWO lines - the count AND the echo - on no match. Every count in
# this suite goes through cnt instead. The trap is in the project notes and it still cost a run.
# through here instead. This trap is documented in the project notes and it still cost a run.
#
# xf: the definitions are inconsistent - `sdp() {` at top level, `_cache_usable(){` with no space,
# `temp_now() {` indented two spaces - so the pattern has to tolerate all three.
X='cnt(){ _c=$(grep -c "$1" "$2" 2>/dev/null); case "${_c:-}" in ""|*[!0-9]*) echo 0;; *) echo "$_c";; esac; }
 xf(){ awk -v fn="$1" -f "$AWKF" "$B/$F"; }
 fn(){ _s=$(xf "$1"); [ -n "$_s" ] || { echo "<absent>"; exit 0; }; eval "$_s"; }'

want(){ [ "$WANT" = all ] || [ "$WANT" = "$1" ]; }
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

log "=== rc21 vs rc22 differential suite ==="
log "rc21: $(sed -n 's/^versionCode=//p' $ROOT/rc21/module.prop 2>/dev/null || echo '?')"
log "rc22: $(sed -n 's/^versionCode=//p' $ROOT/rc22/module.prop 2>/dev/null || echo '?')"
log "shell: $(readlink /proc/$$/exe 2>/dev/null || echo sh)   device: $(getprop ro.product.device 2>/dev/null)"

# SELF-CHECK: prove the extractor works before trusting anything it returns.
#
# Without this the suite silently degenerates. A run where xf.awk was missing from the bundle
# returned "<absent>" for every function in BOTH builds, so all 17 FLIP assertions compared empty
# against empty and reported "no change" - a vacuous comparison, in the very suite whose entire
# purpose is to refuse vacuous comparisons. Worse, the summary still printed a verdict.
#
# idle_discharging is the canary: it is 93 lines in rc22 and present in both builds, so a short
# extract means the extractor is broken, not that the function shrank.
[ -f "$AWKF" ] || { log ""; log "ABORT: no extractor at $AWKF - every assertion would compare empty to empty"; exit 1; }
for _b in rc21 rc22; do
  _n=$(awk -v fn=idle_discharging -f "$AWKF" "$ROOT/$_b/install/batt-interface.sh" 2>/dev/null | wc -l)
  case "${_n:-0}" in ''|*[!0-9]*) _n=0;; esac
  if [ "$_n" -lt 20 ]; then
    log ""
    log "ABORT: extractor returned $_n lines for idle_discharging in $_b (expected 20+)."
    log "       Every FLIP assertion would silently pass by comparing nothing to nothing."
    exit 1
  fi
  log "extractor: $_b idle_discharging = ${_n} lines"
done

# =============================================================================================
if want batt; then
hdr "batt-interface.sh"

# bug 28 - the fuxi report. A supply reading 0 must not answer for the whole device.
dt B-present-zero FLIP batt-interface.sh "$X"'
fn present
online(){ return 0; }
present_f(){ :; }
echo 0 > '"$W"'/p1
_presentF='"$W"'/p1
present && echo plugged || echo unplugged'

# The direction that must NOT change: an input-cut switch zeroes online while the cable is in, so a
# present node reading 1 has to beat an offline reading.
dt B-present-one HOLD batt-interface.sh "$X"'
fn present
online(){ return 1; }
present_f(){ :; }
echo 1 > '"$W"'/p1
_presentF='"$W"'/p1
present && echo plugged || echo unplugged'

# Genuinely unplugged must stay unplugged, or the fallback becomes "always plugged" and the daemon
# never deep-sleeps - the standby drain this project already fixed once.
dt B-present-none HOLD batt-interface.sh "$X"'
fn present
online(){ return 1; }
present_f(){ :; }
echo 0 > '"$W"'/p1
_presentF='"$W"'/p1
present && echo plugged || echo unplugged'

# bug 3 - sdp() appended a _DPOL line per call; 18 contradictory lines were seen on one phone.
dt B-dpol-append FLIP misc-functions.sh "$X"'
fn sdp
TMPDIR='"$W"'; mkdir -p $TMPDIR
: > $TMPDIR/.batt-interface.sh
_i=0; while [ $_i -lt 5 ]; do _i=$((_i+1)); sdp - >/dev/null 2>&1 || :; done
echo "dpol-lines=$(cnt "^_DPOL=" $TMPDIR/.batt-interface.sh)"'

# bug 12/14/17 - the cache was rebuilt only when ABSENT. A zero-length or half-written file passed
# -f, so the daemon sourced an empty cache, ran blind, and acc -i answered nothing.
dt B-cache-usable FLIP batt-interface.sh "$X"'
fn _cache_usable
TMPDIR='"$W"'; mkdir -p $TMPDIR
r=""
: > $TMPDIR/.batt-interface.sh
_cache_usable 2>/dev/null && r="${r}empty=ok " || r="${r}empty=rebuild "
echo "foo=1" > $TMPDIR/.batt-interface.sh
_cache_usable 2>/dev/null && r="${r}partial=ok " || r="${r}partial=rebuild "
printf "battCapacity=4000\ncurrFile=/x\n" > $TMPDIR/.batt-interface.sh
_cache_usable 2>/dev/null && r="${r}full=ok" || r="${r}full=rebuild"
echo "$r"'
fi

# =============================================================================================
if want accd; then
hdr "accd.sh"

# bug 25 - the discovery sweep cut a healthy charge at ANY level. A fresh install at 40% with a
# pause of 80 stopped charging to find a switch it would not need for hours.
dt A-probe-due FLIP accd.sh "$X"'
fn probe_due
[ "$(type probe_due 2>/dev/null | head -1)" = "" ] && :
capacity_3=80
capacity=""
set -- ; eval "capacity=(5 101 75 80 false)" 2>/dev/null || :
r=""
for c in 40 74 75 80; do
  batt_cap(){ echo '"'"'"$c"'"'"'; }
  batt_cap(){ echo $c; }
  if probe_due 2>/dev/null; then r="${r}${c}=probe "; else r="${r}${c}=wait "; fi
done
echo "$r"'

# bug 15 - a dead temperature sensor was coerced to 25C, so the thermal limit silently vanished on
# a phone whose sensor had failed. It must report the outage instead of inventing a safe number.
dt A-temp-unreadable FLIP accd.sh "$X"'
echo "outage-logged=$(cnt "temp-sensor-unreadable" "$B/$F")"'

# bug 11 - a resume acted on a temperature read BEFORE the sleep, so a pack that had heated during
# the nap was judged on a stale figure.
dt A-temp-hold FLIP accd.sh "$X"'
fn _temp_hold
echo "exists=$(type _temp_hold >/dev/null 2>&1 && echo yes || echo no)"'

# bug 7 - native_unlatch pulsed charge_stop_level to 100, briefly allowing unrestricted charging on
# a pack that was over its temperature limit.
dt A-native-unlatch FLIP accd.sh "$X"'
fn native_unlatch
echo "pulses-100=$(xf native_unlatch | grep -c 100 || :)"'
fi

# =============================================================================================
if want misc; then
hdr "misc-functions.sh"

# bug 10/26/27 - the cap guard. rc21 had no guard at all, so a daemon holding a stale config put a
# cleared cap straight back on. rc22 gates on the marker, and the guard must cover the nodes the cap
# actually writes rather than five hardcoded names out of about twenty.
dt M-cap-guard FLIP misc-functions.sh "$X"'
echo "guard=$(cnt "mcc-custom" "$B/$F")"'

dt M-cap-guard-nodes FLIP misc-functions.sh "$X"'
_g=$(sed -n "/never APPLY a current cap once the marker is gone/,/^    fi/p" "$B/$F" 2>/dev/null)
n=0
for p in restrict_cur input_current constant_charge_current ch-curr-ctrl-files; do
  printf "%s" "$_g" | grep -q "$p" && n=$((n+1))
done
echo "covered=$n"'

# bug 13/20/30 - re-kick. Two sites bypassed the gate entirely, and two separate timestamps let it
# fire every 15-62s; the interval also moved from 30s to 300s.
dt M-rekick-gate FLIP misc-functions.sh "$X"'
echo "raw-echo-sites=$(grep -c "apsd_rerun. . && . _wlog" "$B/$F" || :) rekick_usb=$(cnt "rekick_usb" "$B/$F")"'

dt M-rekick-interval FLIP misc-functions.sh "$X"'
fn _rekick_due
echo "interval=$(xf _rekick_due | grep -oE "_rekickMinInterval:-[0-9]+" | head -1)"'

# bug 23 - a rejected discovery candidate was left latched OFF for the whole session. Below the
# pause level a cut candidate protects nothing, so it must be handed back.
dt M-reject-handback FLIP misc-functions.sh "$X"'
echo "at_or_above_pause=$(cnt "at_or_above_pause" "$B/$F")"'

fi

# =============================================================================================
if want curr; then
hdr "set-ch-curr.sh / set-ch-volt.sh / set-prop.sh"

# bug 18 - the marker was created AFTER the apply, so the very first apply ran with it missing and
# every current node was skipped: the cap landed in config and nothing was ever written.
dt C-marker-order FLIP set-ch-curr.sh "$X"'
_n=$(grep -n "touch \$f" "$B/$F" 2>/dev/null | tail -1 | cut -d: -f1)
_a=$(grep -n "apply_current \$1" "$B/$F" 2>/dev/null | tail -1 | cut -d: -f1)
case "${_n:-x}-${_a:-x}" in
  *x*) echo "order=unknown";;
  *) if [ "$_n" -lt "$_a" ]; then echo "order=marker-before-apply"; else echo "order=apply-before-marker"; fi;;
esac'

# bug 26 - `acc -s` published its config AFTER applying, so a daemon tick landing in that ~1s window
# read a config with no cap, saw the marker, concluded the user had cleared one, and ran the release
# path - deleting the marker mid-apply. The cap then showed as active in AccA and throttled almost
# nothing. `acc -s` takes no lock, so the daemon needs an explicit in-flight signal.
dt C-settling-mutex FLIP set-prop.sh "$X"'
echo "mutex=$(cnt "mcc-settling" "$B/$F")"'

# bug 19 - a voltage limit was persisted on a phone with no voltage control node, so AccA displayed
# an enforced-looking limit that nothing could ever apply.
dt C-volt-unsupported FLIP set-ch-volt.sh "$X"'
echo "probe-discriminator=$(cnt "ch-curr-ctrl-files" "$B/$F") novolt=$(cnt "No voltage control file" "$B/$F")"'
fi

# =============================================================================================
if want scan; then
hdr "acc-switch-scan.sh"

# bug 24 - restore_all_on replayed a probe-time SNAPSHOT over ACC's own release. $SW carries two
# lines for the same node and awk keeps first-occurrence order, so the snapshot came second and a
# top-to-bottom sweep made it the final value: an A3 ended a scan at 2.2A after ACC negotiated 2.8A.
dt S-sweep-filter FLIP acc-switch-scan.sh "$X"'
_r=$(sed -n "/^restore_all_on()/,/^}/p" "$B/$F" 2>/dev/null)
n=0
for p in current_max input_current constant_charge_current restrict_cur; do
  printf "%s" "$_r" | grep -q "$p" && n=$((n+1))
done
echo "filtered=$n"'

# bug 29 - the per-candidate restore had the same defect, and the rc22 fix covered only the sweep.
dt S-per-candidate FLIP acc-switch-scan.sh "$X"'
_r=$(sed -n "/^restore_on()/,/^}/p" "$B/$F" 2>/dev/null)
n=0
for p in current_max input_current constant_charge_current restrict_cur; do
  printf "%s" "$_r" | grep -q "$p" && n=$((n+1))
done
echo "filtered=$n"'
fi

# =============================================================================================
if want batt2; then
hdr "batt-interface.sh - cache, polarity, direction"

# bug 21 - the learned polarity was lost on every cache republish, so the daemon had to re-derive
# the charge direction from scratch and could pick the wrong sign while it did.
dt B-dpol-carried FLIP batt-interface.sh "$X"'
echo "dpol-in-cache-write=$(xf _cache_write | grep -c _DPOL || :)"'

# The cache must be written atomically. A half-written file is exactly the state that made the
# daemon run blind, so a non-atomic writer recreates bug 12 every time it is interrupted.
dt B-cache-atomic FLIP batt-interface.sh "$X"'
_w=$(xf _cache_write)
printf "%s" "$_w" | grep -q "mv -f" && echo "atomic=yes" || echo "atomic=no"'

# bug 12 - _cache_republish did not exist; the daemon could not heal a cache it had lost.
dt B-republish FLIP batt-interface.sh "$X"'
echo "republish=$(xf _cache_republish | grep -c . || :)"'

# bug 2 - "Charging" reported with no cable attached. The physical gate must be the LAST word, and
# it must be present, not online: an input-cut switch zeroes online while the cable is still in.
dt B-idle-present-gate FLIP batt-interface.sh "$X"'
_i=$(xf idle_discharging)
printf "%s" "$_i" | grep -q "present" && echo "present-gated=yes" || echo "present-gated=no"'

# bug 1 - the coulomb arbiter set its verdict even when the counter had not moved, so a coarse
# gauge that reported a zero delta stood down the kernel tie-break and decided direction on nothing.
dt B-ccd-zero FLIP batt-interface.sh "$X"'
_i=$(xf idle_discharging)
echo "ccd-guarded=$(printf "%s" "$_i" | grep -c "_ccd=" || :)"'

# The kernel status is stashed so a later reader sees what the arbiter actually saw, rather than
# re-reading a node that may have changed underneath it.
dt B-kstatus FLIP batt-interface.sh "$X"'
echo "kstatus=$(cnt "_kstatus" "$B/$F")"'
fi

# =============================================================================================
if want accd2; then
hdr "accd.sh - loop, limits, init"

# bug 4 - a hung daemon still held a lockfile that said "alive", and /proc agreed, so nothing
# noticed. The flight recorder is the only honest heartbeat, and it has to record every loop.
dt A-flight-rec FLIP accd.sh "$X"'
echo "flight_rec=$(cnt "flight_rec" "$B/$F")"'

# The flight recorder gained the supply contract, so a collapse is attributable after the fact
# rather than merely noticed. This is what made the curtana report diagnosable.
dt A-flight-vbus FLIP accd.sh "$X"'
_f=$(xf flight_rec)
n=0
for p in vbus icl supply; do printf "%s" "$_f" | grep -q "$p" && n=$((n+1)); done
echo "contract-fields=$n"'

# bug 5 - a native firmware limit LATCHED: the phone stayed at zero current with the limit raised
# far above the level, and only a reboot cleared it.
dt A-sync-native FLIP accd.sh "$X"'
echo "sync_native_limit=$(xf sync_native_limit | grep -c . || :)"'

# bug 6 - the thermal pause was absent BELOW the resume level, so a hot pack under the resume point
# kept charging.
dt A-generic-rearm FLIP accd.sh "$X"'
echo "generic_rearm=$(xf generic_rearm | grep -c . || :)"'

# bug 8/9 - init restore overwrote live negotiated input nodes with a probe-time snapshot, handing
# back the whole measured advantage. It must release HIGH and let the driver clamp.
dt A-init-release-high FLIP accd.sh "$X"'
echo "no-limit-configured=$(cnt "no current limit configured" "$B/$F")"'

# bug 27 - the cap marker lives in tmpfs and is wiped every boot, but the cap it stands for is
# persisted. Without a rebuild at init the first charge after every reboot ignored the cap.
dt A-marker-rebuild FLIP accd.sh "$X"'
echo "marker-rebuilt-at-init=$(grep -c "touch .TMPDIR/.mcc-custom" "$B/$F" || :)"'

# The exit trap must restore charging on every path, including an aborted install or a killed
# daemon, or a failed run leaves the phone unable to charge until reboot.
dt A-exit-trap FLIP accd.sh "$X"'
_e=$(xf exxit)
echo "exit-trap-lines=$(printf "%s" "$_e" | grep -c . || :)"'

# The daemon must not act on a config it read before a CLI set completed - the marker race.
dt A-settling-honoured FLIP accd.sh "$X"'
echo "settling-checks=$(cnt "mcc-settling" "$B/$F")"'

# A contract-collapse detector that reports and never acts. Reporting-only matters: a detector that
# tried to fix a collapse would be a second actor fighting the charger firmware.
dt A-collapse-detect FLIP accd.sh "$X"'
echo "collapse-detector=$(cnt "collapse" "$B/$F")"'
fi

# =============================================================================================
if want misc2; then
hdr "misc-functions.sh - apply, restore, switches"

# bug 16 - the scan marker was an empty file, so a SIGKILLed scan still looked live and blocked
# every later probe. rc22 writes the pid so liveness can be checked against /proc.
#
# Matching a literal $$ through two layers of shell quoting silently matched nothing and reported
# this fix as absent. Ask a question that needs no escaping: does the marker get WRITTEN or merely
# touched?
dt M-testingsw-pid FLIP misc-functions.sh "$X"'
echo "written=$(grep testingsw "$B/$F" 2>/dev/null | grep -c echo || :) touched=$(grep testingsw "$B/$F" 2>/dev/null | grep -c touch || :)"'

# bug 22 - restrict_cur was restored to its probe-time value instead of released high, leaving a
# phone throttled to 1A on a charger that had negotiated 4A.
dt M-restrict-cur FLIP misc-functions.sh "$X"'
echo "restrict_cur-in-restore=$(cnt "restrict_cur" "$B/$F")"'

# The never-lower rule: a restore may only RAISE a node back toward its default. A restore that can
# lower one is how a cleared cap left the phone slower than before it was set.
dt M-never-lower FLIP misc-functions.sh "$X"'
echo "never-lower=$(grep -ciE "never lower|never-lower|only ever raise" "$B/$F" || :)"'

# bug 23 - the reject arm. A candidate that cannot hold must be handed BACK below the pause level,
# because a cut candidate protects nothing there. Both arms must share one decision or they drift.
dt M-reject-arms FLIP misc-functions.sh "$X"'
echo "shared-helper-calls=$(cnt "at_or_above_pause || flip_sw on" "$B/$F")"'

# The sustained-hold verify: sample the signed current several times across the settle window, so a
# switch that stops current for one read and is then re-armed by firmware is rejected rather than
# locked. Judged on current only - status and online both read "stopped" on an input-cut switch.
dt M-sustained-hold HOLD misc-functions.sh "$X"'
_c=$(xf cycle_switches)
echo "chg-samples=$(printf "%s" "$_c" | grep -cE "_chg_n|_chg_last" || :)"'

# The rejection ledger: a candidate that keeps failing must not be retried forever.
dt M-reject-ledger HOLD misc-functions.sh "$X"'
echo "mccrej=$(cnt "mccrej" "$B/$F")"'

# sdp must persist the polarity where a rebuild can find it again.
dt M-dpol-persist FLIP misc-functions.sh "$X"'
_s=$(xf sdp)
printf "%s" "$_s" | grep -q "dpol" && echo "persisted=yes" || echo "persisted=no"'
fi

# =============================================================================================
if want curr2; then
hdr "set-ch-curr.sh / set-prop.sh - the cap lifecycle"

# bug 18 - a failed apply must take the marker back down, or the guard believes in a cap that was
# never written and skips every node from then on.
dt C-marker-rollback FLIP set-ch-curr.sh "$X"'
_s=$(grep -A2 "touch \$f" "$B/$F" 2>/dev/null)
printf "%s" "$_s" | grep -q "rm -f \$f" && echo "rollback=yes" || echo "rollback=no"'

# The clear path must release nodes AND drop the marker, in that order. Dropping the marker first
# makes the release a no-op, because the guard then refuses to touch the very nodes being released.
dt C-clear-order HOLD set-ch-curr.sh "$X"'
_n=$(grep -nE "rm .f$|rm -f .f$" "$B/$F" 2>/dev/null | head -1 | cut -d: -f1)
_r=$(grep -n "apply_on_plug_ default" "$B/$F" 2>/dev/null | head -1 | cut -d: -f1)
case "${_n:-x}-${_r:-x}" in *x*) echo "order=unknown";;
  *) if [ "$_n" -lt "$_r" ]; then echo "order=marker-dropped-first"; else echo "order=released-first"; fi;; esac'

# A cap outside [0-9999] must be refused AND the key dropped, or write-config clamps it to 9999 and
# persists a limit the user never asked for.
dt C-range-refusal HOLD set-ch-curr.sh "$X"'
echo "range-guard=$(cnt "0-9999" "$B/$F")"'

# The numeric test must be guarded: a non-numeric value would make [ abc -ge 0 ] error out on every
# daemon tick under set -e.
dt C-numeric-guard HOLD set-ch-curr.sh "$X"'
echo "guarded-numeric=$(grep -cE "2>/dev/null. && ..1. -le 9999" "$B/$F" || :)"'
fi

# =============================================================================================
if want scan2; then
hdr "acc-switch-scan.sh / acc.sh / diag-collect.sh"

# The scan must survive an interrupt without leaving a node pinned off. SIGKILL still skips the
# trap, which is why the daemon has its own startup recovery.
dt S-restore-trap FLIP acc-switch-scan.sh "$X"'
echo "restore_all_on-calls=$(cnt "restore_all_on" "$B/$F")"'

# The offer list must not present a candidate the scan has already rejected.
dt S-offer-list HOLD acc-switch-scan.sh "$X"'
echo "klass=$(cnt "klass" "$B/$F")"'

# The diagnostic collector gained the evidence that made the fuxi report solvable: a shutdown trace,
# last_kmsg and pstore. Without those the bundle could not distinguish a hung daemon from a blind one.
dt D-shutdown-trace FLIP diag-collect.sh "$X"'
echo "shutdown-trace=$(cnt "shutdown-trace" "$B/$F")"'

dt D-pstore FLIP diag-collect.sh "$X"'
echo "pstore=$(cnt "pstore" "$B/$F")"'

dt D-last-kmsg FLIP diag-collect.sh "$X"'
echo "last_kmsg=$(cnt "last_kmsg" "$B/$F")"'

dt D-bootreason FLIP diag-collect.sh "$X"'
echo "bootreason=$(cnt "bootreason" "$B/$F")"'
fi

# =============================================================================================
if want hold; then
hdr "invariants - these must NOT change"

# The charging switch is the overcharge guard. Nothing in this release may weaken the path that
# stops charging at the pause level; every fix here is about RELEASING correctly, never about
# holding less firmly.
dt H-disable-charging HOLD misc-functions.sh "$X"'
_d=$(xf disable_charging)
printf "%s" "$_d" | grep -q "flip_sw off" && echo "cuts=yes" || echo "cuts=no"'

# shutdown_temp must never be written by any of this.
dt H-shutdown-temp HOLD accd.sh "$X"'
echo "sd-writes=$(cnt "shutdown_temp=" "$B/$F")"'

# The pause comparison itself is untouched: a fix that quietly changed WHEN charging stops would be
# far worse than any bug in this register.
dt H-pause-compare HOLD accd.sh "$X"'
echo "body=$(xf _ge_pause_cap | tr -d " " | tr "
" "~")"'

# The offline-charging guard: never cut or power off while the phone is off and on a charger, or a
# low resume level bricks recovery.
dt H-offline-charging HOLD misc-functions.sh "$X"'
echo "offline-guard=$(grep -cE "_cut|charger mode|offline" "$B/$F" || :)"'
fi

# =============================================================================================
_el=$(( $(date +%s) - T0 ))
log ""
log "=============================================================="
log "  FLIPPED (fix demonstrated) : $FLIP"
log "  held    (no drift)         : $HOLD"
log "  PROBLEMS                   : $BAD"
log "  skipped                    : $SKIP"
log "  runtime                    : ${_el}s"
log ""
if [ "$BAD" -eq 0 ] && [ "$FLIP" -gt 0 ]; then
  log "  VERDICT: rc22 differs from rc21 on every intended fix and drifts on nothing else."
elif [ "$BAD" -gt 0 ]; then
  log "  VERDICT: $BAD assertion(s) did not behave as intended. A NO-CHANGE row means a fix is not"
  log "           in this build; a DRIFT row means something changed that was not meant to."
else
  log "  VERDICT: nothing flipped. Either the wrong trees were compared, or this build is rc21."
fi
log "  report: $OUT"
log "  table : $TSV"
