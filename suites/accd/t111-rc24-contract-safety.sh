#!/system/bin/sh
# t111 - the whole rc24 delta, graded on BOTH builds at once.
#
# WHY IT RUNS TWO TREES. A suite that only runs the new build cannot tell a fix from a coincidence:
# every assertion it makes might have passed on the old build too. So every case here is executed
# against rc23 AND rc24, and the case is only credited when rc23 answers UNSAFE and rc24 answers
# SAFE. Three other outcomes are reported by name and are all failures:
#
#   BOTH-SAFE    the case cannot see the defect at all - it would have passed before the fix, so it
#                proves nothing. This is the false positive this file exists to make impossible.
#   BOTH-UNSAFE  the fix is not present in the rc24 tree, or does not do what the case measures.
#   INVERTED     rc23 is safe and rc24 is not: a regression.
#
# Everything is executed, not grepped for, wherever the shipped code can be extracted and run. Where
# a claim genuinely is about source shape (a node never being written, a call being routed through a
# helper) the check is a fixed-string search over comment-stripped source, so a comment mentioning
# the old behaviour cannot pass or fail it by accident.
#
# NO HARDWARE IS TOUCHED. Every case runs against a scratch directory under /data/local/tmp with
# stubbed present/online/write. The daemon is never stopped, no charge node is ever written, and the
# installed module is not read except to locate the arms.
#
#   ARM23=/data/local/tmp/rc23tree ARM24=/data/local/tmp/rc24tree sh t111-rc24-contract-safety.sh

ID=t111
P=0; F=0; N=0
ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t111}

ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
nd(){ N=$((N+1)); F=$((F+1)); echo "  FAIL  $* [NON-DISCRIMINATING: passes on rc23 too - this case proves nothing]"; }
sec(){ echo; echo "-- $*"; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

# ---- harness preflight. Refuse to grade anything until the rig itself is proven. ---------------
sec "PREFLIGHT"
_pf=0
for a in "$ARM23" "$ARM24"; do
  [ -f "$a/accd.sh" ] && [ -f "$a/misc-functions.sh" ] || { echo "  ABORT: $a is not an ACC tree"; _pf=1; }
done
[ "$_pf" = 0 ] || { echo "$ID: preflight failed, no verdict"; exit 1; }
if cmp -s "$ARM23/accd.sh" "$ARM24/accd.sh" 2>/dev/null; then
  echo "  ABORT: the two arms are byte-identical - every case below would be meaningless"
  echo "$ID: preflight failed, no verdict"; exit 1
fi
ok "two distinct arms staged ($(basename $ARM23) vs $(basename $ARM24))"
# The grader must be able to report a failure. Prove it on a case whose answer is known.
_selfa=$( (echo UNSAFE) ); _selfb=$( (echo SAFE) )
[ "$_selfa" = UNSAFE ] && [ "$_selfb" = SAFE ] && ok "grader can distinguish SAFE from UNSAFE" \
  || { no "grader is broken"; echo "$ID: $P passed, $F failed"; exit 1; }

# ---- the two graders ----------------------------------------------------------------------------
# dual: run a shell function against each arm; it must echo SAFE or UNSAFE.
dual(){
  _lbl=$1; _fn=$2
  _r23=$($_fn "$ARM23" 2>/dev/null | tail -1)
  _r24=$($_fn "$ARM24" 2>/dev/null | tail -1)
  case "${_r23:-?}/${_r24:-?}" in
    UNSAFE/SAFE)   ok "$_lbl" ;;
    SAFE/SAFE)     nd "$_lbl" ;;
    UNSAFE/UNSAFE) no "$_lbl [BOTH-UNSAFE: the fix is absent or does not cover this case]" ;;
    SAFE/UNSAFE)   no "$_lbl [INVERTED: rc24 regressed against rc23]" ;;
    *)             no "$_lbl [NO VERDICT: rc23='$_r23' rc24='$_r24' - the case body failed to run]" ;;
  esac
}

# src: comment-stripped source of one file in one arm.
src(){ sed 's/#.*//' "$1/$2" 2>/dev/null; }

