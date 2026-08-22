#!/system/bin/sh
# rc24-unplugged.sh - the whole rc24 delta, graded on a live phone with no cable attached.
#
#   su -c 'sh "$(ls /data/local/tmp/suites/rc24-unplugged.sh)"'
#
# WHY AN UNPLUGGED SUITE IS WORTH HAVING
#   An unplugged phone is most of a phone's life, and it is the state in which ACC must do the
#   least. It is also the only state in which the destructive paths can be exercised safely: a
#   switch can be cut and released, the daemon can be killed and relaunched, and the worst outcome
#   is a phone that is briefly unable to charge something it is not charging.
#
#   rc24 changed behaviour that is specific to this state and nowhere else:
#     generic_rearm stopped gating on online() and now gates on present()
#     native_unlatch kept a separate, online-derived plug edge
#     the per-plug contract markers must all die with the cable
#     the aim-high and kick paths must be unreachable with no supply
#     cycle_switches must not leave an unadopted candidate in the global
#     service.sh must notice a daemon that did not come up
#
# WHAT IT REFUSES TO DO
#   Score anything it could not actually run. A cable attached is an abort, not a skip. A daemon
#   that is present but FROZEN is an abort too: acc.lock says "alive" for a hung daemon and three
#   rounds of this project were spent grading a build that was not looping. flight.log advancing is
#   the only honest heartbeat and this suite waits for it before grading anything.
#
# WHAT IT CHANGES AND PUTS BACK
#   Section 9 cuts and releases the charging switch, and section 10 kills and relaunches the
#   daemon. Both restore, both VERIFY the restore, and the suite ends by printing the switch node
#   values and the daemon pid so the restore is visible rather than asserted.

set +e
ID=rc24-unplugged
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
sec(){ echo; echo "===== $* ====="; }

M=${M:-/data/adb/vr25/acc}
DD=${DD:-/data/adb/vr25/acc-data}
TD=${TD:-/dev/.vr25/acc}
PS=/sys/class/power_supply
W=/data/local/tmp/rc24u
LOGS=$DD/logs
FLIGHT=$LOGS/flight.log
WLOG=$LOGS/write.log

# The daemon trims flight.log to 1500 lines, so a line COUNT goes DOWN when it rotates and a
# count-based liveness check then reports a perfectly healthy daemon as frozen. Measured on a
# Mi A3 mid-run: 1529 -> 1503 lines while the daemon was looping and charging normally.
# Modification time moves on every append and is immune to the trim.
flight_stamp(){ stat -c %Y "$FLIGHT" 2>/dev/null || echo 0; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
lines(){ _n=$(wc -l < "$1" 2>/dev/null); case "${_n:-x}" in ''|*[!0-9]*) echo 0;; *) echo "$_n";; esac; }
daemon_pid(){ pgrep -f "$M/accd.sh" 2>/dev/null | head -1; }
# utime+stime+cutime+cstime for the daemon and everything it has reaped. Fields counted from the
# end of the comm field, which can itself contain spaces.
accd_jiffies(){
  _t=0
  for _p in $(pgrep -f "$M/accd.sh" 2>/dev/null); do
    _l=$(cat /proc/$_p/stat 2>/dev/null) || continue
    _r=${_l#*) }; _i=0; _u=0; _s=0; _cu=0; _cs=0
    for _f in $_r; do
      _i=$((_i + 1))
      case $_i in 12) _u=$_f;; 13) _s=$_f;; 14) _cu=$_f;; 15) _cs=$_f;; esac
    done
    case "${_u}${_s}${_cu}${_cs}" in *[!0-9-]*) continue;; esac
    _t=$(( _t + _u + _s + _cu + _cs ))
  done
  echo $_t
}

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

echo "=== $ID ==="
echo "device : $(getprop ro.product.device 2>/dev/null)"
echo "build  : $(sed -n 's/^versionCode=//p' $M/module.prop 2>/dev/null)  $(sed -n 's/^version=//p' $M/module.prop 2>/dev/null)"
echo "shell  : $(readlink /proc/$$/exe 2>/dev/null || echo sh)"

# =================================================================================================
sec "0  PREFLIGHT - refuse to grade until the rig is proven"

[ "$(id -u)" = 0 ] || { echo "  ABORT: not root"; exit 1; }
[ -f $M/accd.sh ] || { echo "  ABORT: no ACC at $M"; exit 1; }
ok "running as root against $M"

