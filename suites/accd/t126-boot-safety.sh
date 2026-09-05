#!/system/bin/sh
# t126 - nothing added to a boot path may be able to hang, abort, or loop a boot.
#
# ACC runs code at two boot stages and they carry very different risk:
#
#   post-fs-data   EARLY, blocking. A hang here hangs the boot; an abort here loses the boot-gap
#                  cut. This is the stage that can bootloop a phone.
#   late_start     AFTER init.svc.bootanim stops or sys.boot_completed=1. accd --init lives here,
#                  so by construction it cannot prevent a boot that has already completed.
#
# The existing guard is a 3-strike self-heal: post-fs-data increments .early-boot-count, service.sh
# deletes it on reaching late_start, and three boots that never get there make post-fs-data disable
# its own early cap. That is what turns a hypothetical early-cap bootloop into three slow boots.
# Every assertion here defends one of those properties.
#
# NO HARDWARE. Source-level, because a bootloop cannot be unit-tested by causing one.

ID=t126
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
PF=$execDir/post-fs-data.sh
SV=$execDir/service.sh
for _f in "$AD" "$PF" "$SV"; do [ -f "$_f" ] || { no "missing $_f"; fin; }; done

# ---- 1. everything parses. A syntax error in post-fs-data IS a boot hazard --------------------
for _f in "$AD" "$PF" "$SV"; do
  if /system/bin/sh -n "$_f" 2>/dev/null; then ok "$(basename $_f) parses"
  else no "$(basename $_f) does NOT parse - this alone could break boot"; fi
done

# ---- 2. accd --init is late_start, never early -------------------------------------------------
grep -q 'init.svc.bootanim' "$SV" && grep -q 'sys.boot_completed' "$SV" \
  && ok "service.sh waits for bootanim/boot_completed before --init" \
  || no "service.sh no longer gates --init on boot completing"

# ---- 3. the 3-strike self-heal is intact -------------------------------------------------------
grep -q 'early-boot-count' "$PF" \
  && ok "post-fs-data still counts boots" \
  || no "the boot counter is gone - a bootloop would no longer self-heal"
grep -q 'rm -f $dataDir/.early-boot-count' "$SV" \
  && ok "service.sh clears the counter on a good boot" \
  || no "the counter is never cleared - normal use would eventually self-disable early-cap"
grep -qE '\-ge 3' "$PF" && grep -q 'no-early-cap' "$PF" \
  && ok "three bad boots self-disable early-cap" \
  || no "the 3-strike limit or its latch is missing"

# ---- 4. post-fs-data must not enable errexit ---------------------------------------------------
# It is full of best-effort reads; one non-zero must never abort the stage that gates the boot.
if grep -qE '^[[:space:]]*set -[a-z]*e' "$PF"; then
  no "post-fs-data.sh enables errexit - a single failing read could abort the early stage"
else
  ok "post-fs-data.sh does not enable errexit"
fi

# ---- 5. _mvolt (added for the millivolt pause domain) is read-only and bounded -----------------
_mv=$(sed -n '/^_mvolt() {/,/^}/p' "$PF")
if [ -n "$_mv" ]; then
  # Strip comments and the harmless redirections before asking whether anything is written:
  # a bare '>' counted 2>/dev/null as a write.
  _mvclean=$(printf '%s' "$_mv" | grep -vE '^[[:space:]]*#' | sed -e 's|2>/dev/null||g')
  if printf '%s' "$_mvclean" | grep -qE '>|rm |mv |ln |chmod |mount '; then
    no "_mvolt writes something - a boot-stage reader must only read"
  else
    ok "_mvolt only reads"
  fi
  printf '%s' "$_mv" | grep -qE 'while|until' \
    && no "_mvolt contains an unbounded loop" \
    || ok "_mvolt has no while/until - it cannot spin"
else
  sk "_mvolt not present"
fi

# ---- 6. the provider-bin loop cannot abort accd under set -eu ---------------------------------
# accd enables set -eu inside misc_stuff(), which runs BEFORE this loop, so any unguarded
# non-zero here would kill the daemon at init.
_pb=$(sed -n '/for _pbin in/,/unset _pbin/p' "$AD")
if [ -n "$_pb" ]; then
  _bad=0
  # every executable line must end in a handler: `|| continue`, `|| :`, or be loop syntax
  printf '%s\n' "$_pb" | grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*$' | while IFS= read -r _l; do
    case "$_l" in
      *'|| continue'*|*'|| :'*|*'for _pbin'*|*done*|*'unset _pbin'*) : ;;
      *) echo "UNGUARDED: $_l" ;;
    esac
  done > "${TMPDIR:-/data/local/tmp}/.t126bad" 2>/dev/null || :
  if [ -s "${TMPDIR:-/data/local/tmp}/.t126bad" ]; then
    no "provider-bin loop has an unguarded command:"
    cat "${TMPDIR:-/data/local/tmp}/.t126bad"
  else
    ok "every command in the provider-bin loop has a || handler"
  fi
  rm -f "${TMPDIR:-/data/local/tmp}/.t126bad" 2>/dev/null || :
  printf '%s' "$_pb" | grep -q '\[ -w' \
    && ok "it writes only where the directory is writable" \
    || no "it does not check writability before linking"
  printf '%s' "$_pb" | grep -qE 'mount|remount' \
    && no "it remounts something - never do that from a boot path" \
    || ok "it never remounts anything"
else
  sk "provider-bin loop not present"
fi

# ---- 7. one missing grouped node must not hide later valid nodes -------------------------------
_cutfn=$(sed -n '/^_cut() {/,/^}/p' "$PF")
_cw=${TMPDIR:-/data/local/tmp}/t126-cut.$$
rm -rf "$_cw" 2>/dev/null; mkdir -p "$_cw"
echo 1 > "$_cw/valid"
getprop(){ :; }
eval "$_cutfn"
_w=$(_cut "$_cw/missing 1 0 $_cw/valid 1 0" 75)
[ "$(cat "$_cw/valid" 2>/dev/null)" = 0 ] \
  && ok "_cut skips a missing first node and still writes the later valid node" \
  || no "_cut stopped at the missing first node and skipped the valid remainder"
case " $_w " in *" $_cw/valid "*) ok "_cut reports the later node it wrote";;
  *) no "_cut wrote no auditable record for the later node";; esac
rm -rf "$_cw" 2>/dev/null

# ---- 8. the /sbin loop must not abandon links on one failure ----------------------------------
# Comments first: the block explains itself with the words '|| break', and matching that prose
# reported the fixed code as broken.
sed -n '/if \[ -d \/sbin \]/,/^  fi/p' "$AD" | grep -vE '^[[:space:]]*#' | grep -q '|| break' \
  && no "the /sbin loop still breaks on first failure, dropping the rest" \
  || ok "the /sbin loop continues past a single failed link"

fin
