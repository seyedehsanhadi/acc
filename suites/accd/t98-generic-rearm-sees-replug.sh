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
# grep -F (fixed string) on purpose: toybox grep has no \s and no \| in -E mode, so a plain
# substring match is the only thing guaranteed to work identically on both test phones.
# Comment lines are stripped first: the rc24 fix comment quotes the old `online || return 0`
# code verbatim as its own rationale, and a bare substring match would trip on that quote.
grep -v '^[[:space:]]*#' $execDir/accd.sh > $W/nocomment.sh
if grep -qF 'if online; then $wasOnline || freshPlug=true' $W/nocomment.sh; then
  no "freshPlug is still derived from online() - an input-cut replug never sets it"
else
  ok "freshPlug is not derived from online()"
fi
grep -v '^[[:space:]]*#' $W/fn.sh | grep -qF 'online || return 0' \
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

# ---------------------------------------------------------------------------
# native_unlatch: the online-derived edge must be its own variable, distinct
# from generic_rearm's present-derived freshPlug. THE FINDING 3 CASE: a loop
# where present was already 1 last time (so freshPlug, present-derived, is
# false this loop) but online just flipped 0->1 (so freshPlugOnline is true)
# must still fire. A build that collapsed both paths onto one present-derived
# edge would miss exactly this -- a smaller re-arm window on the native path,
# the same class of bug as B1 itself.
sed -n '/^  native_unlatch() {/,/^  }/p' $execDir/accd.sh > $W/nat.sh
[ -s $W/nat.sh ] || { no "native_unlatch not found in $execDir/accd.sh"; fin; }

grep -v '^[[:space:]]*#' $W/nat.sh | grep -qF '$freshPlug &&' \
  && no "native_unlatch still reads the present-derived \$freshPlug, not its own online-derived edge" \
  || ok "native_unlatch does not read the present-derived \$freshPlug"

mkharnessNative() {  # $1=freshPlug $2=freshPlugOnline $3=online $4=expect(fire|skip)
  cat > $W/runnat.sh <<EOF
freshPlug=$1
freshPlugOnline=$2
online(){ [ "$3" = 1 ]; }
_lt_pause_cap(){ return 0; }
_le_resume_cap(){ return 1; }
_temp_hold(){ return 1; }
read_status(){ echo "Not charging"; }
sync_native_limit(){ :; }
loopDelay=(0)
gcsl=$W/gcsl; gcst=$W/gcst
. $W/nat.sh
native_unlatch
EOF
  rm -f $W/gcst
  /system/bin/sh $W/runnat.sh >/dev/null 2>&1 || :
  if [ "$4" = fire ]; then
    [ -f $W/gcst ] && ok "freshPlug=$1 freshPlugOnline=$2 online=$3 -> native re-armed" \
      || no "freshPlug=$1 freshPlugOnline=$2 online=$3 -> NO native re-arm (narrowed window)"
  else
    [ -f $W/gcst ] && no "freshPlug=$1 freshPlugOnline=$2 online=$3 -> native re-armed when it must not" \
      || ok "freshPlug=$1 freshPlugOnline=$2 online=$3 -> correctly skipped"
  fi
}
mkharnessNative false true  1 fire   # THE FINDING 3 CASE: present already latched, online edge alone must still fire
mkharnessNative true  false 1 skip   # present edge fired earlier plug, no online edge this loop -> must not fire on freshPlug alone
mkharnessNative false false 1 skip   # neither edge this loop
mkharnessNative true  true  1 fire   # ordinary simultaneous replug
mkharnessNative false true  0 skip   # online() itself false -> entry gate still wins regardless of the edge
fin