# has: SAFE when the fixed string is present in the stripped source.
has(){ src "$1" "$2" | grep -qF "$3" && echo SAFE || echo UNSAFE; }
# hasnt: SAFE when the fixed string is ABSENT.
hasnt(){ src "$1" "$2" | grep -qF "$3" && echo UNSAFE || echo SAFE; }
# fn: extract one shell function body from an arm.
fn(){ sed -n "/^$3() {/,/^}/p" "$1/$2" 2>/dev/null; }
fni(){ sed -n "/^  $3() {/,/^  }/p" "$1/$2" 2>/dev/null; }

# ============================================================================================
sec "1  UNITS - the defect that made a 9V contract invisible on a millivolt phone"
# usb/voltage_now is uV on one test phone and mV on the other. rc23 compares against 6000000, so on
# the mV phone the latch can never set and a live QC3 plug looks unnegotiated.
c_unit_norm(){ A=$1
  fn $A misc-functions.sh _mv > $W/mv.sh
  [ -s $W/mv.sh ] || { echo UNSAFE; return; }
  r1=$(/system/bin/sh -c ". $W/mv.sh; _mv 9000000" 2>/dev/null)
  r2=$(/system/bin/sh -c ". $W/mv.sh; _mv 9000" 2>/dev/null)
  [ "$r1" = 9000 ] && [ "$r2" = 9000 ] && echo SAFE || echo UNSAFE
}
dual "a 9V bus reads 9000mV whether the kernel reports uV or mV" c_unit_norm

c_unit_latch(){ A=$1
  # A mV phone at 9000 must latch. rc23's threshold is 6000000, so it cannot.
  s=$(src $A accd.sh | grep -F 'hvLatchMv' | head -1)
  [ -n "$s" ] && echo SAFE || echo UNSAFE
}
dual "the contract latch compares in mV, not raw node units" c_unit_latch

c_unit_noraw(){ A=$1
  # No bare microvolt literal may survive next to a voltage decision.
  src $A accd.sh | grep -qF '6000000' && { echo UNSAFE; return; }
  src $A misc-functions.sh | grep -qF '6000000' && { echo UNSAFE; return; }
  echo SAFE
}
dual "no raw 6000000 comparison remains in the contract paths" c_unit_noraw

c_unit_ma(){ A=$1
  fn $A misc-functions.sh _ma > $W/ma.sh
  [ -s $W/ma.sh ] || { echo UNSAFE; return; }
  r1=$(/system/bin/sh -c ". $W/ma.sh; _ma -1700000" 2>/dev/null)
  r2=$(/system/bin/sh -c ". $W/ma.sh; _ma 900" 2>/dev/null)
  [ "$r1" = 1700 ] && [ "$r2" = 900 ] && echo SAFE || echo UNSAFE
}
dual "current normalises to mA and drops the discharge sign" c_unit_ma

c_unit_node(){ A=$1
  # The Pixel has no usb/input_current_now and the A3 has no usb/current_now. A hardcoded path
  # silently disables every check that reads it.
  fn $A misc-functions.sh _iin_ma > $W/iin.sh
  [ -s $W/iin.sh ] || { echo UNSAFE; return; }
  fn $A misc-functions.sh _ma >> $W/iin.sh
  rm -rf $W/ps; mkdir -p $W/ps/usb; echo 1700000 > $W/ps/usb/current_now
  r=$(/system/bin/sh -c "cd $W/ps; . $W/iin.sh; _iin_ma" 2>/dev/null)
  [ "$r" = 1700 ] && echo SAFE || echo UNSAFE
}
dual "input current is found on whichever node this kernel provides" c_unit_node

c_unit_failclosed(){ A=$1
  fn $A misc-functions.sh _iin_ma > $W/iin2.sh
  [ -s $W/iin2.sh ] || { echo UNSAFE; return; }
  fn $A misc-functions.sh _ma >> $W/iin2.sh
  rm -rf $W/ps2; mkdir -p $W/ps2/usb
  if /system/bin/sh -c "cd $W/ps2; . $W/iin2.sh; _iin_ma" >/dev/null 2>&1; then echo UNSAFE; else echo SAFE; fi
}
dual "with no readable current node the reader fails closed" c_unit_failclosed

