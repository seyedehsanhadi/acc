#!/system/bin/sh
# t51 - the probe journal, the fast-charge guard, the native backstop, and unit conversion.
#
# THE PROBE JOURNAL IS THE HIGHEST-CONSEQUENCE CODE IN THE MODULE
#   Discovery works by writing candidate nodes to see which one stops a charge. On some devices a
#   particular node does not stop the charge - it crash-reboots the phone, and on at least one
#   reported OnePlus SM8250 it dropped the device into EDL. The journal is what makes that survivable:
#   arm before the write, and if the phone comes back up with the marker still set, that node crashed
#   it and must never be probed again on this device, ever.
#
#   There is no second chance here. If the journal fails to persist, the next scan probes the same
#   node and crashes the phone again - an infinite bootloop, on a user's daily driver.
#
#   Neither test phone has such a node, so this can only be tested synthetically.
#
# ALSO COVERED
#   fast_session            do not fight a charger that is mid fast-charge negotiation
#   native_verify_backstop  restore an input node the native-limit path borrowed
#   to_mA                   unit conversion, where a wrong ampFactor makes every current wrong
#
# NO HARDWARE.

ID=t51
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
PJ=$execDir/probe-journal.sh
AD=$execDir/accd.sh
SC=$execDir/acc-switch-scan.sh
W=${TMPDIR:-/data/local/tmp}/.t51
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

xf() {
  awk -v fn="$1" '
    !f { if ($0 ~ "^[ \t]*" fn "\\(\\)[ \t]*\\{") { f=1; ind=""; s=$0
           while (substr(s,1,1)==" " || substr(s,1,1)=="\t") { ind=ind substr(s,1,1); s=substr(s,2) }
           closer=ind "}"; print } next }
    { print; if ($0==closer) exit }' "$2"
}
chk(){ [ "$3" = "$2" ] && ok "$1" || no "$1  (expected '$2', got '$3')"; }
local(){ :; }

# ---- the probe journal ---------------------------------------------------------------------------
if [ -f "$PJ" ]; then
  for _f in journal_arm journal_check journal_disarm journal_blacklisted; do
    _s=$(xf "$_f" "$PJ"); [ -n "$_s" ] || { no "could not extract $_f"; fin; }
    eval "$_s"
  done
  dataDir=$W
  probePending=$W/.probe-pending
  probeBlacklist=$W/.probe-blacklist
  TMPDIR=$W
  notif(){ :; }

  # The whole point: arm, simulate a crash (the marker survives the reboot), then check.
  rm -f "$probePending" "$probeBlacklist"
  journal_arm 'battery/killer_node 0 1'
  [ -f "$probePending" ] && ok "arming persists the candidate before it is written" \
                         || no "arming did not persist - a crash would be untraceable"
  chk "the armed line is exactly what was passed" "battery/killer_node 0 1" "$(cat $probePending 2>/dev/null)"

  # Now the phone "reboots" with the marker still present.
  journal_check 2>/dev/null || :
  grep -qxF 'battery/killer_node 0 1' "$probeBlacklist" 2>/dev/null \
    && ok "after a crash-reboot the candidate is permanently blacklisted" \
    || no "the crashing candidate was NOT blacklisted - the next scan would crash the phone again"
  journal_blacklisted 'battery/killer_node 0 1' 2>/dev/null \
    && ok "and journal_blacklisted reports it" \
    || no "journal_blacklisted does not see the entry it just wrote"
  journal_blacklisted 'battery/other_node 0 1' 2>/dev/null \
    && no "an unrelated node reports as blacklisted" \
    || ok "an unrelated node is not blacklisted"

  # A clean probe disarms, so a later reboot does not blame an innocent node.
  rm -f "$probePending" "$probeBlacklist"
  journal_arm 'battery/good_node 0 1'
  journal_disarm 2>/dev/null || :
  [ -f "$probePending" ] && no "disarm left the marker set - a later reboot would blame this node" \
                         || ok "a clean probe disarms, so an unrelated reboot blames nothing"
  journal_check 2>/dev/null || :
  [ -s "$probeBlacklist" ] && no "a disarmed probe still ended up blacklisted" \
                           || ok "and journal_check blacklists nothing when disarmed"

  # Idempotence: two crashes on the same node must not duplicate the entry, or the file grows without
  # bound on a device that keeps crashing.
  rm -f "$probeBlacklist"
  journal_arm 'battery/dup 0 1'; journal_check 2>/dev/null || :
  journal_arm 'battery/dup 0 1'; journal_check 2>/dev/null || :
  _n=$(grep -cxF 'battery/dup 0 1' "$probeBlacklist" 2>/dev/null || :)
  case "${_n:-0}" in 1) ok "a repeated crash does not duplicate the blacklist entry";;
                     *) no "blacklist has ${_n:-0} copies of the same node";; esac

  # An empty marker must not blacklist an empty line, which would then match everything or nothing
  # depending on the grep.
  rm -f "$probeBlacklist"
  : > "$probePending"
  journal_check 2>/dev/null || :
  [ -s "$probeBlacklist" ] && no "an empty pending marker wrote an empty blacklist entry" \
                           || ok "an empty pending marker blacklists nothing"
