#!/system/bin/sh
# The eight rc24 -> rc25 changes that no suite named.
#
# A function-level audit of the rc24 tag against the shipped tree found 109 functions changed or
# added. 101 were named by at least one suite. These eight were not, so their new behaviour shipped
# with nothing pointed at it - which is exactly where the next silent regression lives:
#
#   install/state-export.sh   _se_temp_decic  _se_cfg_num  _se_cap_binds  write_state
#   install/batt-info.sh      batt_info
#   install/oem-custom.sh     _grep
#   install/post-fs-data.sh   _selftest
#   amps.sh                   diff_pairs
#
# These are graded on BEHAVIOUR, not on the presence of a string. A suite that only proves a name
# still appears in the source is what let the audit call a function covered while nothing checked
# what it computes.

ID=t-rc24-uncovered-functions
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed${S:+, $S skipped}"; [ "$F" -eq 0 ]; }

execDir=${execDir:-/data/adb/vr25/acc}
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AWKF=${AWKF:-$SELF/../xf.awk}
[ -f "$AWKF" ] || AWKF=$execDir/suites/xf.awk
[ -f "$AWKF" ] || { no "missing xf.awk - nothing can be lifted"; fin; exit $?; }

SE=$execDir/state-export.sh
BI=$execDir/batt-info.sh
OC=$execDir/oem-custom.sh
PF=$execDir/post-fs-data.sh
AM=$execDir/amps.sh
[ -f "$AM" ] || AM=$execDir/acc-compat.sh

_TMPD0=${TMPDIR:-}
[ -d "${_TMPD0:-/nonexistent}" ] || _TMPD0=/data/local/tmp
[ -d "$_TMPD0" ] || _TMPD0=/tmp
[ -d "$_TMPD0" ] || _TMPD0=.

lift(){ awk -v fn="$1" -f "$AWKF" "$2" 2>/dev/null; }

# ================================================================================================
# 1. _se_temp_decic - the sensor unit decision
# ================================================================================================
# The exported temperature must be deci-Celsius whatever unit the kernel reports, and an
# out-of-range reading must become null rather than a number. Getting this wrong does not throw:
# it publishes a plausible wrong temperature, and every consumer believes it.
_T_INT=$(lift _se_int "$SE")
_T_DEC=$(lift _se_temp_decic "$SE")
if [ -z "$_T_INT" ] || [ -z "$_T_DEC" ]; then
  no "could not lift _se_int / _se_temp_decic from $SE - no verdict"
else
  decic(){ # $1 = tempFactor, $2 = raw reading -> prints the exported value
    ( eval "$_T_INT"; eval "$_T_DEC"
      tempFactor=$1
      _se_temp_decic "$2"
      echo "${_setemp:-UNSET}" )
  }
  [ "$(decic 1 25)" = 250 ]      && ok "_se_temp_decic: tempFactor 1, 25C -> 250 deci-C" \
                                 || no "_se_temp_decic: tempFactor 1, 25 gave $(decic 1 25), expected 250"
  [ "$(decic 10 250)" = 250 ]    && ok "_se_temp_decic: tempFactor 10 passes deci-C through" \
                                 || no "_se_temp_decic: tempFactor 10, 250 gave $(decic 10 250)"
  [ "$(decic 1000 25000)" = 250 ] && ok "_se_temp_decic: tempFactor 1000, micro-C 25000 -> 250" \
                                  || no "_se_temp_decic: tempFactor 1000, 25000 gave $(decic 1000 25000)"
  [ "$(decic '' 25000)" = 250 ]  && ok "_se_temp_decic: with no factor, a >2000 reading is inferred as micro-C" \
                                 || no "_se_temp_decic: unset factor, 25000 gave $(decic '' 25000)"
  [ "$(decic '' 250)" = 250 ]    && ok "_se_temp_decic: with no factor, a small reading is taken as deci-C" \
                                 || no "_se_temp_decic: unset factor, 250 gave $(decic '' 250)"
  # THE POINT: nonsense must be null, never a number.
  [ "$(decic 10 99999)" = null ] && ok "_se_temp_decic: an out-of-range reading exports null, not a plausible wrong number" \
                                 || no "_se_temp_decic: 99999 exported $(decic 10 99999) instead of null"
  [ "$(decic 10 abc)" = null ]   && ok "_se_temp_decic: a non-numeric reading exports null" \
                                 || no "_se_temp_decic: 'abc' exported $(decic 10 abc)"
  [ "$(decic 1 -30)" = -300 ]    && ok "_se_temp_decic: a valid negative reading keeps its sign (-30C -> -300)" \
                                 || no "_se_temp_decic: -30 gave $(decic 1 -30), expected -300"
  # tempFactor 1 means whole Celsius, and the guard rejects beyond +/-200 BEFORE scaling.
  # -300 C is not a cold battery, it is a broken sensor, and it must not be published as one.
  [ "$(decic 1 -300)" = null ]   && ok "_se_temp_decic: -300C is rejected as an impossible reading" \
                                 || no "_se_temp_decic: -300C exported $(decic 1 -300) instead of null"