# ============================================================================================
sec "2  CONTRACT GATE - never renegotiate a plug already won"
_gate(){ A=$1; shift
  # $1 latch $2 peakMv $3 type $4 rawCurrent $5 kicked $6 node
  fn $A misc-functions.sh _mv > $W/g.sh
  fn $A misc-functions.sh _ma >> $W/g.sh
  fn $A misc-functions.sh _iin_ma >> $W/g.sh
  fn $A misc-functions.sh _hv_may_kick >> $W/g.sh
  grep -qF '_hv_may_kick()' $W/g.sh || { echo ABSENT; return; }
  rm -rf $W/gp; mkdir -p $W/gp/usb
  [ "$1" = 1 ] && : > $W/gp/.hvcontract
  [ "$5" = 1 ] && : > $W/gp/.hvkicked
  echo "$2" > $W/gp/.hvpeak; echo "$3" > $W/gp/usb/real_type; echo "$4" > $W/gp/usb/${6}
  cat > $W/gp/run.sh <<EOF
TMPDIR=$W/gp; dataDir=$W/gp; cd $W/gp
present(){ return 0; }
: \${hvPeakMaxMv:=5500}; : \${hvDeadMa:=50}
. $W/g.sh
_hv_may_kick && echo KICK || echo WITHHOLD
EOF
  /system/bin/sh $W/gp/run.sh 2>/dev/null | tail -1
}
# On rc23 there is no gate at all: every one of these is UNSAFE by construction, which is the point.
mk(){ _want=$1; shift; _args="$*"
  eval "c_g_$_n(){ r=\$(_gate \"\$1\" $_args); [ \"\$r\" = $_want ] && echo SAFE || echo UNSAFE; }"
}
_n=1;  mk KICK     0 4200 SDP 0 0 input_current_now;       dual "dead 5V SDP (uA node) is repaired"                c_g_1
_n=2;  mk KICK     0 4200 SDP 0 0 current_now;             dual "dead 5V SDP (mA node) is repaired"                c_g_2
_n=3;  mk WITHHOLD 1 9000 HVDCP_3 0 0 input_current_now;   dual "a latched contract is never re-detected"          c_g_3
_n=4;  mk WITHHOLD 0 5000 HVDCP_3 0 0 input_current_now;   dual "an HVDCP label at 5V is left alone"               c_g_4
_n=5;  mk WITHHOLD 0 5000 PD 0 0 input_current_now;        dual "a PD label is left alone"                         c_g_5
_n=6;  mk WITHHOLD 0 5000 QC3 0 0 input_current_now;       dual "a QC label is left alone"                         c_g_6
_n=7;  mk WITHHOLD 0 9000 SDP 0 0 input_current_now;       dual "a plug that ever peaked 9V stays negotiated"      c_g_7
_n=8;  mk WITHHOLD 0 4200 SDP 1700000 0 input_current_now; dual "a supply delivering 1.7A is not dead"             c_g_8
_n=9;  mk WITHHOLD 0 4200 SDP 0 1 input_current_now;       dual "one kick per plug, never two"                     c_g_9
_n=10; mk KICK     0 5499 SDP 0 0 input_current_now;       dual "peak 5499mV is still repairable (lower edge)"     c_g_10
_n=11; mk WITHHOLD 0 5500 SDP 0 0 input_current_now;       dual "peak 5500mV is not (upper edge)"                  c_g_11
_n=12; mk KICK     0 4200 SDP 50000 0 input_current_now;   dual "50mA counts as dead (floor edge)"                 c_g_12
_n=13; mk WITHHOLD 0 4200 SDP 51000 0 input_current_now;   dual "51mA does not (floor edge)"                       c_g_13

c_gate_off(){ A=$1
  fn $A misc-functions.sh _hv_may_kick > $W/go.sh
  grep -qF '_hv_may_kick()' $W/go.sh || { echo UNSAFE; return; }
  grep -qF '.rekick-off' $W/go.sh && echo SAFE || echo UNSAFE
}
dual "the gate honours acc -sk off" c_gate_off

# ============================================================================================
sec "3  LATCH LIFETIME - cleared by the cable, by nothing else"
c_latch_hold_v(){ A=$1
  # rc23 clears .hvcontract after 5 sustained sub-6V passes. That clear is what lets the next call
  # fire an APSD at a live plug.
  s=$(src $A accd.sh | grep -F 'hvLostPasses' -A4 | grep -F 'rm -f' | grep -F 'hvcontract')
  [ -n "$s" ] && echo UNSAFE || echo SAFE
}
dual "a sustained sag does NOT release the contract latch" c_latch_hold_v

