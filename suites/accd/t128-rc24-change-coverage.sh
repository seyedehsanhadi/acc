#!/system/bin/sh
# t128 - the rc23 -> rc24 changes that no other suite names.
#
# HOW THIS LIST WAS BUILT, so it can be rebuilt rather than trusted:
#   git diff v2025.5.18-6.5.1-rc23..HEAD -U0 -- install/ install.sh install-online.sh \
#     | grep -E '^@@' | sed -E 's/^@@[^@]*@@ ?//' | grep -oE '^[ \t]*[_a-zA-Z][_a-zA-Z0-9]*\(\)'
#   -> 36 changed functions. 25 were named somewhere under suites/. These are the other 11.
#
# "Named by a suite" is a weaker claim than "tested", so the assertions below go for the specific
# thing each diff changed, not merely the function's existence. Where a behaviour needs a charger
# it is asserted at source level and SAYS SO, rather than being quietly skipped.

ID=t128
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SE=$execDir/state-export.sh
DC=$execDir/diag-collect.sh
ST=$execDir/strings.sh
BI=$execDir/batt-interface.sh
for _f in "$SE" "$ST"; do [ -f "$_f" ] || { no "missing $_f"; fin; }; done

# ---- _redact: the e-mail pattern was widened at the wrong end -------------------------------------
# rc23 matched [A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}, so a domain could START with a digit
# or a dot. rc24 requires the domain to begin with a letter. This is a privacy path: it runs over a
# bundle the user is about to send someone, so the assertion is behavioural, not a grep.
if [ -f "$DC" ]; then
  _w=${TMPDIR:-/data/local/tmp}/t128.$$
  mkdir -p "$_w" 2>/dev/null
  _re=$(grep -oE "s#[^#]*#.EMAIL.#g" "$DC" | head -1)
  if [ -n "$_re" ]; then
    printf '%s\n' 'contact me at real.user@example.com please' > "$_w/in"
    sed -E "$_re" "$_w/in" > "$_w/out" 2>/dev/null
    # -E, not BRE alternation: toybox grep has no \| and the test passed over a redacted line.
    grep -qE 'REDACTED|\[EMAIL\]' "$_w/out" \
      && ok "a real address is redacted" \
      || no "a real address survived redaction: $(cat "$_w/out")"
    printf '%s\n' 'version 1.2@3.4 build' > "$_w/in2"
    sed -E "$_re" "$_w/in2" > "$_w/out2" 2>/dev/null
    grep -q '1.2@3.4' "$_w/out2" \
      && ok "a digit-leading pseudo-domain is NOT mangled as an address" \
      || no "the pattern still eats non-addresses like 1.2@3.4: $(cat "$_w/out2")"
  else
    no "could not lift the e-mail redaction pattern out of diag-collect.sh"
  fi
  rm -rf "$_w" 2>/dev/null
else
  sk "diag-collect.sh not installed; _redact not exercised"
fi

# ---- _se_plugged / _se_status: the supply set must not be a hardcoded list ------------------------
# rc23 hardcoded usb/ac/dc/mains/pc_port/wireless. That missed the phones present() was widened for
# (a fuxi shows its charger only as ucsi-source-psy-.../online), so state-export could report
# plugged=false on a charging phone while the daemon knew better. rc24 mirrors present_f/online_f.
_sec=$(sed 's/^[[:space:]]*#.*//' "$SE")
printf '%s' "$_sec" | grep -q '_SE_SUPPLY' \
  && ok "state-export derives its supply set from a shared pattern" \
  || no "state-export has no _SE_SUPPLY - the hardcoded list is back and fuxi-class phones misreport"

if [ -f "$BI" ]; then
  # The two must agree. Compare the node names each one looks for, not the code around them.
  _sesup=$(printf '%s' "$_sec" | grep -oE 'ucsi|usb|wireless|dc|mains|pc_port' | sort -u | tr '\n' ' ')
  _bisup=$(sed 's/^[[:space:]]*#.*//' "$BI" | grep -oE 'ucsi|usb|wireless|dc|mains|pc_port' | sort -u | tr '\n' ' ')
  [ -n "$_sesup" ] && [ -n "$_bisup" ] || sk "could not read either supply set"
  case "$_sesup" in *ucsi*) _a=1;; *) _a=0;; esac
  case "$_bisup" in *ucsi*) _b=1;; *) _b=0;; esac
  [ "$_a" = "$_b" ] \
    && ok "state-export and batt-interface agree on whether ucsi supplies count" \
    || no "state-export and batt-interface disagree on ucsi: se=[$_sesup] bi=[$_bisup]"