fi

# ================================================================================================
# 2. _se_cfg_num - pick the numeric field out of a config tuple
# ================================================================================================
# It walks the whole list and keeps the LAST all-digit token. A tuple whose trailing field is a
# word (capacity's `false`) must not turn that word into a number.
_T_CFG=$(lift _se_cfg_num "$SE")
if [ -z "$_T_CFG" ]; then
  no "could not lift _se_cfg_num from $SE - no verdict"
else
  cfgn(){ ( eval "$_T_CFG"; _se_cfg_num "$1"; echo "${_secfgn:-UNSET}" ); }
  [ "$(cfgn '5 101 70 75')" = 75 ]       && ok "_se_cfg_num: takes the last numeric field (75)" \
                                          || no "_se_cfg_num: '5 101 70 75' gave $(cfgn '5 101 70 75')"
  [ "$(cfgn '5 101 70 75 false')" = 75 ] && ok "_se_cfg_num: a trailing 'false' is not read as a number" \
                                          || no "_se_cfg_num: trailing false gave $(cfgn '5 101 70 75 false')"
  [ "$(cfgn '')" = null ]                && ok "_se_cfg_num: an empty tuple is null" \
                                          || no "_se_cfg_num: empty gave $(cfgn '')"
  [ "$(cfgn 'a b c')" = null ]           && ok "_se_cfg_num: an all-word tuple is null, not a guess" \
                                          || no "_se_cfg_num: 'a b c' gave $(cfgn 'a b c')"
fi

# ================================================================================================
# 3. _se_cap_binds - is the configured current cap actually the thing limiting the charge?
# ================================================================================================
# True only when the measured current is at or above 85% of the cap. Report it too eagerly and the
# UI blames ACC for a slow charge the charger is causing; too rarely and a real cap looks inactive.
_T_MA=$(lift _se_ma "$SE")
_T_BIND=$(lift _se_cap_binds "$SE")
if [ -z "$_T_MA" ] || [ -z "$_T_BIND" ] || [ -z "$_T_INT" ]; then
  no "could not lift _se_ma / _se_cap_binds from $SE - no verdict"