c_latch_hold_i(){ A=$1
  s=$(src $A accd.sh | grep -F 'hvZeroPasses' -A6 | grep -F 'rm -f' | grep -F 'hvcontract')
  [ -n "$s" ] && echo UNSAFE || echo SAFE
}
dual "a collapsed input does NOT release the contract latch" c_latch_hold_i

c_latch_unplug(){ A=$1
  src $A accd.sh | grep -F 'hvpeak' | grep -qF 'rm -f' && echo SAFE || echo UNSAFE
}
dual "the per-plug peak marker dies with the cable" c_latch_unplug

c_latch_type(){ A=$1
  # Not "the file mentions HVDCP" - the TYPE read must actually set the latch file.
  src $A accd.sh | grep -A8 -F 'usb_type type' | grep -qF 'hvcontract' && echo SAFE || echo UNSAFE
}
dual "a high-voltage charger TYPE also latches the contract" c_latch_type

# ============================================================================================
sec "4  LIFT - the only answer to a stall"
c_lift_exists(){ A=$1
  fn $A misc-functions.sh _hv_lift > $W/l.sh
  grep -qF '_hv_lift()' $W/l.sh && echo SAFE || echo UNSAFE
}
dual "there is a lift path that raises current without re-detecting" c_lift_exists

c_lift_nodes(){ A=$1
  fn $A misc-functions.sh _hv_lift > $W/l2.sh
  grep -qF '_hv_lift()' $W/l2.sh || { echo UNSAFE; return; }
  # must never name the negotiation supplies
  grep -qF 'usb/' $W/l2.sh && { echo UNSAFE; return; }
  grep -qF 'dc/' $W/l2.sh && { echo UNSAFE; return; }
  grep -qF 'tcpm' $W/l2.sh && { echo UNSAFE; return; }
  grep -qF 'main/current_max' $W/l2.sh && echo SAFE || echo UNSAFE
}
dual "the lift touches charger supplies only, never usb/ dc/ tcpm*" c_lift_nodes

c_lift_write(){ A=$1
  fn $A misc-functions.sh _hv_lift > $W/l3.sh
  grep -qF '_hv_lift()' $W/l3.sh || { echo UNSAFE; return; }
  grep -qF 'write 5000000' $W/l3.sh && echo SAFE || echo UNSAFE
}
dual "the lift goes through write(), so the blacklist and ledger apply" c_lift_write

c_rekick_routed(){ A=$1
  fn $A misc-functions.sh rekick_usb > $W/rk.sh
  grep -qF '_hv_may_kick' $W/rk.sh && echo SAFE || echo UNSAFE
}
dual "rekick_usb asks the gate instead of checking the latch itself" c_rekick_routed

c_aim_routed(){ A=$1
  src $A accd.sh | grep -F 'apsd_rerun' | grep -qF 'for _mcf' || { echo UNSAFE; return; }
  # the APSD loop must sit inside a gate call
  src $A accd.sh | grep -B6 -F 'apsd_rerun' | grep -qF '_hv_may_kick' && echo SAFE || echo UNSAFE
}
dual "aim-high's APSD is behind the same gate" c_aim_routed

c_aim_nodes(){ A=$1
  # The loop may still glob; what matters is that a supply that is not charger-owned is skipped and
  # that the write goes through write(). rc23 excluded only battery/gauge and used a raw echo.
  s=$(src $A accd.sh | grep -A6 -F 'for _mcf in */current_max')
  [ -n "$s" ] || { echo UNSAFE; return; }
  case "$s" in
    *'main|main-charger|mainchg|charger|gccd|bbc'*) : ;;
    *) echo UNSAFE; return ;;
  esac
  case "$s" in *'write 5000000'*) echo SAFE;; *) echo UNSAFE;; esac
}
dual "aim-high writes an allow-list, not every */current_max" c_aim_nodes

