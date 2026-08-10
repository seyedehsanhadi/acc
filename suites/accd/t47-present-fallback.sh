#!/system/bin/sh
# t47 - present() must not let a supply reporting 0 answer for the whole device.
#
# THE REPORT THIS COMES FROM
#   A fuxi (Xiaomi) owner on rc21: charger plugged in, phone not charging, AccA showing "draining".
#   "Charge once to 80%, without restrictions" started it charging immediately. Two full diagnostic
#   bundles, taken 5 minutes apart, gave the whole sequence:
#
#     18:53:30  ACC writes input_suspend <- 1        (a normal pause at 80%)
#               ... ACC writes nothing at all for 4h14m ...
#     23:07:31  level 62%, resume_capacity 75%, still cut, status Discharging
#               flight.log still ticking every 121s, cutByAcc=false
#     23:11:04  force-charge -> input_suspend <- 0 (was 1)
#
#   The daemon was alive and looping the entire time, so this was never the hung-daemon class. It
#   simply believed the cable was out, and a phone that believes it is unplugged never evaluates
#   resume. The pack drained from 80% to 62% with a charger attached.
#
# WHY IT HAPPENED
#   That device has NO usb/present node. The only present nodes matching the regex are the battery
#   (excluded) and wireless/present, which reads 0 because no pad is in use. The attached charger is
#   visible only as ucsi-source-psy-.../online=1.
#
#   present() looped its nodes and set seen=true for any node it merely READ, so the idle wireless
#   supply's 0 made `seen` true and the function returned "unplugged" WITHOUT reaching its own
#   online fallback. ACC's own input_suspend=1 had already zeroed usb/online, so nothing else could
#   correct it.
#
# WHY A LIVE TEST WOULD NOT HAVE CAUGHT IT
#   Both test phones expose usb/present, so present() short-circuits on the first node and the
#   fallback is unreachable code on that hardware. The path only exists on devices we do not have,
#   which is exactly what a unit test is for: drive the function with the reporter's node layout.
#
# WHAT IS ASSERTED
#   The full truth table, including the two directions that matter most: a node reading 0 must never
#   veto an energized supply, and an input-cut switch (online=0 while plugged) must still be caught
#   by a present node reading 1 - the reason present is consulted FIRST and online is only a
#   fallback.

ID=t47
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=$execDir/batt-interface.sh
[ -f "$BI" ] || { no "missing $BI"; fin; }

W=${TMPDIR:-/data/local/tmp}/.t47
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

# Drive the SHIPPED function, not a copy of it. A reimplementation would pass whatever the harness
# author believed the code did, which is how the first version of the megatest "verified" a filter
# by asserting against its own copy of that filter.
eval "$(sed -n '/^present() {/,/^}/p' "$BI")" 2>/dev/null
command -v present >/dev/null 2>&1 || { no "could not extract present() from $BI"; fin; }

ONLINE_ANS=1
online(){ return $(( 1 - ONLINE_ANS )); }
local(){ :; }

run(){   # run <online 1|0> <values...>  -> prints yes/no
  ONLINE_ANS=$1; shift
  _presentF=
  _i=0
  for _v in "$@"; do
    _i=$((_i + 1)); echo "$_v" > "$W/n$_i"; _presentF="$_presentF $W/n$_i"
  done
  present >/dev/null 2>&1 && echo yes || echo no
}

# --- the reporter's exact layout: one node reading 0, charger energized ---------------------------
r=$(run 1 0)
[ "$r" = yes ] && ok "a present node reading 0 does NOT veto an energized supply (the fuxi case)" \
               || no "a single present=0 node still reports unplugged - the reported bug reproduces"

# wireless/present=0 alongside nothing else, charger visible only via online
r=$(run 1 0 0)
[ "$r" = yes ] && ok "two nodes reading 0 still defer to online" \
               || no "two nodes reading 0 veto the online fallback"

# --- present must still WIN over online, or an input-cut switch breaks everything -----------------
# This is the direction the old code got right and must keep: a cut switch drives online to 0 while
# the cable is in, so a present node reading 1 has to be believed over an offline reading.
r=$(run 0 1)
[ "$r" = yes ] && ok "present=1 beats online=0 (an input-cut switch is still seen as plugged)" \
               || no "present=1 with online=0 reports unplugged - input-cut detection is broken"

r=$(run 0 0 1)
[ "$r" = yes ] && ok "any node reading 1 wins, whatever order it appears in" \
               || no "a later node reading 1 was not honoured"

# --- genuinely unplugged must stay unplugged -----------------------------------------------------
# The fallback must not turn into "always plugged": that would keep the daemon on its fast loop all
# night on an unplugged phone, which is the standby drain this project already fixed once.
r=$(run 0 0)
[ "$r" = no ] && ok "nothing present and nothing online still reports unplugged" \
              || no "reports plugged with no present node and no online supply"

r=$(run 0)
[ "$r" = no ] && ok "no present nodes at all, nothing online -> unplugged" \
              || no "reports plugged with no evidence at all"

# --- no present nodes, but a live supply ---------------------------------------------------------
r=$(run 1)
[ "$r" = yes ] && ok "no present nodes at all -> defers to online" \
               || no "a device with no present node can never be seen as plugged"

# --- the guard against a regression: 'seen' must not gate the fallback ----------------------------
# CODE only. The function carries a comment describing the old defect, and that comment contains
# the literal text "seen=true" - so grepping the raw extract reported the bug as still present in
# the very build that fixed it. Strip comment lines before asserting on code.
_src=$(sed -n '/^present() {/,/^}/p' "$BI" | grep -v '^[[:space:]]*#')
# toybox grep has no \s and no \| - a pattern using them matches nothing, so the assertion
# silently inverts and reports a defect that is not there. Use POSIX classes, and match the
# ASSIGNMENT rather than the bare word so the explanatory comment above the code cannot satisfy it.
printf '%s' "$_src" | grep -qE 'seen=(true|false)' \
  && no "present() still tracks a 'seen' flag - a node reading 0 can veto the online fallback again" \
  || ok "no 'seen' flag remains; only present=1 short-circuits"

printf '%s' "$_src" | grep -qE '^[[:space:]]*online[[:space:]]*$' \
  && ok "online is the last word when no node claims present" \
  || no "present() no longer ends by deferring to online"

rm -rf "$W" 2>/dev/null
fin