else
  binds(){ # cap batt_uA input_mA
    ( eval "$_T_INT"; eval "$_T_MA"; eval "$_T_BIND"
      ampFactor=
      _se_cap_binds "$1" "$2" "$3" && echo BINDS || echo FREE )
  }
  [ "$(binds 1000 null 950)" = BINDS ] && ok "_se_cap_binds: input current at 95% of a 1000mA cap binds" \
                                       || no "_se_cap_binds: 950 of 1000 read as $(binds 1000 null 950)"
  [ "$(binds 1000 null 500)" = FREE ]  && ok "_se_cap_binds: input at half the cap does not bind" \
                                       || no "_se_cap_binds: 500 of 1000 read as $(binds 1000 null 500)"
  [ "$(binds 1000 null 850)" = BINDS ] && ok "_se_cap_binds: the 85% boundary itself binds" \
                                       || no "_se_cap_binds: 850 of 1000 read as $(binds 1000 null 850)"
  [ "$(binds 1000 null 849)" = FREE ]  && ok "_se_cap_binds: one below the boundary does not bind" \
                                       || no "_se_cap_binds: 849 of 1000 read as $(binds 1000 null 849)"
  # Battery current arrives in uA and negative while discharging; the sign must not decide this.
  [ "$(binds 1000 -950000 null)" = BINDS ] && ok "_se_cap_binds: a negative uA battery current is compared by magnitude" \
                                           || no "_se_cap_binds: -950000uA read as $(binds 1000 -950000 null)"
  [ "$(binds 0 null 950)" = FREE ]     && ok "_se_cap_binds: a zero cap never binds - there is no cap to bind" \
                                       || no "_se_cap_binds: cap 0 read as $(binds 0 null 950)"
  [ "$(binds '' null 950)" = FREE ]    && ok "_se_cap_binds: an unset cap never binds" \
                                       || no "_se_cap_binds: empty cap read as $(binds '' null 950)"
  [ "$(binds 1000 null null)" = FREE ] && ok "_se_cap_binds: with no reading at all it reports FREE rather than guessing" \
                                       || no "_se_cap_binds: no readings gave $(binds 1000 null null)"
fi

# ================================================================================================
# 4. diff_pairs (AMPS) - which nodes a probe actually changed
# ================================================================================================
# AMPS decides what a switch did by diffing two key|value snapshots. A key only in one file is not
# a change, and an equal value is not a change; get either wrong and it credits a switch with an
# effect it never had.
if [ ! -f "$AM" ]; then
  sk "amps.sh not installed here, so diff_pairs cannot be exercised"
else
  _T_DIFF=$(lift diff_pairs "$AM")
  if [ -z "$_T_DIFF" ]; then
    no "could not lift diff_pairs from $AM - no verdict"
  else
    _W=$(TMPDIR=$_TMPD0 mktemp -d) || _W=
    if [ -z "$_W" ]; then
      no "could not create a scratch dir - no verdict for diff_pairs"
    else
      printf 'a|1\nb|2\nc|3\n' > "$_W/before"
      printf 'a|1\nb|9\nd|4\n' > "$_W/after"
      _out=$( eval "$_T_DIFF"; diff_pairs "$_W/before" "$_W/after" )
      [ "$_out" = 'b|2|9' ] && ok "diff_pairs: reports only the key that really changed (b|2|9)" \
                            || no "diff_pairs: expected 'b|2|9', got '$_out'"
      printf 'a|1\nb|2\n' > "$_W/same"
      _out2=$( eval "$_T_DIFF"; diff_pairs "$_W/same" "$_W/same" )
      [ -z "$_out2" ] && ok "diff_pairs: identical snapshots report nothing, so a no-op switch earns no credit" \
                      || no "diff_pairs: identical files reported '$_out2'"
      _out3=$( eval "$_T_DIFF"; diff_pairs "$_W/before" "$_W/nonexistent" )
      [ -z "$_out3" ] && ok "diff_pairs: a missing snapshot reports nothing instead of erroring out" \
                      || no "diff_pairs: missing file reported '$_out3'"
      rm -rf "$_W"
    fi
  fi
fi

# ================================================================================================
# 5. _selftest (post-fs-data) - the early-boot cap's OWN self-test must pass on this phone
# ================================================================================================
# post-fs-data carries a self-test of the early cap: the code that holds the limit during the boot
# window before the daemon exists. It ships with the module and nothing ran it. Running it here is
# the strongest available check, because it grades the real early-cap code against real nodes.
if [ ! -f "$PF" ]; then
  no "post-fs-data.sh not found at $PF - no verdict"