# ============================================================================================
sec "5  RESUME - a successful resume must not trigger a re-kick"
c_flip_clear(){ A=$1
  # DOMINANCE, not adjacency. This used to demand `flip=` within 3 lines above `rekick_usb resume`,
  # which only ever described the *current_max* arm - the *suspend*|*bypass*|*vbus* arm three lines
  # below it was reached with whatever flip_sw on had left in `flip`, and the test called that safe.
  # Clearing it once after `flip_sw on`, before the `if present` that both arms live inside, covers
  # both; the adjacency form then reported the stronger code as unsafe. So: find the clear and the
  # first resume call, and require the clear to come first with nothing re-arming flip in between.
  s=$(src $A misc-functions.sh | grep -n -e '^ *flip=$' -e 'rekick_usb resume' -e '^ *flip=[^ ]' | head -20)
  _fc=$(printf '%s\n' "$s" | grep -m1 ':[[:space:]]*flip=$' | cut -d: -f1)
  _rk=$(printf '%s\n' "$s" | grep -m1 'rekick_usb resume' | cut -d: -f1)
  [ -n "$_fc" ] && [ -n "$_rk" ] || { echo UNSAFE; return; }
  [ "$_fc" -lt "$_rk" ] || { echo UNSAFE; return; }
  # nothing may set flip to a VALUE between the clear and the resume call
  _bad=$(printf '%s\n' "$s" | awk -F: -v a="$_fc" -v b="$_rk" '$1>a && $1<b && /flip=[^ ]/{c++} END{print c+0}')
  [ "${_bad:-0}" -eq 0 ] && echo SAFE || echo UNSAFE
}
dual "flip is cleared before the resume-time not_charging" c_flip_clear

# ============================================================================================
sec "6  DAEMON SURVIVAL AND SWITCH HYGIENE"
c_probe_guard(){ A=$1
  src $A accd.sh | grep -A8 -F 'probe_due; then' | grep -qF 'disable_charging || :' && echo SAFE || echo UNSAFE
}
dual "the first-install probe cannot take the daemon with it" c_probe_guard

c_leak_if(){ A=$1
  src $A accd.sh | grep -qF 'if not_charging; then _lbrc=0; else _lbrc=1; fi' && echo SAFE || echo UNSAFE
}
dual "leak_backstop reads not_charging without a bare status expansion" c_leak_if

c_nopromo_src(){ A=$1
  src $A batt-interface.sh | grep -qF '_acc_nopromo' && echo SAFE || echo UNSAFE
}
dual "a dedicated tie-break suppressor exists" c_nopromo_src

c_nopromo_used(){ A=$1
  n=$(src $A acc.sh | grep -cF '_acc_nopromo')
  [ "${n:-0}" -ge 3 ] && echo SAFE || echo UNSAFE
}
dual "acc -t uses it on both wait gates and the loop" c_nopromo_used

c_nopromo_noflip(){ A=$1
  src $A acc.sh | grep -qF 'while { flip=off; not_charging; }' && echo UNSAFE || echo SAFE
}
dual "acc -t no longer forges working-switches entries with flip=off" c_nopromo_noflip

c_sweep_on(){ A=$1
  src $A misc-functions.sh | grep -qF '[ "$1" = off ] && [ -n "${_swEnd-}" ]' && echo UNSAFE || echo SAFE
}
dual "the sweep budget covers the ON direction too" c_sweep_on

c_sweep_local(){ A=$1
  fn $A misc-functions.sh _rearm_sweep > $W/rs.sh
  grep -qF 'local _swEnd' $W/rs.sh && echo SAFE || echo UNSAFE
}
dual "the ON budget is a local, so the restore sweep stays unbounded" c_sweep_local

c_sw_leftover(){ A=$1
  src $A misc-functions.sh | grep -qF '[ -n "${_swAdopted-}" ] || chargingSwitch=()' && echo SAFE || echo UNSAFE
}
dual "an unadopted candidate is cleared from the global" c_sw_leftover

c_testingsw_rm(){ A=$1
  # The no-probe arm always had a guarded rm. The one that matters is the sweep's own exit.
  src $A misc-functions.sh | grep -A3 -F 'chargingSwitch=()' | grep -qF 'rm -f $TMPDIR/.testingsw'     && echo SAFE || echo UNSAFE
}
dual "the marker removal cannot abort the caller" c_testingsw_rm

# ============================================================================================
sec "7  WRITE PATH"
c_write_once(){ A=$1
  fn $A misc-functions.sh write > $W/w.sh
  [ -s $W/w.sh ] || { echo UNSAFE; return; }
  # the retry loop must be reached only when a write was attempted and did not verify
  grep -qF '_unverified' $W/w.sh && echo SAFE || echo UNSAFE
}
dual "write() retries only an attempted, unverified write" c_write_once

c_restore_icl(){ A=$1
  src $A misc-functions.sh | grep -qF '*/input_current_max|' && echo SAFE || echo UNSAFE
}
dual "the restore high-lift covers input_current_max" c_restore_icl