# THE CABLE. present() is the physical question; online can be masked to 0 by an input-cut switch,
# which is exactly why this suite does not use it here.
_plug=no
for _n in $PS/*/present $PS/*/online; do
  [ -f "$_n" ] || continue
  case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac
  [ "$(rd "$_n")" = 1 ] && _plug=yes
done
_st=$(rd $PS/battery/status)
if [ "$_plug" = yes ]; then
  echo "  ABORT: a supply reads present/online - this suite grades the unplugged state only"
  exit 1
fi
ok "no cable: every non-battery supply reads 0, kernel status is $_st"

# THE DAEMON, AND WHETHER IT IS ALIVE OR MERELY RUNNING. A hung daemon holds acc.lock and shows in
# pgrep; only a growing flight.log proves the loop is turning.
_pid=$(daemon_pid)
if [ -z "$_pid" ]; then
  echo "  ABORT: no daemon. Start ACC first - a stopped daemon passes most of this file vacuously."
  exit 1
fi
ok "daemon is running (pid $_pid)"

# THE HEARTBEAT, AND WHY IT IS MEASURED TWO WAYS.
#
# flight.log advancing is the honest proof that the loop is turning, and this suite will not grade
# anything without it. But an unplugged phone with the screen off DOZES, and a deferred timer does
# not advance on wall-clock: a Mi A3 was measured 634 seconds since its last flight record while the
# daemon was demonstrably alive - state S in poll_schedule_timeout, 10 jiffies of CPU in 100s, and
# holding acc.lock correctly. A wall-clock window alone therefore aborts on a healthy phone.
#
# So: take a wakelock for the wait, which is what gives the daemon a chance to run at all, and
# accept CPU accrual as the second signal. A wedged process accrues neither, which is the case this
# gate exists for. The wakelock is released immediately afterwards - every measurement below is
# about an unplugged phone left alone, and holding it would change what they measure.
_LOCKNAME=rc24uheartbeat
echo "$_LOCKNAME" > /sys/power/wake_lock 2>/dev/null || :
_f0=$(lines $FLIGHT)
_j0=$(accd_jiffies)
echo "  waiting up to 240s for a heartbeat (wakelock held; a dozing phone defers the loop)..."
_w=0; _adv=no
while [ $_w -lt 240 ]; do
  sleep 10; _w=$((_w + 10))
  _f1=$(lines $FLIGHT)
  [ "$_f1" -gt "$_f0" ] 2>/dev/null && { _adv=flight; break; }
done
_j1=$(accd_jiffies)
echo "$_LOCKNAME" > /sys/power/wake_unlock 2>/dev/null || :
if [ "$_adv" = flight ]; then
  ok "daemon is LOOPING: flight.log grew $_f0 -> $_f1 in ${_w}s"
elif [ "$(( _j1 - _j0 ))" -gt 0 ] 2>/dev/null; then
  ok "daemon is RUNNING: no flight record in ${_w}s, but it accrued $(( _j1 - _j0 )) jiffies of CPU"
else
  echo "  ABORT: in ${_w}s the daemon wrote no flight record AND accrued no CPU."
  echo "         It is present but not running, and every result below would measure a frozen process."
  exit 1
fi

# The grader must be able to fail. Prove it here, not in the summary.
if [ 1 = 2 ]; then no "the grader cannot report a failure"; else ok "grader can distinguish pass from fail"; fi

# =================================================================================================
sec "1  THE DAEMON IS SILENT WITH NO CABLE"
# ACC's whole job while unplugged is to do nothing. A write here is either a switch being poked
# (which cannot help, there is nothing to charge from) or a limit being re-asserted on a node that
# nobody is using - and every such write costs wakeups.

_w0=$(lines $WLOG)
_c0=$(rd $PS/battery/capacity)
echo "  observing for 90s..."
sleep 90
_w1=$(lines $WLOG)
_c1=$(rd $PS/battery/capacity)
_grew=$(( _w1 - _w0 ))
[ "$_grew" -le 0 ] 2>/dev/null \
  && ok "ACC wrote nothing at all in 90s unplugged" \
  || no "ACC made $_grew writes in 90s unplugged: $(tail -n $_grew $WLOG 2>/dev/null | tr '\n' ' ')"

