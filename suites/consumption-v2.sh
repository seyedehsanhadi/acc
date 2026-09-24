#!/system/bin/sh
# consumption-v2.sh - battery cost of each ACC build, measured so the number can be defended.
#
#   setsid sh consumption-v2.sh < /dev/null > /dev/null 2>&1 &
#   ARMS="vr25 rc24 t2410" ROUNDS=99 WINDOW=900 SETTLE=60 DEADLINE=<epoch> sh consumption-v2.sh
#
# Arms live in $ARMDIR/<arm>/ as a FULL module tree (*.sh, default-config.txt, module.prop).
# Two floor arms run every round: off and off2. Their paired difference is the rig's own noise
# (an A/A test), measured on the same phone in the same hour as the builds.
#
# What v1 got wrong, and what this version does instead:
#  1. v1 swapped only *.sh and left the previous build's tmpfs. VR25 skips its init whenever
#     $TMPDIR/.batt-interface.sh exists, so it ran on rc leftovers with no ch-switches and looped on
#     "No such file". Every arm here starts COLD: tmpfs wiped, full tree installed, own init run.
#  2. v1 slept through setup without a wakelock. `sleep` stops in suspend, so a 120 s preflight took
#     hours of wall time and the deadline was spent before round 1. Setup and settle here hold a
#     wakelock; only the measured window runs without one, and it is timed by the wall clock.
#  3. v1 trusted that an arm had landed. Here every install must prove it: versionCode, exactly one
#     daemon, CPU accrued while settling, zero error lines in its logs, and (VR25) a non-empty
#     ch-switches. A window whose arm did not land is recorded and never scored.
#
# Drain gauge: MAX1720x QH:QL coulomb counter when present (Pixel; 2000 uAh / 65536 per count),
# else bms/cc_soc scaled by charge_full (Qualcomm QG; 1/10000 of full per step), else
# charge_counter. The raw readings are written to the TSV so any window can be recomputed.

set +e
ID=consumption-v2
M=${M:-/data/adb/vr25/acc}
DD=${DD:-/data/adb/vr25/acc-data}
TD=${TD:-/dev/.vr25/acc}
PS=/sys/class/power_supply
B=$PS/battery
W=${W:-/data/local/tmp/cv2}
ARMDIR=${ARMDIR:-$W/arms}
BK=$W/backup
OUT=$W/run.txt
TSV=$W/run.tsv
LOCK=acccv2
ARMS=${ARMS:-"vr25 rc24 t2410"}
ROUNDS=${ROUNDS:-1}
WINDOW=${WINDOW:-240}
SETTLE=${SETTLE:-60}
DEADLINE=${DEADLINE:-0}
HZ=$(getconf CLK_TCK 2>/dev/null); case "${HZ:-x}" in ''|*[!0-9]*) HZ=100;; esac
NCPU=$(grep -c '^processor' /proc/cpuinfo); [ "${NCPU:-0}" -gt 0 ] || NCPU=1
DEV=$(getprop ro.product.device)

