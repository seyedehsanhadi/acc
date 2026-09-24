#!/system/bin/sh
# t153 - the twelve rc22-era functions P1's coverage audit reported as having no suite pointed at
# them. Eight distinct functions; four of them exist twice because acc-compat.sh is a generated
# sibling of amps.sh, and the audit counts each copy.
#
#   amps.sh / acc-compat.sh : _cscap  emit_native  pick_outdir  proof_available
#   acc.sh                  : set_prop_
#   set-ch-volt.sh          : apply_voltage
#   strings.sh              : print_help  print_restart_accd
#
# The audit only asks that a suite NAME each one, which a file full of greps would satisfy without
# testing anything. Each is driven here instead, against the contract that makes it matter:
# _cscap decides whether a current reading is microamps or milliamps, emit_native is the list AMPS
# writes to put a phone back, proof_available is what says a charge is real, and the two string
# helpers are the ones a partial translation could leave undefined.
#
# NO HARDWARE.

ID=t153
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed${S:+, $S skipped}"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
# amps.sh ships beside the module rather than inside install/, so accept either layout.
AMPS=$execDir/amps.sh
[ -f "$AMPS" ] || AMPS=${execDir%/*}/amps.sh
COMPAT=$execDir/acc-compat.sh
[ -f "$COMPAT" ] || COMPAT=${execDir%/*}/acc-compat.sh
ACC=$execDir/acc.sh
SCV=$execDir/set-ch-volt.sh
STR=$execDir/strings.sh

[ 1 = 2 ] && no "harness: 1 equals 2" || ok "harness: the assertions discriminate"

# ---- 1. _cscap: a current reading is microamps or milliamps, and getting it wrong is 1000x -------
if [ ! -f "$AMPS" ]; then
  sk "amps.sh not found under $execDir - _cscap, emit_native, pick_outdir, proof_available not graded"
else
  # _cscap is written on ONE line, closing brace and all, so a /^}/ range never terminates and the
  # lift comes back empty - which then reads as "_cscap returned nothing" for every input.
  _cs=$(grep '^_cscap()' "$AMPS")
  case "$_cs" in *'}'*) ;; *) _cs=$(sed -n '/^_cscap()/,/^}/p' "$AMPS");; esac
  if [ -z "$_cs" ]; then
    no "_cscap could not be lifted from $AMPS"
  else
    cscap(){ ( _csr(){ echo "$1"; }
               eval "$_cs"
               _cscap "$1" ) 2>/dev/null; }
    printf '  %-14s %s\n' input output
    for v in 2000000 150000 100000 99999 50000 0 '' abc -1; do
      printf '  %-14s %s\n' "${v:-(empty)}" "$(cscap "$v")"
    done
    [ "$(cscap 2000000)" = 2000 ] \
      && ok "_cscap scales 2000000 uA to 2000 mA" || no "_cscap gave $(cscap 2000000) for 2000000"
    [ "$(cscap 100000)" = 100 ] \
      && ok "_cscap scales at the 100000 boundary" || no "_cscap gave $(cscap 100000) at the boundary"
    [ "$(cscap 99999)" = 99999 ] \
      && ok "_cscap passes 99999 through, so a mA reading is not divided again" \
      || no "_cscap divided a value below the boundary ($(cscap 99999))"
    [ "$(cscap '')" = 0 ] && [ "$(cscap abc)" = 0 ] && [ "$(cscap -1)" = 0 ] \
      && ok "an empty, non-numeric or negative reading answers 0 rather than aborting arithmetic" \
      || no "_cscap did not coerce garbage to 0 (empty=$(cscap ''), abc=$(cscap abc), -1=$(cscap -1))"
  fi

  # ---- 2. emit_native: this list is what puts a phone BACK. A wrong value here leaves it cut ------
  _en=$(sed -n '/^emit_native(){/,/^EOF$/p' "$AMPS")
  if [ -z "$_en" ]; then
    no "emit_native could not be lifted"
  else
    _body=$(printf '%s\n' "$_en" | sed '1,/<<EOF/d;/^EOF$/,$d')
    _lines=$(printf '%s\n' "$_body" | grep -c '[^[:space:]]')
    [ "${_lines:-0}" -gt 10 ] \
      && ok "emit_native lists $_lines release nodes" || no "emit_native lists only ${_lines:-0} nodes"
    _bad=$(printf '%s\n' "$_body" | awk 'NF && NF != 2 { c++ } END { print c+0 }')
    [ "$_bad" = 0 ] \
      && ok "every line is exactly 'node value', so the caller cannot misparse one" \
      || no "$_bad line(s) are not a node/value pair"
    # Two kinds of node live in this list: boolean cut/enable flags, which release at 0 or 1, and
    # LEVEL nodes, which release by being set to a value that never stops a charge (stop 100,
    # start 99, -1 for the qpnp adaptive-charge limit). Demanding 0/1 everywhere fails the level
    # nodes for being correct.
    _badv=$(printf '%s\n' "$_body" | awk '
      NF == 2 {
        n = tolower($1)
        lvl = (n ~ /charge_stop_level|charge_start_level|charge_control_end_threshold|batt_full_capacity|upper_limit/)
        if (!lvl && $2 != 0 && $2 != 1) c++
      } END { print c+0 }')
    [ "$_badv" = 0 ] \
      && ok "every boolean node releases at 0 or 1" \
      || no "$_badv boolean line(s) carry a value that is neither 0 nor 1"
    _badl=$(printf '%s\n' "$_body" | awk '
      NF == 2 {
        n = tolower($1)
        if (n ~ /charge_stop_level|charge_control_end_threshold|batt_full_capacity/ && $2 != 100) c++
        if (n ~ /charge_start_level/ && $2 != 99) c++
        if (n ~ /upper_limit/ && $2 != -1) c++
      } END { print c+0 }')
    [ "$_badl" = 0 ] \
      && ok "every LEVEL node releases to a value that never stops a charge (stop 100, start 99, limit -1)" \
      || no "$_badl level node(s) would be left holding a limit after a restore"
    # The polarity is the whole point: a *suspend*/*disable* node releases at 0, an *enable* node at 1.
    _flip=$(printf '%s\n' "$_body" | awk '
      NF == 2 {
        n = tolower($1)
        if ((n ~ /suspend|disable|slate|night_charging|interruption|bypass|limit_en/) && $2 != 0) c++
        if ((n ~ /charging_enabled|charging_enable|enable_charger|charge_enable/) && $2 != 1) c++
      } END { print c+0 }')
    [ "$_flip" = 0 ] \
      && ok "release polarity is right on every node: suspend/disable release at 0, enable at 1" \
      || no "$_flip node(s) carry the wrong release polarity - a restore would leave charging cut"
    _dup=$(printf '%s\n' "$_body" | awk 'NF==2 { print $1 }' | sort | uniq -d | wc -l)
    [ "${_dup:-0}" = 0 ] \
      && ok "no node appears twice, so no line can overwrite an earlier one" \
      || no "${_dup} node(s) appear more than once"
  fi

  # ---- 3. pick_outdir: must always answer with a directory that can be written ---------------------
  _po=$(sed -n '/^pick_outdir(){/,/^}/p' "$AMPS")
  if [ -z "$_po" ]; then
    no "pick_outdir could not be lifted"
  else
    _T=/data/local/tmp/.t153-out; rm -rf $_T; mkdir -p $_T/good
    _got=$( ( eval "$_po"
              EXTERNAL_STORAGE=; HOME=; SRCDIR=; TMPD=$_T/good
              HOME=$_T/missing
              pick_outdir ) 2>/dev/null )
    if [ -n "$_got" ] && [ -d "$_got" ] && ( : > "$_got/.t153w" ) 2>/dev/null; then
      rm -f "$_got/.t153w"
      ok "pick_outdir answered with a writable directory ($_got)"
    else
      no "pick_outdir answered '$_got', which is not a writable directory"
    fi
    # With nothing writable anywhere it must still answer, with the fallback rather than empty.
    _fb=$( ( eval "$_po"
             EXTERNAL_STORAGE=; HOME=; SRCDIR=; TMPD=$_T/good
             pick_outdir ) 2>/dev/null )
    [ -n "$_fb" ] && ok "it never answers empty, so the caller cannot build a path at /" \
                  || no "pick_outdir answered empty"
    printf '%s\n' "$_po" | grep -q 'printf .%s. "\$TMPD"' \
      && ok "the last resort is \$TMPD, which the script owns" \
      || no "the fallback is not \$TMPD"
    rm -rf $_T
  fi

  # ---- 4. proof_available: what counts as a charge actually happening -----------------------------
  _pa=$(sed -n '/^proof_available(){/,/return 1; }/p' "$AMPS")
  if [ -z "$_pa" ]; then
    no "proof_available could not be lifted"
  else
    # Every stub reads _st/_ct/_cur from the enclosing scope. A function defined in here has its
    # OWN $1..$n, so a stub written as `echo "$3"` returns the stub's third argument - nothing -
    # and the whole matrix answers the same way whatever it is handed.
    pa(){ # $1 status, $2 charge_type verdict, $3 current, $4 VRISE -> YES | NO
      ( eval "$_pa"
        _st=$1; _ct=$2; _cur=$3
        read_st(){ echo "$_st"; }
        ex(){ return 0; }
        chg_type(){ echo x; }
        ctype_charging(){ echo "$_ct"; }
        abs(){ _a=${1#-}; echo "$_a"; }
        rd_current(){ echo "$_cur"; }
        CHGIN=usb; IDLE=10000; VRISE=$4
        if proof_available; then echo YES; else echo NO; fi ) 2>/dev/null
    }
    # The stub set must be able to answer both ways before the matrix means anything.
    [ "$(pa Charging 0 0 0)" != "$(pa Discharging 0 0 0)" ] \
      && ok "the proof_available stubs discriminate" \
      || no "the proof_available stubs answer identically - the matrix below is constant"
    [ "$(pa Charging 0 0 0)" = YES ] && ok "a Charging status is proof" || no "Charging was not proof"
    [ "$(pa Discharging 1 0 0)" = YES ] && ok "a charging charge_type is proof" || no "charge_type was not proof"
    [ "$(pa Discharging 0 500000 0)" = YES ] && ok "a current above the idle threshold is proof" || no "current was not proof"
    [ "$(pa Discharging 0 0 1)" = YES ] && ok "a rising voltage is proof" || no "VRISE was not proof"
    [ "$(pa Discharging 0 0 0)" = NO ] \
      && ok "none of the four means NO proof, so AMPS does not grade a switch on a dead charger" \
      || no "proof_available answered YES with no evidence at all"
    [ "$(pa Discharging 0 5000 0)" = NO ] \
      && ok "a current below the idle threshold is not proof" || no "an idle current counted as proof"
  fi
fi

# ---- 5. acc-compat.sh is generated from amps.sh: the two copies must not drift -------------------
if [ ! -f "$COMPAT" ] || [ ! -f "$AMPS" ]; then
  sk "acc-compat.sh or amps.sh missing - drift not graded"
else
  _drift=0
  for _fn in _cscap emit_native pick_outdir proof_available; do
    _a=$(sed -n "/^${_fn}()/,/^}/p" "$AMPS" | md5sum | cut -d' ' -f1)
    _b=$(sed -n "/^${_fn}()/,/^}/p" "$COMPAT" | md5sum | cut -d' ' -f1)
    [ "$_a" = "$_b" ] || { _drift=$((_drift+1)); echo "      drift: $_fn"; }
  done
  [ "$_drift" = 0 ] \
    && ok "all four shared helpers are byte-identical in amps.sh and acc-compat.sh" \
    || no "$_drift helper(s) have drifted between the two copies"
fi

# ---- 6. acc.sh:set_prop_ must forward EVERY argument ---------------------------------------------
if [ ! -f "$ACC" ]; then
  sk "acc.sh not found"
else
  _sp=$(sed -n '/^set_prop_() {/,/^}/p' "$ACC")
  [ -n "$_sp" ] || no "set_prop_ could not be lifted"
  printf '%s' "$_sp" | grep -q 'set_prop "\$@"' \
    && ok "set_prop_ forwards \"\$@\", so a multi-key set cannot lose its tail" \
    || no "set_prop_ does not forward \"\$@\" - a call like 'acc -s a=1 b=2' would drop b=2"
  printf '%s' "$_sp" | grep -q '\. \$execDir/set-prop.sh' \
    && ok "it sources set-prop.sh from \$execDir rather than the caller's directory" \
    || no "set_prop_ does not source \$execDir/set-prop.sh"
  # Drive the forwarding, which is the part a reader gets wrong.
  _fwd=$( ( set_prop(){ echo "$#:$*"; }
            execDir=/nonexistent
            . /dev/null
            set_prop_(){ set_prop "$@"; }
            set_prop_ --print a=1 b=2 ) 2>/dev/null )
  [ "$_fwd" = "3:--print a=1 b=2" ] \
    && ok "the forwarding form passes all three arguments through" \
    || no "the forwarding form gave '$_fwd'"
fi

# ---- 7. set-ch-volt.sh:apply_voltage -------------------------------------------------------------
if [ ! -f "$SCV" ]; then
  sk "set-ch-volt.sh not found"
else
  _av=$(sed -n '/apply_voltage() {/,/^    }/p' "$SCV")
  [ -n "$_av" ] || no "apply_voltage could not be lifted"
  printf '%s' "$_av" | grep -q 'ch-volt-ctrl-files.ok' \
    && ok "apply_voltage records the entries that actually HELD, separately from the ones it tried" \
    || no "apply_voltage does not record which entries held"
  printf '%s' "$_av" | grep -q '_mcvWasFV=true' \
    && ok "it marks an FV votable, so a vote that never holds can be told from a mirror failure" \
    || no "the FV marker is gone - t145's fallback cannot work"
  printf '%s' "$_av" | grep -q 'if \[ "\$(cat "\$_mcvf" 2>/dev/null)" = "\$_mcvt" \]' \
    && ok "a held entry is confirmed by READING THE NODE BACK, not by the write returning 0" \
    || no "apply_voltage trusts the write instead of reading the node back"
  printf '%s' "$_av" | grep -q 'awk -F.::. -v p=' \
    && ok "the discovery marker is preserved from ch-volt-ctrl-files rather than guessed from digits" \
    || no "the unit marker is reconstructed by guessing, which turns a uV default into 4150"
fi

# ---- 8. strings.sh: the two helpers, and the load order that lets a partial translation exist -----
if [ ! -f "$STR" ]; then
  sk "strings.sh not found"
else
  grep -q '^print_help() {' "$STR" \
    && ok "print_help is defined in the base strings.sh" || no "print_help is missing"
  grep -q '^print_restart_accd() {' "$STR" \
    && ok "print_restart_accd is defined in the base strings.sh" || no "print_restart_accd is missing"
  printf '%s' "$(sed -n '/^print_restart_accd() {/,/^}/p' "$STR")" | grep -q 'acc -f 0' \
    && ok "print_restart_accd names the command that ends the mode early" \
    || no "print_restart_accd no longer tells the user how to end the mode"
  # Only the base file defines print_restart_accd; no translation does. That is safe ONLY because
  # acc.sh sources the base file FIRST and lets a translation override what it chooses to carry.
  # Reverse that order and every non-English user gets an undefined function under set -eu.
  _base=$(grep -n '^\. \$execDir/strings.sh' "$ACC" 2>/dev/null | head -1 | cut -d: -f1)
  _tr=$(grep -n '\. \$execDir/translations/\$language/strings.sh' "$ACC" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$_base" ] && [ -n "$_tr" ]; then
    if [ "$_base" -lt "$_tr" ] 2>/dev/null; then
      ok "acc.sh sources the base strings at line $_base before the translation at line $_tr, so a partial translation falls back instead of failing"
    else
      no "the translation is sourced at $_tr BEFORE the base at $_base - a translation missing print_restart_accd would leave it undefined"
    fi
  else
    no "could not locate both strings.sh sources in acc.sh"
  fi
  _missing=0
  for _t in ${execDir}/translations/*/strings.sh; do
    [ -f "$_t" ] || continue
    grep -q '^print_restart_accd() {' "$_t" || _missing=$((_missing+1))
  done
  echo "      translations without their own print_restart_accd: $_missing (each falls back to the base)"
fi

fin