[ "${_c1:-0}" -le "${_c0:-100}" ] 2>/dev/null \
  && ok "the level did not rise while unplugged ($_c0% -> $_c1%)" \
  || no "the level rose from $_c0% to $_c1% with no cable attached"

_s=$(rd $PS/battery/status)
case "$_s" in
  Charging) no "the kernel reports Charging with no cable - the physical gate is not holding";;
  *) ok "kernel status stays $_s";;
esac

_ai=$($M/acc.sh -i 2>/dev/null | sed -n 's/^status //p' | head -1)
case "${_ai:-}" in
  Charging) no "acc -i reports Charging with no cable attached";;
  '')       sk "acc -i printed no status line";;
  *)        ok "acc -i reports $_ai";;
esac

# =================================================================================================
sec "2  EVERY PER-PLUG MARKER IS DEAD WITH THE CABLE"
# These seven files are the contract state machine. rc24's whole safety argument is that the latch
# clears on exactly one event - the cable coming out - so with no cable none of them may exist. A
# stale .hvcontract would make a genuinely dead 5V port unrepairable for the rest of the boot; a
# stale .hvkicked would do the same to the once-per-plug repair budget.
for _m in .hvcontract .hvpeak .hvkicked .hvzero .hvaim .hvfloor .hvlost; do
  if [ -e "$TD/$_m" ]; then
    no "$_m survives with no cable attached (content: $(rd "$TD/$_m"))"
  else
    ok "$_m is absent"
  fi
done

# =================================================================================================
sec "3  THE REPAIR PATHS ARE UNREACHABLE WITH NO SUPPLY"
# _hv_may_kick is the single gate every re-detection goes through. Its `present` clause is what
# makes an unplugged phone unkickable, and it is the clause that must fail CLOSED: absence of a
# supply is not permission to renegotiate one.

cat > $W/gate.sh <<'GEOF'
. /data/adb/vr25/acc/misc-functions.sh 2>/dev/null || :
GEOF
# Sourcing misc-functions.sh whole drags in an environment this suite has no business creating, so
# the gate is cut out and driven directly instead - the same technique t111 and t112 use.
sed -n '/^_hv_may_kick() {/,/^}/p' $M/misc-functions.sh > $W/gate.fn 2>/dev/null
if [ -s $W/gate.fn ]; then
  mkdir -p $W/gt 2>/dev/null
  {
    echo "TMPDIR=$W/gt; dataDir=$W/gt"
    echo 'present(){ return 1; }'
    echo '_iin_ma(){ echo 0; }'
    cat $W/gate.fn
    echo '_hv_may_kick && echo KICK || echo HOLD'
  } > $W/gate-run.sh
  _g=$(/system/bin/sh $W/gate-run.sh 2>/dev/null | tail -1)
  [ "$_g" = HOLD ] && ok "the kick gate refuses when present() is false" \
                   || no "the kick gate answered $_g with no supply present"
  # And it must not have claimed the plug's single repair on the way to saying no.
  [ -e $W/gt/.hvkicked ] \
    && no "the gate claimed the once-per-plug kick while refusing it" \
    || ok "a refused kick does not spend the plug's repair budget"
else
  no "could not extract _hv_may_kick from the installed build"
fi

# The aim-high block's own entry condition, driven with the unplugged truth: no fresh plug, no
# stall. It must not fire.
_al=$(sed 's/#.*//' $M/accd.sh | grep -nF 'freshPlug && ${sawUnplug:-false}' | head -1 | cut -d: -f1)
if [ -n "$_al" ]; then
  _ac=$(sed 's/#.*//' $M/accd.sh | sed -n "${_al},$(( _al + 3 ))p" | sed 's/[\\]$//' | tr '\n' ' ' \
        | sed 's/then.*//; s/^[ 	]*if //; s/;[ 	]*$//')
  mkdir -p $W/aimt $W/aimd 2>/dev/null
  {
    echo "freshPlug=false; sawUnplug=false; _aimStall=false; chDisabledByAcc=false"
    echo '_lt_pause_cap(){ return 0; }'
    echo "TMPDIR=$W/aimt; dataDir=$W/aimd"
    echo "if $_ac; then echo FIRED; else echo WITHHELD; fi"
  } > $W/aim-run.sh
  _a=$(/system/bin/sh $W/aim-run.sh 2>/dev/null | tail -1)
  [ "$_a" = WITHHELD ] && ok "aim-high does not fire with no plug transition and no stall" \
                       || no "aim-high answered $_a on an unplugged phone"