else
  no "missing $PJ - the EDL-crash latch is absent from this build"
fi

# ---- fast_session --------------------------------------------------------------------------------
# Do not cut or cap while a charger is mid fast-charge negotiation: on VOOC/QC a toggle forces a
# re-negotiate that only a physical replug recovers from.
_s=$(xf fast_session "$AD")
if [ -n "$_s" ]; then
  eval "$_s"
  TMPDIR=$W
  rm -f $W/.fcguard-off $W/.fcguard-force
  echo 3 > $W/qc; _fcNodes="$W/qc"
  fs(){ if fast_session 2>/dev/null; then echo yes; else echo no; fi; }
  chk "a node reporting 3 -> fast session in progress"  yes "$(fs)"
  echo 0 > $W/qc;  chk "a node reporting 0 -> no fast session"        no  "$(fs)"
  echo '' > $W/qc; chk "an empty node -> no fast session"             no  "$(fs)"
  echo xx > $W/qc; chk "a non-numeric node -> no fast session"        no  "$(fs)"
  # quick_charge_type is special: 1 means "ordinary", only >1 is a fast session
  mkdir -p $W/ps; echo 1 > $W/ps/quick_charge_type; _fcNodes="$W/ps/quick_charge_type"
  chk "quick_charge_type=1 is ordinary, not fast"       no  "$(fs)"
  echo 2 > $W/ps/quick_charge_type
  chk "quick_charge_type=2 is a fast session"           yes "$(fs)"
  # the user's override, both directions
  touch $W/.fcguard-off
  chk "the guard can be turned off entirely"            no  "$(fs)"
  rm -f $W/.fcguard-off; touch $W/.fcguard-force
  echo 0 > $W/ps/quick_charge_type
  chk "and forced on regardless of the nodes"           yes "$(fs)"
  rm -f $W/.fcguard-force
else
  no "could not extract fast_session"
fi

# ---- native_verify_backstop ----------------------------------------------------------------------
# It borrows an input node to verify a native limit, and MUST hand it back. A node left borrowed is
# a phone left throttled with nothing in the config to explain it.
_s=$(xf native_verify_backstop "$AD")
if [ -n "$_s" ]; then
  printf '%s' "$_s" | grep -q 'nvb-restore' \
    && ok "native_verify_backstop keeps a restore value for the node it borrows" \
    || no "it borrows an input node with nothing recorded to restore"
  printf '%s' "$_s" | grep -q 'rm -f $TMPDIR/.nvb-on' \
    && ok "and clears its own marker when it hands the node back" \
    || no "the borrow marker is never cleared"
  printf '%s' "$_s" | grep -qE 'cap. -le .\( stop \+ 1 \)|! online' \
    && ok "hands the node back once below the limit or unplugged" \
    || no "no release condition - the node could stay borrowed indefinitely"
  printf '%s' "$_s" | grep -q '\[ -f "$nvb_node" \] || return 0' \
    && ok "no-ops on a phone without that node" \
    || no "assumes the input node exists"
else
  no "could not extract native_verify_backstop"
fi

# ---- to_mA : unit conversion ---------------------------------------------------------------------
# ampFactor_ is 1000000 for microamp kernels and 1000 for milliamp ones. Get it wrong and every
# current in every log and every comparison is out by a thousand.
_s=$(xf to_mA "$SC")
if [ -n "$_s" ]; then
  eval "$_s"
  ampFactor_=1000000
  chk "uA kernel: 2000000 -> 2000 mA"  2000 "$(to_mA 2000000)"
  chk "uA kernel: -2000000 -> -2000"   -2000 "$(to_mA -2000000)"
  chk "uA kernel: 0 -> 0"              0    "$(to_mA 0)"
  ampFactor_=1000
  chk "mA kernel: 2000 -> 2000 mA"     2000 "$(to_mA 2000)"
  chk "mA kernel: 500 -> 500 mA"       500  "$(to_mA 500)"
else
  no "could not extract to_mA"
fi

rm -rf "$W" 2>/dev/null
fin