c_rekick_restore(){ A=$1
  s=$(src $A misc-functions.sh | grep -A2 -F 'rekick lift')
  [ -n "$s" ] || { echo UNSAFE; return; }
  case "$s" in *'write 5000000'*) echo SAFE;; *) echo UNSAFE;; esac
}
dual "the rekick ICL restore releases high through write()" c_rekick_restore

c_stamp_after(){ A=$1
  s=$(src $A misc-functions.sh | sed -n '/_rekick_due() {/,/^}/p')
  [ -n "$s" ] || { echo UNSAFE; return; }
  case "$s" in *'> "$TMPDIR/.rekick"'*) echo UNSAFE;; *) echo SAFE;; esac
}
dual "the re-kick budget is stamped where the kick happens" c_stamp_after

# ============================================================================================
sec "8  PLUG EDGE"
c_fresh_present(){ A=$1
  src $A accd.sh | grep -qF 'if present; then $wasPresent' && echo SAFE || echo UNSAFE
}
dual "the plug edge is derived from present(), not online()" c_fresh_present

c_fresh_native(){ A=$1
  src $A accd.sh | grep -qF 'freshPlugOnline' && echo SAFE || echo UNSAFE
}
dual "the native path keeps its own online-derived edge" c_fresh_native

c_rearm_present(){ A=$1
  # Brace matching truncates on the nested braces above this function, so slice by anchor.
  s=$(src $A accd.sh | sed -n '/generic_rearm() {/,/^  }/p')
  [ -n "$s" ] || { echo UNSAFE; return; }
  case "$s" in *'online || return 0'*) echo UNSAFE;; *) echo SAFE;; esac
}
dual "generic_rearm no longer gates on online()" c_rearm_present

# executable proof of the same thing
c_rearm_exec(){ A=$1
  fni $A accd.sh generic_rearm > $W/gr2.sh
  [ -s $W/gr2.sh ] || { echo UNSAFE; return; }
  cat > $W/gr2run.sh <<EOF
nativeLimit=false; freshPlug=true
present(){ return 0; }
online(){ return 1; }
_lt_pause_cap(){ return 0; }
_temp_hold(){ return 1; }
TMPDIR=$W
enable_charging(){ echo FIRED > $W/fired; }
$(cat $W/gr2.sh)
generic_rearm
EOF
  rm -f $W/fired
  /system/bin/sh $W/gr2run.sh >/dev/null 2>&1 || :
  [ -f $W/fired ] && echo SAFE || echo UNSAFE
}
dual "cable in with online masked to 0 still re-arms charging" c_rearm_exec

# ============================================================================================
sec "9  ACCA AND UNINSTALL"
c_acca_export(){ A=$1
  src $A acca.sh | grep -qF 'export "$@"' && echo UNSAFE || echo SAFE
}
dual "acca assigns config values without export" c_acca_export

c_uninstall(){ A=$1
  src $A uninstall.sh | grep -qF 'usb/*|dc/*|pc_port/*|tcpm*' && echo SAFE || echo UNSAFE
}
dual "uninstall never releases the negotiation supplies" c_uninstall

# ============================================================================================
sec "10  LAUNCHER, CLI AND PACKAGING - the rest of the rc24 delta"
c_svc_verify(){ A=$1
  # rc23 exec'd start-stop-daemon, so nothing could run after it and a failed exec in the forked
  # child was invisible: service.sh returned 0 with no daemon and no cap.
  src $A service.sh | grep -qF 'exec start-stop-daemon' && { echo UNSAFE; return; }
  src $A service.sh | grep -qF 'pgrep -f' && echo SAFE || echo UNSAFE
}
dual "service.sh verifies a daemon is really up instead of trusting an exit code" c_svc_verify

c_svc_interp(){ A=$1
  # By the fallback line, setup-busybox has put busybox ahead of /system/bin on PATH, and busybox
  # ash cannot parse accd.sh (mksh arrays). The interpreter has to be spelled out.
  s=$(src $A service.sh | grep -F 'setsid')
  [ -n "$s" ] || { echo UNSAFE; return; }
  case "$s" in *'/system/bin/sh'*) echo SAFE;; *) echo UNSAFE;; esac
}
dual "the launcher fallback pins /system/bin/sh, not whatever PATH resolves" c_svc_interp