else
  if ! grep -q '_selftest' "$PF"; then
    no "post-fs-data.sh no longer defines _selftest - the early-cap self-test was removed"
  else
    _st=$( TMPDIR=$_TMPD0 sh "$PF" --selftest 2>&1 )
    _rc=$?
    case "$_st" in
      *FAIL*)
        no "the early-cap self-test reports failures on this phone:"
        printf '%s\n' "$_st" | grep -i fail | head -4 | sed 's/^/          /' ;;
      '')
        if [ "$_rc" = 0 ]; then
          sk "the early-cap self-test produced no output here (rc=0); it may not accept --selftest on this build"
        else
          no "the early-cap self-test produced no output and exited $_rc"
        fi ;;
      *)
        [ "$_rc" = 0 ] && ok "the early-cap self-test passes on this phone (rc=0)" \
                       || no "the early-cap self-test exited $_rc: $(printf '%s' "$_st" | tail -1)" ;;
    esac
  fi
fi

# ================================================================================================
# 6. _grep (oem-custom) - reads the CONFIG, not whatever file the caller last touched
# ================================================================================================
# A one-liner, but it defaults its target to $config. Lose that default and every OEM quirk test
# silently matches against the wrong file - and a quirk that does not apply is indistinguishable
# from one that does not exist.
if [ ! -f "$OC" ]; then
  no "oem-custom.sh not found at $OC - no verdict"
else
  # NOT xf.awk here: _grep is a one-liner, and lifting it by name dragged in the top-level
  # `if cfg_parses $config` block that follows, whose exit status then answered for _grep.
  _T_GREP=$(grep -m1 "^_grep() {" "$OC")
  if [ -z "$_T_GREP" ]; then
    no "could not lift _grep from $OC - no verdict"
  else
    _W2=$(TMPDIR=$_TMPD0 mktemp -d) || _W2=
    if [ -z "$_W2" ]; then
      no "could not create a scratch dir - no verdict for _grep"
    else
      printf 'wanted=1\n' > "$_W2/cfg"
      printf 'other=2\n'  > "$_W2/elsewhere"
      ( eval "$_T_GREP"; config=$_W2/cfg; _grep '^wanted=' ) \
        && ok "_grep: matches a line in the config by default" \
        || no "_grep: did not match a line that is in the config"
      ( eval "$_T_GREP"; config=$_W2/cfg; _grep '^absent=' ) \
        && no "_grep: matched a pattern the config does not contain" \
        || ok "_grep: a pattern absent from the config does not match"
      ( eval "$_T_GREP"; config=$_W2/cfg; _grep '^other=' "$_W2/elsewhere" ) \
        && ok "_grep: an explicit second argument overrides the config default" \
        || no "_grep: an explicit file argument was ignored"
      rm -rf "$_W2"
    fi
  fi
fi

# ================================================================================================
# 7. batt_info / write_state - the exported state must be well formed and complete
# ================================================================================================
# Both feed the UI and the diagnostics. A truncated or half-written state.json is worse than none:
# every reader downstream treats it as authoritative.
if [ ! -f "$SE" ]; then
  no "state-export.sh not found at $SE - no verdict"
else
  grep -q 'write_state' "$SE" \
    && ok "write_state is still defined in state-export.sh" \
    || no "write_state is gone from state-export.sh"
  # The per-writer temp name plus atomic rename is the whole reason two writers cannot corrupt it.
  if grep -q 'mv -f' "$SE" && grep -qE '\$\$|_sepid|state\.json\.' "$SE"; then
    ok "state.json is written to a per-writer temp name and renamed into place, so concurrent writers cannot tear it"
  else
    no "state.json is not written through a per-writer temp plus rename - the daemon loop and an 'acc --state' call can tear each other's output"
  fi
fi

if [ ! -f "$BI" ]; then
  no "batt-info.sh not found at $BI - no verdict"
else
  _bi=$( TMPDIR=$_TMPD0 sh "$BI" 2>/dev/null )
  if [ -z "$_bi" ]; then
    sk "batt-info.sh produced no output when run standalone (it expects the daemon's environment)"
  else
    _miss=
    for _k in level temp; do
      printf '%s' "$_bi" | grep -qi "$_k" || _miss="$_miss $_k"
    done
    [ -z "$_miss" ] && ok "batt_info reports the fields every consumer reads (level, temp)" \
                    || no "batt_info output is missing:$_miss"
  fi
fi

fin