else
  sk "batt-interface.sh not installed; cannot cross-check the supply set"
fi

# ---- print_restart_accd: the message had to change when -f gained an exit --------------------------
# It used to say "Restart accd manually to exit this mode", which stopped being true the moment the
# -f hook started restoring the real config at the target.
_stc=$(sed 's/^[[:space:]]*#.*//' "$ST")
printf '%s' "$_stc" | grep -q 'Restart accd manually to exit this mode' \
  && no "the -f message still tells the user to restart accd by hand - that is no longer true" \
  || ok "the stale 'restart accd manually' wording is gone"
printf '%s' "$_stc" | grep -qi 'ends by itself' \
  && ok "the -f message says the mode ends on its own" \
  || no "the -f message does not tell the user the mode ends by itself"

# ---- install-online: branch default and TLS --------------------------------------------------------
# Not installed on the phone, so look wherever a copy was staged. Source-level by nature: exercising
# it would download and run an installer as root.
_io=
for _c in /data/local/tmp/install-online.sh "$execDir/../install-online.sh" /data/local/tmp/suites/install-online.sh; do
  [ -f "$_c" ] && { _io=$_c; break; }
done
if [ -n "$_io" ]; then
  _ioc=$(sed 's/^[[:space:]]*#.*//' "$_io")
  printf '%s' "$_ioc" | grep -q ':[[:space:]]*${commit:=main}' \
    && ok "the updater defaults to main (master has never existed in this fork)" \
    || no "the updater does not default to main"
  printf '%s' "$_ioc" | grep -q 'insecure:-false' \
    && ok "TLS verification is opt-OUT, not always-off" \
    || no "the updater still disables TLS verification unconditionally"
  printf '%s' "$_ioc" | grep -q 'UPDATE FAILED' \
    && ok "a failed download or installer is reported instead of exiting 0" \
    || no "the updater can still report success after a failed install"
else
  sk "install-online.sh not staged on this device; updater changes not checked here"
fi

# ---- AMPS engine functions with no suite of their own ----------------------------------------------
# _is_board, bcharge, chgin_low, emit_alts, selftest, unit_pick changed in the engine. The portable
# AMPS suites live under suites/amps and run on a host, not here; assert only that the engine on this
# phone actually carries them, so a half-synced install is visible.
_amps=
for _c in "$execDir/../amps.sh" /data/local/tmp/amps.sh "$execDir/acc-compat.sh" /data/local/tmp/acc-compat.sh; do
  [ -f "$_c" ] && { _amps=$_c; break; }
done
if [ -n "$_amps" ]; then
  _miss=
  for _fn in bcharge chgin_low emit_alts selftest unit_pick; do
    grep -qE "^[[:space:]]*${_fn}\(\)" "$_amps" || _miss="$_miss $_fn"
  done
  [ -z "$_miss" ] \
    && ok "the staged AMPS engine carries every function rc24 changed" \
    || no "the staged AMPS engine is missing:$_miss (half-synced amps.sh/acc-compat.sh)"
else
  sk "no AMPS engine staged on this device"
fi

# ---- _is_board lives in oem-custom.sh, not the AMPS engine ---------------------------------------
# It is the per-board quirk gate (ro.product.board) and rc24 touched it. Nothing else names it, and
# an earlier version of this suite looked for it in amps.sh and reported a false half-synced engine.
OC=$execDir/oem-custom.sh
if [ -f "$OC" ]; then
  grep -qE '^[[:space:]]*_is_board\(\)' "$OC" \
    && ok "_is_board is defined in oem-custom.sh" \
    || no "_is_board is gone from oem-custom.sh - every per-board quirk below it stops firing"
  # It must stay a QUERY. A board gate that writes something would fire on every phone that loads
  # this file, not only the one the quirk was written for.
  _ocb=$(sed -n 's/^[[:space:]]*_is_board() *{ *//p' "$OC" | head -1)
  case "$_ocb" in
    *getprop*grep*) ok "_is_board only reads ro.product.board and greps it" ;;
    "")             no "could not read the _is_board body" ;;
    *)              no "_is_board is no longer a plain getprop+grep: $_ocb" ;;
  esac
else
  sk "oem-custom.sh not installed; _is_board not checked"
fi


fin