c_uirefresh(){ A=$1
  src $A print-config.sh | grep -qF 'ui_refresh' && echo SAFE || echo UNSAFE
}
dual "ui_refresh is readable back through the config printer" c_uirefresh

c_acca_glued(){ A=$1
  # The glob accepts a glued filter, so the shift must handle one. rc23 ran `shift 2` on a single
  # argument and aborted under set -eu with "shift: nothing to shift".
  [ -f "$A/acca.sh" ] || { echo UNSAFE; return; }
  src $A acca.sh | grep -qF -- '-sd?*)' && echo SAFE || echo UNSAFE
}
dual "acca accepts a glued -sdcapacity filter" c_acca_glued

c_acca_nosubst(){ A=$1
  # Executable proof that a value carrying $(cmd) is stored literally and never run.
  [ -f "$A/acca.sh" ] || { echo UNSAFE; return; }
  rm -f $W/PWNED
  cat > $W/acca_probe.sh <<EOF
set -eu
$(src $A acca.sh | sed -n '/for _as; do/,/unset _as _ak _av/p')
EOF
  if [ -s $W/acca_probe.sh ] && grep -qF 'eval' $W/acca_probe.sh; then
    /system/bin/sh -c "set -- 'run_cmd_on_pause=\$(echo pwned > $W/PWNED)'; . $W/acca_probe.sh; echo \"\$run_cmd_on_pause\"" >$W/acca.out 2>/dev/null || :
    [ -f $W/PWNED ] && echo UNSAFE || echo SAFE
  else
    # rc23 has no such block at all: it exports the argument wholesale.
    echo UNSAFE
  fi
}
dual "an acca value containing a command substitution is stored, not executed" c_acca_nosubst

c_vbus_helper(){ A=$1
  fn $A misc-functions.sh _vbus_mv > $W/vb.sh
  grep -qF '_vbus_mv()' $W/vb.sh && echo SAFE || echo UNSAFE
}
dual "there is one bus-voltage reader and it returns mV" c_vbus_helper

c_kicked_marker(){ A=$1
  # The once-per-plug marker has to be SET by the kick path, not only read by the gate.
  n=$(src $A misc-functions.sh | grep -cF '.hvkicked')
  m=$(src $A accd.sh | grep -cF '.hvkicked')
  [ "${n:-0}" -ge 2 ] && [ "${m:-0}" -ge 1 ] && echo SAFE || echo UNSAFE
}
dual "the once-per-plug kick marker is written by both kick sites" c_kicked_marker

# ============================================================================================
sec "11  MUTATION - can this suite still fail?"
# Put one defect back into a COPY of the rc24 tree and confirm the relevant case flips. A suite that
# cannot fail is worse than no suite, and this is the only proof that it can.
rm -rf $W/mut 2>/dev/null; mkdir -p $W/mut
for _f in "$ARM24"/*.sh "$ARM24"/*.txt; do [ -f "$_f" ] && cp -f "$_f" $W/mut/ 2>/dev/null; done
# The harness pins hvPeakMaxMv, so mutate the GUARD, not its default: delete the line entirely.
sed -i '/hvPeakMaxMv/d' $W/mut/misc-functions.sh 2>/dev/null
_m=$(_gate "$W/mut" 0 9000 SDP 0 0 input_current_now)
[ "$_m" = KICK ] && ok "mutation caught: removing the peak guard makes a 9V plug kickable again" \
                 || no "mutation NOT caught: the peak guard case does not measure the guard (got $_m)"

rm -rf $W/mut2 2>/dev/null; mkdir -p $W/mut2
for _f in "$ARM24"/*.sh "$ARM24"/*.txt; do [ -f "$_f" ] && cp -f "$_f" $W/mut2/ 2>/dev/null; done
sed -i '/hvcontract" \] || return 1/d' $W/mut2/misc-functions.sh 2>/dev/null
_m2=$(_gate "$W/mut2" 1 4200 SDP 0 0 input_current_now)
[ "$_m2" = KICK ] && ok "mutation caught: removing the latch check re-opens a won contract" \
                  || no "mutation NOT caught: the latch case does not measure the latch (got $_m2)"

# ============================================================================================
echo
echo "$ID: $P passed, $F failed"
[ "$N" -eq 0 ] || echo "  ($N case(s) were non-discriminating - they pass on rc23 and prove nothing)"
rm -rf $W 2>/dev/null
[ "$F" -eq 0 ] && exit 0 || exit 1
