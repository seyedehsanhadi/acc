#!/system/bin/sh
# t67 - set_ch_curr: the current-cap clear paths, EXECUTED.
#
# WHY THIS FILE EXISTS
#   The mega2 coverage gate graded set_ch_curr covered on the strength of the words "set_ch_curr"
#   appearing in the PROSE HEADERS of t35 and t43. Neither asserts anything about it. Once comments
#   were stripped from that search the function had nothing pointed at it, and the rc21->rc22 audit
#   independently listed its changes as high-risk and untested.
#
#   Two hazards live here, and both are races between the daemon and the user's own `acc -s`:
#     - the daemon releasing a cap the user is in the middle of setting
#     - the .mcc-custom marker being down while apply_on_plug restores the default nodes, so a
#       daemon tick re-applies a cap the user just cleared
#
# NO HARDWARE. apply_on_plug, apply_current and rekick_usb are stubbed; nothing reaches a sysfs node.

ID=t67
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
# A device that physically cannot take the path is reported as SKIP, never as a pass and never as a
# failure. A Pixel has no current-control node, so two of these cases are unreachable there.
S=0
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed$([ "${S:-0}" -gt 0 ] && echo ", $S skipped")"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SC=$execDir/set-ch-curr.sh
AWKF=$execDir/suites/xf.awk
[ -f "$SC" ] || { no "set-ch-curr.sh not found"; fin; }
[ -f "$AWKF" ] || { no "xf.awk not found at $AWKF"; fin; }

W=${TMPDIR:-/data/local/tmp}/t67-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null
xf(){ awk -v fn="$1" -f "$AWKF" "$SC"; }
[ -n "$(xf set_ch_curr)" ] || { no "could not extract set_ch_curr"; rm -rf "$W"; fin; }

# One driver, parameterised. Each case gets its own directory: the marker and the settling file are
# the whole subject here, so a leftover from the previous case would decide the next one's answer.
#   $1 dir  $2 arg  $3 settling(yes/no)  $4 config maxChargingCurrent line  $5 accdRelease  $6 notcharging(0=not charging)
run(){
  D=$W/$1; rm -rf $D; mkdir -p $D
  # Without this fixture set_ch_curr stops at its "no current control file on this device" guard and
  # never reaches the branches under test. That is device-dependent: a Pixel has no such node, so on
  # bluejay four assertions failed for the wrong reason while the same code passed on a Mi A3.
  printf '%s\n' '/sys/class/power_supply/battery/current_max::v::0' > $D/ch-curr-ctrl-files
  : > $D/.mcc-custom
  printf 'maxChargingCurrent=%s\n' "$4" > $D/config.txt
  [ "$3" = yes ] && : > $D/.mcc-settling
  # $6 INSIDE a function body is that function's own sixth argument, not run's - so this read as a
  # bare `return`, which in mksh yields whatever $? happened to be at that moment. The branch taken
  # was therefore NONDETERMINISTIC: the identical driver sent laurus down the not-charging clear and
  # bluejay down the resolved clear, and the two phones disagreed on a build that was byte-identical.
  _nc=$6
  ( TMPDIR=$D; config=$D/config.txt; LOG=$D/log; : > $LOG
    eval "$(xf set_ch_curr)"
    not_charging(){ return $_nc; }
    apply_on_plug(){ echo "apply=$1/marker=$([ -f $D/.mcc-custom ] && echo present || echo absent)" >> $LOG; }
    apply_current(){ echo "apply_current=$1" >> $LOG; return ${APPLYRC:-0}; }
    rekick_usb(){ echo "rekick=$1" >> $LOG; }
    print_curr_set(){ :; }; print_curr_restored(){ echo restored >> $LOG; }
    print_no_ctrl_file(){ :; }; print_default(){ :; }; print_mA(){ :; }; print_only(){ :; }
    set_temp_level(){ :; }
    maxChargingCurrent=(1000)
    _accdRelease=$5
    set_ch_curr "$2" >/dev/null 2>&1
    echo "rc=$? marker=$([ -f $D/.mcc-custom ] && echo present || echo absent) mcc=${maxChargingCurrent[0]-} log=$(tr '\n' ',' < $LOG)" ) 2>/dev/null
}

# ---- 1: a daemon release stands down while the CLI is settling --------------------------------------------
_o=$(run c1 - yes '(1000)' true 0)
case "$_o" in
  *marker=present*restored*) no "the daemon released the cap DURING a CLI set - marker gone and nodes restored (rc21 behaviour): $_o" ;;
  *marker=present*) ok "a daemon release stands down while a CLI set is settling: marker kept, nodes untouched" ;;
  *) no "the daemon released the cap during a CLI set: $_o" ;;
esac

# ---- 2: a daemon release consults the config ON DISK, not its loaded copy ----------------------------------
# The staleness race: the daemon holds a pre-clear config in memory while the user has already
# written a new cap. rc22 re-reads config.txt at the instant of the decision.
_o=$(run c2 - no '(700)' true 0)
case "$_o" in
  *marker=present*) ok "a daemon release aborts when the config on disk still holds a cap (700)" ;;
  *) no "the daemon released a cap that is still configured on disk - it trusted its stale in-memory copy: $_o" ;;
esac