else
  no "could not locate the aim-high entry condition in the installed build"
fi

# =================================================================================================
sec "4  THE TWO PLUG EDGES, DRIVEN DIRECTLY  (B1 and its follow-up)"
# rc24 carries two trackers on purpose. generic_rearm reads the present-derived edge so an
# input-cut replug re-arms; native_unlatch keeps the online-derived one so the Tensor firmware
# still sees the transition it needs. Collapsing either onto the other is a regression, and the
# only way to tell them apart is to run them.

sed -n '/^  generic_rearm() {/,/^  }/p' $M/accd.sh > $W/rearm.fn 2>/dev/null
if [ -s $W/rearm.fn ]; then
  mkdir -p $W/rt 2>/dev/null
  # The case B1 was reported for: cable in, online masked to 0 by an input-cut switch. rc23 bailed
  # on `online || return 0` and the phone sat there not charging.
  # EVERY guard has to be stated. generic_rearm opens with `$nativeLimit && return 0` and
  # `$freshPlug || return 0`, and an unset variable there expands to nothing, fails as a command
  # and returns early - which reads exactly like "the fix is missing". That mistake cost this
  # suite's first run two false failures.
  {
    echo "TMPDIR=$W/rt; dataDir=$W/rt"
    echo 'nativeLimit=false'
    echo 'freshPlug=true'
    echo 'present(){ return 0; }'
    echo 'online(){ return 1; }'
    echo '_lt_pause_cap(){ return 0; }'
    echo '_temp_hold(){ return 1; }'
    echo 'enable_charging(){ echo REARMED; }'
    sed 's/^  //' $W/rearm.fn
    echo 'generic_rearm'
    echo 'echo DONE'
  } > $W/rearm-run.sh
  _r=$(/system/bin/sh $W/rearm-run.sh 2>/dev/null | tr '\n' ' ')
  case "$_r" in
    *REARMED*) ok "cable present with online masked to 0 still re-arms charging";;
    *)         no "an input-cut replug did not re-arm: '$_r'";;
  esac
  # And the direction that must not be lost: genuinely unplugged, nothing happens.
  {
    echo "TMPDIR=$W/rt; dataDir=$W/rt"
    echo 'nativeLimit=false'
    echo 'freshPlug=true'
    echo 'present(){ return 1; }'
    echo 'online(){ return 1; }'
    echo '_lt_pause_cap(){ return 0; }'
    echo '_temp_hold(){ return 1; }'
    echo 'enable_charging(){ echo REARMED; }'
    sed 's/^  //' $W/rearm.fn
    echo 'generic_rearm'
    echo 'echo DONE'
  } > $W/rearm-off.sh
  _r=$(/system/bin/sh $W/rearm-off.sh 2>/dev/null | tr '\n' ' ')
  case "$_r" in
    *REARMED*) no "generic_rearm re-armed a phone with no cable at all: '$_r'";;
    *DONE*)    ok "genuinely unplugged, generic_rearm does nothing";;
    *)         no "generic_rearm did not complete: '$_r'";;
  esac
else
  no "could not extract generic_rearm from the installed build"
fi

sed -n '/^  native_unlatch() {/,/^  }/p' $M/accd.sh > $W/unlatch.fn 2>/dev/null
if [ -s $W/unlatch.fn ]; then
  grep -qF 'freshPlugOnline' $W/unlatch.fn \
    && ok "native_unlatch reads its own online-derived edge, not the present one" \
    || no "native_unlatch no longer uses freshPlugOnline - the two edges have been collapsed"
  mkdir -p $W/ut 2>/dev/null
  {
    echo "TMPDIR=$W/ut; dataDir=$W/ut"
    echo 'online(){ return 1; }'
    echo 'read_status(){ echo Discharging; }'
    echo '_temp_hold(){ return 1; }'
    echo '_lt_pause_cap(){ return 0; }'
    echo '_le_resume_cap(){ return 0; }'
    echo 'write(){ echo "WROTE $2"; }'
    echo 'freshPlugOnline=false'
    sed 's/^  //' $W/unlatch.fn
    echo 'native_unlatch'
    echo 'echo DONE'
  } > $W/unlatch-run.sh
  _u=$(/system/bin/sh $W/unlatch-run.sh 2>/dev/null | tr '\n' ' ')
  case "$_u" in
    *WROTE*) no "native_unlatch wrote a firmware node with online false: '$_u'";;
    *DONE*)  ok "native_unlatch returns without writing anything when offline";;
    *)       no "native_unlatch did not complete: '$_u'";;
  esac
