#!/system/bin/sh
# t88 - anything that writes charger nodes and cleans up on exit must also clean up on SIGHUP.
#
# THE FAULT. install/acc-switch-scan.sh:344 is
#     trap cleanup EXIT INT TERM
# with no HUP, while both of its siblings have it: install/acc.sh:937 `trap exxit EXIT INT TERM HUP`
# and amps.sh:1129 `trap 'restore; ...' INT TERM HUP`.
#
# WHY IT MATTERS HERE SPECIFICALLY. This is the program behind all three of AccA's scan buttons, and
# it works by writing every candidate node to its OFF value in turn. SIGHUP is what a phone delivers
# when the terminal or adb session that launched an unattended scan goes away - the single most likely
# way a scan is interrupted in the field. Without HUP in the trap, cleanup never runs and the scan
# ends with candidates still cut and no daemon: charging uncapped, on a phone whose owner believes a
# scan is in progress.
#
# EXIT does not save it. A shell killed by an uncaught signal dies without running its EXIT trap.
#
# NO HARDWARE - this is a source invariant, asserted across every writer that has a cleanup trap.

ID=t88
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}

# Every file here installs a cleanup handler AND writes charger nodes. amps.sh ships as acc-compat.sh
# in the installed tree, so accept either name.
_amps=
for _c in $execDir/acc-compat.sh $execDir/amps.sh; do [ -f "$_c" ] && { _amps=$_c; break; }; done

_check(){ # $1 file  $2 label
  [ -f "$1" ] || { no "$2 not found at $1"; return; }
  # the arming lines: a trap that installs a handler (not `trap -`, which disarms)
  # -E, not a BRE with \| : toybox grep has no \| alternation, and a silently-empty filter here made
  # this suite report "nothing to cover" and pass against the very fault it exists for.
  _arm=$(grep -n '^ *trap [^-]' "$1" 2>/dev/null | grep -E 'EXIT|INT|TERM')
  if [ -z "$_arm" ]; then
    ok "$2 installs no cleanup trap (nothing to cover)"
    return
  fi
  _bad=0
  # Walk each arming line. A handler that covers INT/TERM must also cover HUP: those three are the
  # interruptions a user or a dropped session actually delivers, and there is no reason to catch two
  # of them and not the third.
  printf '%s\n' "$_arm" | while IFS= read -r _l; do
    case "$_l" in
      *INT*|*TERM*)
        case "$_l" in
          *HUP*) : ;;
          *) echo "BAD:$_l" ;;
        esac ;;
    esac
  done > /data/local/tmp/t88-bad-$$ 2>/dev/null
  _bad=$(grep -c '^BAD:' /data/local/tmp/t88-bad-$$ 2>/dev/null) || _bad=0
  case "${_bad:-0}" in ''|*[!0-9]*) _bad=0;; esac
  if [ "$_bad" -eq 0 ] 2>/dev/null; then
    ok "$2 covers HUP everywhere it covers INT/TERM"
  else
    no "$2 has ${_bad} handler(s) catching INT/TERM but NOT HUP - a dropped session leaves its writes applied"
    sed 's/^BAD:/        /' /data/local/tmp/t88-bad-$$ 2>/dev/null
  fi
  rm -f /data/local/tmp/t88-bad-$$ 2>/dev/null
}

_check "$execDir/acc-switch-scan.sh" "acc-switch-scan.sh (all three AccA scan buttons)"
_check "$execDir/acc.sh"             "acc.sh"
[ -n "$_amps" ] && _check "$_amps"   "AMPS" || ok "AMPS not present in this tree (skipped)"

# The sibling that already gets it right, asserted so the reference cannot rot away.
grep -q 'trap exxit EXIT INT TERM HUP' $execDir/acc.sh 2>/dev/null \
  && ok "acc.sh's exxit trap still covers EXIT INT TERM HUP (the reference this invariant follows)" \
  || no "acc.sh's exxit trap no longer covers all four - the reference is gone"

sh -n "$execDir/acc-switch-scan.sh" 2>/dev/null && ok "acc-switch-scan.sh parses" || no "acc-switch-scan.sh does not parse"
fin
