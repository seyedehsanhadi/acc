#!/system/bin/sh
# AMPS layer-crash guard.
#
# A Motorola kansas (MT6835) hung during a Quick scan and came back with bootreason=hang_detect.
# Its blacklist was checked afterwards and was EMPTY, so the repeat-crash guard did nothing and that
# phone hangs on every scan, forever. The guard only ever watched WRITES; the scan was READING, and
# a driver read wedged in uninterruptible sleep is not killable by the timeout in rd() either.
#
# Journalling every read means an fsync per read, hundreds per run. The layer is the useful
# granularity: about ten writes a run, and it is enough to skip the thing that killed the phone.
#
# NO HARDWARE. The functions are executed against a fake state directory.

ID=t-layer-crash
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

AMPS=${AMPS:-/data/adb/vr25/acc/acc-compat.sh}
[ -f "$AMPS" ] || AMPS=/data/local/tmp/amps.sh
[ -f "$AMPS" ] || { no "amps not found (set AMPS=)"; fin; }

W=${TMPDIR:-/data/local/tmp}/tlc.$$
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null
trap 'rm -rf "$W" 2>/dev/null' EXIT

# The five functions under test, lifted out so they can run against a fake AMPSD.
FNS=$(sed -n '/^boot_abnormal() *{/,/^jrn_begin()/p' "$AMPS" | sed '$d')
for _need in boot_abnormal lyr_mark lyr_skip lyr_skippable lyr_danger; do
  printf '%s\n' "$FNS" | grep -q "^$_need() *{" || no "did not lift $_need()"
done
[ -n "$FNS" ] || { no "could not lift the layer functions out of $AMPS"; fin; }

harness() {  # $1 script fragment, run with the functions and a fake state dir
  ( AMPSD=$W; LYR=$W/.layer; DLY=$W/.danger; OUT=$W/out; OUT2=$W/out
    _BLTAB=$(printf '\t'); _BLCR=$(printf '\r')
    bootid(){ echo "${FAKEBOOT:-boot-now}"; }
    getprop(){ echo "${FAKEREASON:-reboot,userrequested}"; }
    log(){ printf '%s\n' "$*"; }
    sync(){ :; }
    eval "$FNS"
    eval "$1" ) 2>&1
}

# ---- 1: a clean boot reason is not abnormal -------------------------------------------------------
_r=$(harness 'boot_abnormal && echo YES || echo NO')
[ "$_r" = NO ] && ok "an ordinary reboot is not treated as a crash" \
                || no "boot_abnormal said [$_r] for a normal reboot"

# ---- 2: hang_detect IS abnormal - the reason the field report went unnoticed ----------------------
_r=$(FAKEREASON=hang_detect harness 'boot_abnormal && echo YES || echo NO')
[ "$_r" = YES ] && ok "hang_detect counts as abnormal (the Motorola case)" \
                 || no "boot_abnormal said [$_r] for hang_detect - this is the bug that let it through"

# ---- 3: a layer in flight is recorded ------------------------------------------------------------
_r=$(harness 'lyr_mark 6; cut -f1 $LYR')
[ "$_r" = 6 ] && ok "the layer in flight is written to disk" \
               || no "lyr_mark left [$_r]"

# ---- 4: a clean run leaves nothing to skip -------------------------------------------------------
_r=$(harness 'lyr_mark 6; lyr_danger 6 && echo DANGER || echo CLEAN')
[ "$_r" = CLEAN ] && ok "merely entering a layer does not mark it dangerous" \
                   || no "a layer was marked dangerous just for running: [$_r]"