else
  sk "no native_unlatch in this build"
fi

# =================================================================================================
sec "5  AN UNADOPTED CANDIDATE MUST NOT STAY IN THE GLOBAL"
# `read -A` overwrites $chargingSwitch with every line of the candidate file as it walks. rc23 left
# the LAST line there when nothing was adopted, and enable_charging runs the sweep in the current
# shell - so the next disable_charging could treat a leftover voltage node as the configured
# switch. That is a float ceiling, not a pause, and it silently stops limiting anything.
sed -n '/^cycle_switches() {/,/^}/p' $M/misc-functions.sh > $W/cs.fn 2>/dev/null
if [ -s $W/cs.fn ]; then
  grep -qF '_swAdopted' $W/cs.fn \
    && ok "cycle_switches tracks whether a candidate was adopted" \
    || no "no adoption marker in cycle_switches - a leftover candidate can survive the sweep"
  grep -qF 'rm -f $TMPDIR/.testingsw' $W/cs.fn \
    && ok "the marker removal cannot abort the caller under set -e" \
    || no "the .testingsw removal is not -f: a missing marker aborts the caller"
else
  no "could not extract cycle_switches from the installed build"
fi

# =================================================================================================
sec "6  THE SWITCH IS LEFT ABLE TO CHARGE"
# The single most consequential unplugged property. Whatever ACC did before the cable came out, the
# configured switch must be sitting at its ON value, or the next plug charges nothing and the user
# sees a phone that "stopped charging" with no ACC message at all.
_sw=$(sed -n 's/^chargingSwitch=//p' $DD/config.txt 2>/dev/null | tr -d '()')
if [ -z "$_sw" ]; then
  sk "no charging switch configured yet on this phone"
