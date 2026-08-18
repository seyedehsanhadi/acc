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