# ---- 5: crash + abnormal boot -> the layer is recorded --------------------------------------------
# The phone went down inside layer 6 (marked under boot-A) and came back under boot-B.
printf '6\tboot-A\n' > $W/.layer
_r=$(FAKEBOOT=boot-B FAKEREASON=hang_detect harness '
  if [ -s "$LYR" ]; then
    _lyn=$(cut -f1 "$LYR"); _lyb=$(cut -f2 "$LYR"); rm -f "$LYR"
    if [ -n "$_lyn" ] && [ "$_lyb" != unknown ] && [ "$_lyb" != "$(bootid)" ] && boot_abnormal && ! lyr_danger "$_lyn"; then
      printf "%s\t%s\n" "$_lyn" "when" >> "$DLY"
    fi
  fi
  lyr_danger 6 && echo DANGER || echo CLEAN')
[ "$_r" = DANGER ] && ok "a crash with NO write in flight now records the layer (the Motorola case)" \
                    || no "the layer was not recorded: [$_r] - that phone would hang again on every scan"

# ---- 6: the same crash after a NORMAL reboot records nothing --------------------------------------
printf '6\tboot-A\n' > $W/.layer; rm -f $W/.danger
_r=$(FAKEBOOT=boot-B harness '
  if [ -s "$LYR" ]; then
    _lyn=$(cut -f1 "$LYR"); _lyb=$(cut -f2 "$LYR"); rm -f "$LYR"
    if [ -n "$_lyn" ] && [ "$_lyb" != unknown ] && [ "$_lyb" != "$(bootid)" ] && boot_abnormal && ! lyr_danger "$_lyn"; then
      printf "%s\t%s\n" "$_lyn" "when" >> "$DLY"
    fi
  fi
  lyr_danger 6 && echo DANGER || echo CLEAN')
[ "$_r" = CLEAN ] && ok "a user rebooting mid-scan does not get a layer disabled" \
                   || no "a normal reboot disabled a layer: [$_r]"

# ---- 7: a recorded layer skips, once, with an explanation -----------------------------------------
printf '6\twhen\n' > $W/.danger
_r=$(harness 'lyr_mark 6; lyr_skip 6 && echo SKIP; lyr_skip 6 && echo SKIP')
case "$_r" in
  *"restarted abnormally"*) : ;;
  *) no "the skip did not explain itself: [$_r]"; _r=; ;;
esac
if [ -n "$_r" ]; then
  _n=$(printf '%s' "$_r" | grep -c '^SKIP$')
  _w=$(printf '%s' "$_r" | grep -c 'restarted abnormally')
  { [ "$_n" = 2 ] && [ "$_w" = 1 ]; } \
    && ok "a recorded layer skips every time but explains itself once" \
    || no "skips=$_n warnings=$_w - the warning must not repeat per node"
fi

# ---- 8: a DIFFERENT layer still runs ---------------------------------------------------------------
_r=$(harness 'lyr_mark 5; lyr_skip 5 && echo SKIP || echo RUN')
[ "$_r" = RUN ] && ok "only the layer that crashed is skipped; the rest of the scan still runs" \
                 || no "recording layer 6 also disabled layer 5: [$_r]"

# ---- 9: the guard is actually wired into the read-heavy layers --------------------------------------
_miss=
for _l in 6 6f 6g S1; do
  grep -q "lyr_skip $_l" "$AMPS" || _miss="$_miss $_l"
done
[ -z "$_miss" ] && ok "the guard is wired into layers 6, 6f, 6g and S1" \
                 || no "no lyr_skip in layer(s):$_miss - the record would be written and never used"

# ---- 10: reaching our own exit clears the marker ----------------------------------------------------
grep -q 'rm -f "\$LYR"' "$AMPS" \
  && ok "restore() clears the in-flight marker, so a clean run never disables anything" \
  || no "the in-flight marker is never cleared - every completed scan would look like a crash"

# ---- 11: the promise matches what the code can do -------------------------------------------------------
# The first version of this guard recorded ANY layer and told the user it would be skipped from now
# on "so the same thing cannot happen again". lyr_skip is called in exactly four places, so for the
# other fourteen layers that sentence was false and the next scan did the same thing.
_r=$(harness 'for l in S1 6 6f 6g; do lyr_skippable $l && printf "%s:yes " $l || printf "%s:NO " $l; done')
[ "$_r" = "S1:yes 6:yes 6f:yes 6g:yes " ] \
  && ok "the four layers with a lyr_skip call are the ones declared skippable" \
  || no "skippable set is [$_r]"
_r=$(harness 'for l in 0 1 2 3 S2 4 4b 4c 4d 5 6b 6c 6d 6e 7 RECAP; do lyr_skippable $l && printf "%s " $l; done')
[ -z "$_r" ] \
  && ok "no layer without a skip check is declared skippable" \
  || no "these have no lyr_skip call but are claimed skippable: [$_r]"
# and the source must actually carry a call for each claimed one
_missing=
for _l in S1 6 6f 6g; do grep -q "lyr_skip $_l" "$AMPS" || _missing="$_missing $_l"; done
[ -z "$_missing" ] && ok "every layer declared skippable has a real lyr_skip call" \
                    || no "declared skippable with no call:$_missing"

fin