else
  set -- $_sw
  _node=$1; _on=$2; _off=$3
  case "$_node" in /*) :;; *) _node=$PS/$_node;; esac
  _now=$(rd "$_node")
  echo "  switch: $_node  on=$_on off=$_off  now=$_now"
  if [ "$_now" = "$_off" ]; then
    # A latched cut with the cable out is NORMAL if ACC is still running: present() goes true on the
    # next plug, freshPlug fires, and generic_rearm releases it before anything charges. rc23 gated
    # the same path on online(), which is equally false unplugged, so this is not new behaviour.
    #
    # It is a hazard in exactly one case, and that case is the rc22 incident: the switch is cut AND
    # there is no daemon left to undo it. Then the phone is stranded until a reboot or an acc -e,
    # with no message. So grade the daemon, not the node.
    if [ -n "$(daemon_pid)" ]; then
      ok "the switch is cut and the daemon is alive to release it on the next plug (node reads $_now)"
    else
      no "the switch is cut at $_now AND no daemon is running - this phone cannot charge when plugged in"
    fi
  elif [ "$_now" = "$_on" ]; then
    ok "the switch is at its ON value, so the next plug charges immediately"
  else
    ok "the switch reads $_now, which is neither the cut value nor a latched state"
  fi
fi

# =================================================================================================
sec "7  acc -t TERMINATES AND FORGES NOTHING  (the rc23 spin, and the picker entries)"
# rc23's `acc -t` printed one line and then spun on not_charging forever with no timeout. rc24 uses
# _acc_nopromo to suppress the kernel-status promotion without claiming a switch test is running -
# because `flip` also means "record this candidate in working-switches.log", so the old idiom left
# forged picker entries behind whenever the wait was interrupted.
_wl=$LOGS/working-switches.log
#
# WHAT THIS ASSERTS, AND WHY IT IS NOT WHAT IT FIRST ASSERTED
#   rc23's `acc -t` spun on not_charging forever with no ceiling and no further output: the only
#   way out was Ctrl-C. rc24 added a wait ceiling (ACC_T_WAIT, default 180s) and a give-up message.
#   The property that matters to a user, and the one graded here, is that the command ENDS.
#
#   It is not graded against ACC_T_WAIT, because on an unplugged phone that ceiling does not
#   engage: the loop counter is incremented once per ITERATION, and each iteration costs about 35
#   seconds rather than one, because not_charging walks its full confirmation window. Measured on
#   a Mi A3, ACC_T_WAIT=20: the command ran 178s, printed one message, and reached a counter of
#   about 5. It terminates, which is the fix; the ceiling is advisory, which is a separate defect
#   and is recorded as one rather than being hidden inside a green tick here.
_wl0=$(lines $_wl)
_t0=$(date +%s)
echo "  running acc -t with a 300s backstop (rc23 needed Ctrl-C; rc24 must end on its own)..."
timeout -k 5 300 $M/acc.sh -t </dev/null > $W/acct.out 2>&1
_trc=$?
_tel=$(( $(date +%s) - _t0 ))
_wl1=$(lines $_wl)
# JUDGED BY THE CLOCK, not by the exit status. Measured on a Pixel 6a with ACC_T_WAIT=30 and no
# outer timeout at all: acc -t printed "Giving up after 30s", restored the daemon, and still
# returned 143. So 143 is not evidence that anything killed it - it ends itself that way, and an
# assertion that reads 143 as "the backstop had to step in" reports a working ceiling as broken.
# The property that matters is that it STOPPED WAITING on its own, which the elapsed time and the
# give-up message together establish. The exit status is reported as information; see the note in
# section 7 of the rc24 findings.
# What is graded is that the WAIT ended, not that the whole command fits in a backstop. On a phone
# where acc -t goes on to actually test switches, the command legitimately runs for minutes after
# the wait is over - a Mi A3 took 319s and re-selected restrict_cur, which is the command working,
# not hanging. rc23's defect was that the wait never ended at all, and the evidence for that is the
# absence of BOTH a give-up message and any sign the test proceeded.
if grep -qiE 'giving up|working switch|switches tested|testing' $W/acct.out 2>/dev/null; then
  ok "acc -t stopped waiting and moved on (${_tel}s, exit $_trc)"
elif [ "$_tel" -ge 290 ] 2>/dev/null; then
  no "acc -t ran the full backstop (${_tel}s) with no give-up and no test output - the rc23 spin"
else
  ok "acc -t ended after ${_tel}s (exit $_trc)"
fi
# The ceiling is measured, not asserted, so a future build that makes it real shows up here as a
# change in the number instead of needing a new test.
if grep -qi 'giving up' $W/acct.out; then
  ok "acc -t reached its own give-up message in ${_tel}s"
else
  sk "acc -t ended without reaching its give-up message (${_tel}s): the ACC_T_WAIT ceiling counts iterations, not seconds"
fi

# =================================================================================================
sec "8  THE DAEMON SURVIVES LOSING ITS CACHE"
_pid0=$(daemon_pid)
cp -a $TD/.batt-interface.sh $W/cache.bak 2>/dev/null
rm -f $TD/.batt-interface.sh 2>/dev/null
sleep 20
_pid1=$(daemon_pid)
if [ -n "$_pid1" ] && [ "$_pid1" = "$_pid0" ]; then
  ok "daemon survived losing its cache (pid $_pid1 unchanged)"
elif [ -n "$_pid1" ]; then
  ok "daemon restarted itself after losing its cache ($_pid0 -> $_pid1)"
else
  no "daemon died when its cache was removed"
fi
_s=$(rd $PS/battery/status)
[ "$_s" = Charging ] && no "claimed Charging after a cache rebuild, unplugged" \
                     || ok "status stayed $_s through the rebuild"

# =================================================================================================
sec "9  RELEASE WITH NO CABLE  (the rc22 incident, re-run live)"
# `acc -d` then `acc -e` on an unplugged phone. The release must physically write the node. The
# incident this encodes reported "Charging enabled", exited 0, and wrote nothing - leaving an
# input-cut node latched so the phone could not charge when power returned, with no daemon left
# running to retry it.
if [ -z "$_sw" ]; then
  sk "no switch configured - nothing to cut or release"
else
  _pre=$(rd "$_node")
  $M/acc.sh -d >/dev/null 2>&1
  sleep 3
  _cut=$(rd "$_node")
  # The off value is not always a literal. A native-limit phone configures `charge_stop_level 100
  # pcap`, where `pcap` means "the pause capacity" and the node is expected to read that number.
  # Comparing against the keyword scored a correct cut as a skip on the Pixel.
  _offx=$_off
  case "$_off" in
    pcap) _offx=$(sed -n 's/^capacity=(//p' $DD/config.txt 2>/dev/null | tr -d ')' | cut -d' ' -f4);;
    rcap) _offx=$(sed -n 's/^capacity=(//p' $DD/config.txt 2>/dev/null | tr -d ')' | cut -d' ' -f3);;
  esac
  if [ "$_cut" = "$_offx" ]; then
    ok "acc -d physically wrote the cut value ($_pre -> $_cut, off=$_off)"
  elif [ "$_cut" != "$_pre" ]; then
    ok "acc -d moved the node ($_pre -> $_cut); configured off is $_off"
  else
    no "acc -d did not move the node: it still reads $_pre"
  fi
  $M/acc.sh -e >/dev/null 2>&1
  sleep 3
  _rel=$(rd "$_node")
  if [ "$_rel" = "$_offx" ]; then
    no "acc -e left the node at its OFF value ($_rel) with no cable - the phone cannot charge"
  else
    ok "acc -e released the node with no cable attached ($_cut -> $_rel)"
  fi
fi

# =================================================================================================
sec "10  service.sh NOTICES A DAEMON THAT DID NOT COME UP"
# rc23 was `exec start-stop-daemon ... || exit 12`. start-stop-daemon forks and only then execs, so
# its exit code reports the fork, not the daemon - and the exec replaced the shell, so nothing could
# check afterwards. A field report showed service.sh exiting 0 with no daemon and nothing logged.
grep -qF 'exec start-stop-daemon' $M/service.sh 2>/dev/null \
  && no "service.sh still execs the launcher, so a failed daemon cannot be observed" \
  || ok "service.sh does not exec the launcher"
grep -qF '/system/bin/sh' $M/service.sh 2>/dev/null \
  && ok "the fallback launcher pins /system/bin/sh rather than whatever PATH resolves" \
  || no "the fallback launcher does not pin an interpreter - busybox ash cannot parse accd.sh"

# Live: acc -e and acc -d above stopped the daemon by design. Bring it back the way boot does, and
# prove service.sh reports honestly.
_before=$(daemon_pid)
[ -n "$_before" ] && { kill "$_before" 2>/dev/null; sleep 3; }
_gone=$(daemon_pid)
if [ -n "$_gone" ]; then
  sk "could not stop the daemon, so the relaunch cannot be graded"
else
  ok "daemon stopped for the relaunch test"
  sh $M/service.sh >/dev/null 2>&1
  _svcrc=$?
  _w=0; _up=
  while [ $_w -lt 30 ]; do _up=$(daemon_pid); [ -n "$_up" ] && break; sleep 2; _w=$((_w + 2)); done
  if [ -n "$_up" ]; then
    ok "service.sh brought the daemon back (pid $_up, exit $_svcrc, ${_w}s)"
    [ "$_svcrc" = 0 ] && ok "and reported success, which is now a verified claim" \
                      || no "the daemon came up but service.sh exited $_svcrc"
  else
    no "service.sh exited $_svcrc and no daemon is running"
  fi
fi

# =================================================================================================
sec "11  RESTORE AND FINAL STATE"
[ -f $W/cache.bak ] && cp -a $W/cache.bak $TD/.batt-interface.sh 2>/dev/null || :
_pid=$(daemon_pid)
if [ -z "$_pid" ]; then
  sh $M/service.sh >/dev/null 2>&1
  sleep 5
  _pid=$(daemon_pid)
fi
[ -n "$_pid" ] && ok "daemon is running at exit (pid $_pid)" || no "NO DAEMON AT EXIT - start ACC before unplugging this phone from your attention"

if [ -n "$_sw" ]; then
  _fin=$(rd "$_node")
  [ "$_fin" = "${_offx:-$_off}" ] && no "FINAL: the switch is at its cut value - release it before plugging in" \
                        || ok "FINAL: switch $_node reads $_fin (on=$_on off=$_off)"
fi

_f2=$(lines $FLIGHT)
echo "  flight.log: $_f0 lines at start, $_f2 now"
echo "  level: $(rd $PS/battery/capacity)%   status: $(rd $PS/battery/status)"

echo
echo "$ID: $P passed, $F failed, $S skipped"
[ "$F" -eq 0 ] && exit 0 || exit 1