# control: with the cap genuinely cleared on disk, the same release MUST proceed. Without this, a
# guard that always aborted would pass the assertion above.
_o=$(run c3 - no '()' true 0)
case "$_o" in
  *marker=absent*) ok "with the cap cleared on disk the daemon release proceeds (control)" ;;
  *) no "the daemon refuses to release even when the config is empty - the guard never lets go: $_o" ;;
esac

# ---- 3: the marker comes down BEFORE the nodes are restored -------------------------------------------------
# rc21 restored first and removed the marker three statements later. In that window a daemon tick saw
# the marker up and re-applied the cap the user had just cleared.
_o=$(run c4 - no '()' false 0)
case "$_o" in
  *apply=default/marker=absent*) ok "the marker is already down when apply_on_plug restores the defaults" ;;
  *apply=default/marker=present*) no "the defaults are restored while the marker is still up - a daemon tick re-applies the cleared cap (rc21 behaviour): $_o" ;;
  *) no "apply_on_plug default was not reached: $_o" ;;
esac

# ---- 4: the re-kick goes through rekick_usb ------------------------------------------------------------------
# rc21 poked the USB nodes directly. rekick_usb honours `acc -sk off`, applies the rate limit and
# writes a ledger line, none of which a direct poke does.
case "$_o" in
  *rekick=clear-*) ok "the clear's USB re-kick routes through rekick_usb, so acc -sk off and the interval apply" ;;
  *) no "the clear does not call rekick_usb - the re-kick bypasses the off switch and the rate limit: $_o" ;;
esac

# ---- 5: the marker exists BEFORE the nodes are written ------------------------------------------------
# apply_on_plug refuses to apply a current cap while the marker is absent. rc21 touched the marker
# AFTER the apply, so the very first application of a new cap ran against its own guard: the cap
# landed in config, the marker appeared, and nothing was ever written - a limit reported but not
# enforced.
#
# apply_current is defined INSIDE set_ch_curr, so it cannot be stubbed from here, and it calls
# apply_on_plug_ (trailing underscore), not apply_on_plug. Stubbing the wrong name left the real
# apply_current running against a phone-specific node list, which is why this case passed on a Mi A3
# and failed on a Pixel for reasons that had nothing to do with the behaviour under test.
numeric(){  # $1 dir  $2 apply_on_plug_ return code
  D=$W/$1; rm -rf $D; mkdir -p $D
  printf '%s
' '/sys/class/power_supply/battery/current_max::v::0' > $D/ch-curr-ctrl-files
  printf 'maxChargingCurrent=(1000)
' > $D/config.txt
  _rc=$2
  ( TMPDIR=$D; config=$D/config.txt; LOG=$D/log; : > $LOG
    eval "$(xf set_ch_curr)"
    # isAccd=false ON PURPOSE. With it true, `$isAccd || print_no_ctrl_file` short-circuits and the
    # "this device has no current control node" exit is SILENT - which read here as "the write path
    # was not reached" on a Pixel, a failure for a reason that had nothing to do with the code.
    isAccd=false
    not_charging(){ return 1; }
    # Hook apply_on_plug, NOT apply_on_plug_. Both apply_current and apply_on_plug_ are defined
    # INSIDE set_ch_curr, so a stub for either is overwritten the moment the function is eval-ed.
    # apply_on_plug_ is a thin wrapper that runs the real apply_on_plug in a subshell - that is the
    # first name the harness can own, and its return code is what the failure path reads.
    apply_on_plug(){ echo "at-apply=marker=$([ -f $D/.mcc-custom ] && echo present || echo absent)" >> $LOG; return $_rc; }
    rekick_usb(){ :; }
    print_curr_set(){ :; }; print_curr_restored(){ :; }; print_no_ctrl_file(){ echo NOCTRL >> $LOG; }
    print_default(){ :; }; print_mA(){ :; }; print_only(){ :; }; set_temp_level(){ :; }
    maxChargingCurrent=(1000); _accdRelease=false
    set_ch_curr 1000 >/dev/null 2>&1
    echo "rc=$? $(tr '
' ',' < $LOG)marker=$([ -f $D/.mcc-custom ] && echo present || echo absent)" ) 2>/dev/null
}

_o=$(numeric c6 0)
case "$_o" in
  *NOCTRL*) sk "no current-control node on this device, so the numeric cap path cannot run here (expected on Pixel and other firmware-limit phones)" ;;
  *at-apply=marker=present*) ok "the marker is up before the nodes are written, so apply_on_plug's guard permits the first write" ;;
  *at-apply=marker=absent*) no "the nodes are written with the marker down - apply_on_plug's guard blocks the first write of a new cap, so the cap is reported but never enforced (rc21 behaviour): $_o" ;;
  *) no "the write path was not reached: $_o" ;;
esac

# ---- 6: a failed apply takes the marker back down ------------------------------------------------------
# Otherwise a failure leaves apply_on_plug believing in a cap that was never written.
_o=$(numeric c7 1)
case "$_o" in
  *"rc=1 "*marker=absent) ok "a failed apply propagates rc=1 AND rolls the marker back" ;;
  *"rc=1 "*marker=present) no "a failed apply leaves the marker up - the guard believes in a cap that was never written (rc21 behaviour): $_o" ;;
  *NOCTRL*) sk "no current-control node on this device, so the failed-apply rollback cannot be exercised here" ;;
  *) no "the failing-apply case did not return 1: $_o" ;;
esac

rm -rf "$W" 2>/dev/null
fin