mkdir -p $W $BK
say(){ echo "$(date +%T) $*" >> $OUT; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
wl(){ echo $LOCK > /sys/power/wake_$1 2>/dev/null || :; }
screen_state(){ dumpsys power 2>/dev/null | grep -m1 -o 'mWakefulness=[A-Za-z]*' | cut -d= -f2; }
plugged(){ for _n in $PS/*/present $PS/*/online; do case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac
  [ "$(rd "$_n")" = 1 ] && return 0; done; return 1; }
dpids(){ pgrep -f "$M/accd.sh" 2>/dev/null; }
ncount(){ dpids | wc -l | tr -d ' '; }
cfgsum(){ cksum < $DD/config.txt | cut -d' ' -f1; }
modsum(){ cat $M/*.sh $M/default-config.txt $M/module.prop 2>/dev/null | cksum | cut -d' ' -f1; }

# ---- gauge -------------------------------------------------------------------------------------
GK=cc
[ -r $PS/bms/cc_soc ] && GK=ccsoc
[ -r $PS/maxfg/registers_dump ] && GK=qhql
CF=$(rd $B/charge_full); case "${CF:-x}" in ''|*[!0-9]*) CF=0;; esac
gauge(){
  case $GK in
    qhql) _d=$(cat $PS/maxfg/registers_dump 2>/dev/null)
          echo "$(echo "$_d" | sed -n 's/^4d: //p') $(echo "$_d" | sed -n 's/^4e: //p')";;
    ccsoc) echo "$(rd $PS/bms/cc_soc) $(rd $B/charge_counter)";;
    *) echo "$(rd $B/charge_counter) 0";;
  esac
}
# drained uAh between two gauge readings "$a1 $a2" "$b1 $b2" (32-bit shell arithmetic safe)
drained(){
  set -- $1 $2
  case $GK in
    qhql) _h0=$((0x$1)); _l0=$((0x$2)); _h1=$((0x$3)); _l1=$((0x$4))
          _dh=$((_h0 - _h1)); [ $_dh -lt -32768 ] && _dh=$((_dh + 65536)); [ $_dh -gt 32768 ] && _dh=$((_dh - 65536))
          _dl=$((_l0 - _l1))
          echo $(( _dh * 2000 + _dl * 2000 / 65536 ));;
    ccsoc) echo $(( ($1 - $3) * (CF / 10000) ));;
    *) echo $(( $1 - $3 ));;
  esac
}

# ---- cpu / sleep -------------------------------------------------------------------------------
tot_busy(){ set -- $(sed -n 's/^cpu0 //p' /proc/stat); _a=$(( $1+$2+$3+$4+$5+$6+$7 ))
  set -- $(sed -n 's/^cpu  *//p' /proc/stat); echo "$_a $(( $1+$2+$3+$6+$7 ))"; }
doze(){ dumpsys deviceidle get deep 2>/dev/null | head -1; }
djif(){ _t=0; for _p in $(dpids); do _l=$(cat /proc/$_p/stat 2>/dev/null) || continue; _r=${_l#*) }
  set -- $_r; _t=$(( _t + ${12:-0} + ${13:-0} + ${14:-0} + ${15:-0} )); done; echo $_t; }
susp(){ rd /sys/power/suspend_stats/success; }
forks(){ sed -n 's/^processes //p' /proc/stat; }

# ---- arm lifecycle -----------------------------------------------------------------------------
stop_all(){
  timeout -k 3 20 $M/acca.sh -D stop >/dev/null 2>&1 || :
  sleep 2
  for _p in $(dpids); do kill $_p 2>/dev/null; done; sleep 2
  for _p in $(dpids); do kill -9 $_p 2>/dev/null; done; sleep 1
}
put_tree(){
  rm -f $M/*.sh $M/default-config.txt 2>/dev/null
  cp -f $1/*.sh $1/default-config.txt $1/module.prop $M/ 2>/dev/null
  chmod 0755 $M/*.sh 2>/dev/null
}
cold_tmpfs(){ rm -rf $TD 2>/dev/null; mkdir -p $TD; }
ERE='^[^ :]*(sh|grep|cat|sed|ls|rm|mv|cp|chmod|cut|awk|tr|\])(\[[0-9]+\])?: .*(No such file|not found|syntax error|parameter not set|unexpected|bad substitution|cannot open)'
BENIGN="oem-custom.sh\[[0-9]*\]: can.t create battery_ext/smart_charging_activation"
errscan(){ cat $TD/*.log $DD/logs/init.log 2>/dev/null | grep -E "$ERE" | grep -v "$BENIGN" > $W/err-$1.txt; wc -l < $W/err-$1.txt | tr -d ' '; }

LAND=
install_arm(){
  _a=$1
  stop_all
  cp -f $BK/config.txt $DD/config.txt
  case $_a in
    off|off2) cold_tmpfs; LAND="ok"; return 0;;
  esac
  put_tree $ARMDIR/$_a
  cold_tmpfs
  : > $DD/logs/init.log 2>/dev/null
  timeout -k 3 90 sh $M/service.sh >/dev/null 2>&1
  _i=0; while [ -z "$(dpids)" ] && [ $_i -lt 60 ]; do sleep 1; _i=$((_i + 1)); done
  sleep 5
}
verify_arm(){
  _a=$1
  case $_a in
    off|off2) [ "$(ncount)" = 0 ] && LAND=ok || LAND="FAIL daemon present in floor arm"; return;;
  esac
  _why=
  _vc=$(sed -n 's/^versionCode=//p' $M/module.prop)
  [ "$_vc" = "$(sed -n 's/^versionCode=//p' $ARMDIR/$_a/module.prop)" ] || _why="$_why versionCode=$_vc"
  _n=$(ncount); [ "$_n" = 1 ] || _why="$_why daemons=$_n"
  [ "${SET_J1:-0}" -gt "${SET_J0:-0}" ] 2>/dev/null || _why="$_why no-cpu-while-settling"
  _e=$(errscan $_a); [ "${_e:-0}" = 0 ] || _why="$_why errlines=$_e"
  [ "$_a" = vr25 ] && { [ -s $TD/ch-switches ] || _why="$_why no-ch-switches"; }
  [ -z "$_why" ] && LAND="ok vc=$_vc pid=$(dpids | head -1)" || LAND="FAIL$_why"
}

restore(){
  trap - EXIT INT TERM HUP
  wl lock
  say "restore: installed build back"
  stop_all
  cp -f $BK/config.txt $DD/config.txt
  put_tree $BK/tree
  cold_tmpfs
  timeout -k 3 90 sh $M/service.sh >/dev/null 2>&1
  sleep 8
  [ "$(modsum)" = "$WANT" ] && say "restore VERIFIED vc=$(sed -n 's/^versionCode=//p' $M/module.prop) daemons=$(ncount) config=$( [ "$(cfgsum)" = "$CFGWANT" ] && echo same || echo DIFF)" \
    || say "RESTORE MISMATCH - module differs; backup at $BK/tree"
  [ "${FORCE_IDLE:-yes}" = yes ] && dumpsys deviceidle unforce >/dev/null 2>&1
  wl unlock
  say "END"
}

# ---- one window --------------------------------------------------------------------------------
measure(){
  _a=$1 _r=$2 _s=$3
  wl lock
  SET_J0=$(djif); sleep $SETTLE; SET_J1=$(djif)
  verify_arm $_a
  _g0=$(gauge); _j0=$(djif); _tb0=$(tot_busy); _su0=$(susp); _f0=$(forks); _t0=$(date +%s)
  _soc=$(rd $B/capacity); _tmp=$(rd $B/temp); _sc0=$(screen_state); _p0=$(dpids | head -1); _dz0=$(doze)
  wl unlock
  while [ $(( $(date +%s) - _t0 )) -lt $WINDOW ]; do sleep 15; done
  wl lock
  _g1=$(gauge); _j1=$(djif); _tb1=$(tot_busy); _su1=$(susp); _f1=$(forks); _t1=$(date +%s)
  _sc1=$(screen_state); _p1=$(dpids | head -1); _tmp1=$(rd $B/temp)
  _el=$(( _t1 - _t0 ))
  _v=yes; _why=
  case "$LAND" in ok*) ;; *) _v=no; _why="landing: $LAND";; esac
  case "$_sc0$_sc1" in *Awake*) _v=no; _why="$_why screen awake";; esac
  plugged && { _v=no; _why="$_why cable"; }
  case $_a in off|off2) [ -z "$_p1" ] || { _v=no; _why="$_why daemon appeared"; } ;;
    *) [ -n "$_p0" ] && [ "$_p0" = "$_p1" ] || { _v=no; _why="$_why daemon died/restarted ($_p0->$_p1)"; }
       [ $(( _j1 - _j0 )) -gt 0 ] || { _v=no; _why="$_why daemon idle-dead"; };;
  esac
  _dq=$(drained "$_g0" "$_g1")
  set -- $_tb0; _T0=$1 _B0=$2; set -- $_tb1; _T1=$1 _B1=$2
  _awake=$(( (_T1 - _T0) * 1000 / (HZ * _el) ))
  _dz="doze=$_dz0>$(doze)"
  _busy=$(( (_B1 - _B0) * 1000 / HZ * 60 / _el ))
  _cpu=$(( (_j1 - _j0) * 1000 / HZ * 60 / _el ))
  _sus=$(( ${_su1:-0} - ${_su0:-0} ))
  _fk=$(( (_f1 - _f0) * 60 / _el ))
  _ma10=$(( _dq * 36 / _el ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DEV" "$_r" "$_s" "$_a" "$_v" "$_t0" "$_el" "$_dq" "$_ma10" "$_cpu" "$_busy" "$_awake" "$_sus" "$_fk" \
    "$_soc" "$_tmp" "$_tmp1" "$GK:$_g0>$_g1 $_dz" "$LAND${_why:+ | $_why}" >> $TSV
  say "r$_r s$_s $_a valid=$_v el=${_el}s drain=${_dq}uAh (~$((_ma10 / 10)).$((_ma10 % 10))mA) cpu=${_cpu}ms/min busy=${_busy} cpu0awake=${_awake}permil susp=$_sus forks=${_fk}/min $_dz land=[$LAND]${_why:+ why=[$_why]}"
}

# ---- main --------------------------------------------------------------------------------------
: > $OUT
[ -f $TSV ] || printf 'device\tround\tslot\tarm\tvalid\tt0\telapsed_s\tdrain_uAh\tdrain_mA_x10\tdaemon_cpu_ms_min\tsys_busy_ms_min\tawake_permil\tsuspends\tforks_min\tsoc\ttemp0\ttemp1\tgauge\tland\n' > $TSV
wl lock
say "=== $ID on $DEV  arms: off off2 $ARMS  rounds=$ROUNDS window=${WINDOW}s settle=${SETTLE}s gauge=$GK cf=$CF ncpu=$NCPU hz=$HZ deadline=$DEADLINE"
[ "$(id -u)" = 0 ] || { say "ABORT not root"; exit 1; }
plugged && { say "ABORT cable attached"; exit 1; }
for _a in $ARMS; do [ -f $ARMDIR/$_a/accd.sh ] && [ -f $ARMDIR/$_a/default-config.txt ] && [ -f $ARMDIR/$_a/module.prop ] \
  || { say "ABORT incomplete tree $ARMDIR/$_a"; exit 1; }; say "arm $_a vc=$(sed -n 's/^versionCode=//p' $ARMDIR/$_a/module.prop)"; done
am force-stop mattecarra.accapp 2>/dev/null; am force-stop com.antutu.ABenchMark 2>/dev/null
[ "$(screen_state)" = Awake ] && { input keyevent 26; sleep 3; }
[ "${FORCE_IDLE:-yes}" = yes ] && dumpsys deviceidle force-idle deep >/dev/null 2>&1
say "screen=$(screen_state) soc=$(rd $B/capacity) temp=$(rd $B/temp) doze=$(doze)"

mkdir -p $BK/tree; rm -f $BK/tree/*
cp -f $M/*.sh $M/default-config.txt $M/module.prop $BK/tree/
cp -f $DD/config.txt $BK/config.txt
WANT=$(modsum); CFGWANT=$(cfgsum)
say "backup vc=$(sed -n 's/^versionCode=//p' $M/module.prop) sum=$WANT"
trap 'restore' EXIT INT TERM HUP

if [ "${WARMUP:-0}" -gt 0 ]; then
  stop_all; cp -f $BK/config.txt $DD/config.txt; cold_tmpfs
  say "warmup ${WARMUP}s, no daemon, discarded"
  wl unlock; _w0=$(date +%s); while [ $(( $(date +%s) - _w0 )) -lt $WARMUP ]; do sleep 15; done; wl lock
fi

ALL="off $ARMS off2"
r=1
while [ $r -le $ROUNDS ]; do
  N=0; for _x in $ALL; do N=$((N + 1)); done
  if [ "$DEADLINE" -gt 0 ]; then
    _need=$(( N * (WINDOW + SETTLE + 60) ))
    [ $(( $(date +%s) + _need )) -le $DEADLINE ] || { say "deadline: stopping after $((r - 1)) complete rounds"; break; }
  fi
  K=$(( (r - 1) % N )); I=0; H=; T=
  for _x in $ALL; do [ $I -lt $K ] && T="$T $_x" || H="$H $_x"; I=$((I + 1)); done
  ORDER="$H$T"
  say "--- round $r order:$ORDER"
  s=1
  for a in $ORDER; do
    plugged && { say "ABORT cable attached mid-run"; exit 1; }
    install_arm $a
    measure $a $r $s
    s=$((s + 1))
  done
  r=$((r + 1))
done
exit 0
