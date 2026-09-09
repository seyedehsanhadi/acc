#!/system/bin/sh
# ab-all-changes.sh <root> - every behavioural change from the GitHub baseline, A vs B, one line each.
#
#   sh ab-all-changes.sh /data/local/tmp/ab        # expects <root>/acc-a (rc24) and <root>/acc-b (rc25)
#
# Output: <unit-id> <TAB> <A result> <TAB> <B result>. A difference is a behavioural change; identical
# values mean the change was internal only. Nothing here writes to /sys or touches the daemon, so it
# runs on an unplugged phone. "n/a" means the function does not exist in that arm.
#
# Units map to the diff hunks; ids are stable so a later run can be compared line by line.

R=${1:-/data/local/tmp/ab}
W=$(mktemp -d "${TMPDIR:-/data/local/tmp}/ab-all.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT HUP INT TERM
wnl(){ mkdir -p "${1%/*}"; printf '%s\n' "$2" > "$1"; }
wnn(){ mkdir -p "${1%/*}"; printf '%s' "$2" > "$1"; }

for arm in a b; do
  E=$R/acc-$arm/install
  A=$R/acc-$arm/amps.sh
  O=$W/out.$arm; : > "$O"
  e(){ printf '%s\t%s\n' "$1" "$2" >> "$O"; }

  # ---------- AMPS ---------------------------------------------------------------------------------
  ( AMPS=$A
    eval "$(grep -E '^(ex|rd|read1|san|abs|sgn)\(\)' "$AMPS")"
    eval "$(sed -n '/^med3(){/,/^}/p' "$AMPS")"
    eval "$(sed -n '/^_norm(){/,/esac; }/p' "$AMPS" | sed -n '1,3p')"
    eval "$(sed -n '/^classify_state(){/,/esac; }/p' "$AMPS")"
    eval "$(sed -n '/^node_unit(){/,/^}/p' "$AMPS")" 2>/dev/null
    eval "$(grep -E '^(rd_current|rd_ma|counter_value|voltage_uv|voltage_mv|power_mw|_mA|is_idle)\(\)' "$AMPS")" 2>/dev/null
    HAVE_TO=0; log(){ :; }
    P=$W/psy.$arm; BATT=$P/battery; PSY=$P; CURF=$BATT/current_now; CHGIN=$P/usb/input_current_now
    wnl "$BATT/current_now" -895; wnl "$P/bms/current_now" -822265
    wnl "$BATT/constant_charge_current_max" 5400000; wnl "$CHGIN" 1189550
    wnl "$BATT/charge_counter" 2520000; wnl "$BATT/voltage_now" 4160000

    has(){ command -v "$1" >/dev/null 2>&1; }

    # A02 is_idle must not treat an unreadable current as idle
    has is_idle && { IDLE=10000; printf 'A02\t%s\n' "$(is_idle unknown)"; } || printf 'A02\tn/a\n'
    # A03 per-node unit resolution (OnePlus 7 Pro shape: mA battery beside a uA gauge)
    has node_unit && printf 'A03\t%s\n' "$(ST_UNIT= CUR_UNIT= node_unit "$CURF")" || printf 'A03\tn/a\n'
    # A03b the input node on the same phone is uA
    has node_unit && printf 'A03b\t%s\n' "$(CHGIN_UNIT= node_unit "$CHGIN")" || printf 'A03b\tn/a\n'
    # A03c OnePlus 8 Pro shape: no bms at all
    if has node_unit; then
      rm -f "$P/bms/current_now"; wnl "$BATT/current_now" -1500; wnl "$CHGIN" 1650000
      printf 'A03c\t%s\n' "$(ST_UNIT= CUR_UNIT= node_unit "$CURF")"
      # A03d a uA phone idling while the charger runs the load must stay unresolved
      wnl "$BATT/current_now" -8000; wnl "$CHGIN" 2000000
      printf 'A03d\t%s\n' "$(ST_UNIT= CUR_UNIT= node_unit "$CURF")"
      wnl "$BATT/current_now" -895; wnl "$P/bms/current_now" -822265; wnl "$CHGIN" 1189550
    else printf 'A03c\tn/a\nA03d\tn/a\n'; fi
    # A04 the old unit block: what does the baseline decide for the reported phone?
    if has node_unit; then
      printf 'A04\t%s\n' "$(ST_UNIT= CUR_UNIT= rd_ma "$CURF" 2>/dev/null || echo unreadable)"
    else
      RAW=$(san "$(read1 "$CURF")"); ABSB=${RAW#-}; U=mA
      [ "$ABSB" -ge 16000 ] 2>/dev/null && U=uA
      if [ "$U" = mA ]; then for u in "$BATT/constant_charge_current_max" $PSY/*/current_max; do
        ex "$u" || continue; uv=$(san "$(read1 "$u")"); [ "${uv#-}" -ge 100000 ] 2>/dev/null && { U=uA; break; }; done; fi
      printf 'A04\t%s(unit=%s)\n' "$RAW" "$U"
    fi
    # A05 the reported baseline verdict
    if has rd_current; then
      printf 'A05\t%s\n' "$(classify_state 1 1 "$(ST_UNIT= CUR_UNIT= rd_current "$CURF" 2>/dev/null || echo unknown)" inverted 10000)"
    else
      RAW=$(san "$(read1 "$CURF")"); I=10; [ "$ABSB" -ge 16000 ] 2>/dev/null && I=10000
      for u in "$BATT/constant_charge_current_max"; do uv=$(san "$(read1 "$u")"); [ "${uv#-}" -ge 100000 ] 2>/dev/null && I=10000; done
      printf 'A05\t%s\n' "$(classify_state 1 1 "$RAW" inverted "$I")"
    fi
    # A06 classify_state: garbage, and a hair below zero while online
    printf 'A06\t%s\n' "$(classify_state 1 1 garbage normal 10000)"
    printf 'A06b\t%s\n' "$(classify_state 1 1 -1 normal 10000)"
    printf 'A06c\t%s\n' "$(classify_state 1 1 895000 inverted 10000)"
    # A07 counter validation: a reset, a huge jump, a negative
    if has counter_value; then
      wnl "$BATT/charge_counter" 0;        printf 'A07\t%s\n' "$(counter_value "$BATT/charge_counter" || echo rejected)"
      wnl "$BATT/charge_counter" -5;       printf 'A07b\t%s\n' "$(counter_value "$BATT/charge_counter" || echo rejected)"
      wnl "$BATT/charge_counter" 99999999999; printf 'A07c\t%s\n' "$(counter_value "$BATT/charge_counter" || echo rejected)"
      wnl "$BATT/charge_counter" 2520000
    else printf 'A07\tn/a\nA07b\tn/a\nA07c\tn/a\n'; fi
    # A08 voltage helpers
    has voltage_mv && { wnl "$BATT/voltage_now" 4160000; printf 'A08\t%s\n' "$(voltage_mv "$BATT/voltage_now")"
                        wnl "$BATT/voltage_now" 50001;   printf 'A08b\t%s\n' "$(voltage_mv "$BATT/voltage_now")"
                        wnl "$BATT/voltage_now" 4160000; } || printf 'A08\tn/a\nA08b\tn/a\n'
    # A09 overflow-safe power
    has power_mw && printf 'A09\t%s\n' "$(power_mw 9000000 2000000)" || printf 'A09\tn/a\n'
    has power_mw && printf 'A09b\t%s\n' "$(power_mw 99999999999 2000000)" || printf 'A09b\tn/a\n'
    # A10 display conversion of an unreadable current
    has _mA && printf 'A10\t%s\n' "$(_mA unknown)" || printf 'A10\tn/a\n'
    has _mA && printf 'A10b\t%s\n' "$(_mA -895000)" || printf 'A10b\tn/a\n'
    # A11 a node with a unit suffix, and one with none
    if has rd_current; then
      wnn "$BATT/current_now" '-895 mA'; printf 'A11\t%s\n' "$(CUR_UNIT=mA rd_ma "$CURF" 2>/dev/null || echo rejected)"
      wnn "$BATT/current_now" -895;      printf 'A11b\t%s\n' "$(CUR_UNIT=mA rd_ma "$CURF" 2>/dev/null || echo rejected)"
      wnl "$BATT/current_now" -895
    else printf 'A11\tn/a\nA11b\tn/a\n'; fi
  ) >> "$O" 2>/dev/null

  # ---------- ACC ----------------------------------------------------------------------------------
  ( . "$E/state-export.sh" 2>/dev/null || exit
    for fn in current_now current_factor temperature_now volt_now cc_now status idle_discharging; do
      eval "$(sed -n "/^$fn() {/,/^}/p" "$E/batt-interface.sh")" 2>/dev/null || :
    done
    eval "$(sed -n '/^_iin_ma() {/,/^}/p' "$E/misc-functions.sh")" 2>/dev/null || :
    eval "$(sed -n '/^_vbus_mv() {/,/^}/p' "$E/misc-functions.sh")" 2>/dev/null || :
    has(){ command -v "$1" >/dev/null 2>&1; }
    D=$W/acc.$arm; mkdir -p "$D/battery" "$D/usb" "$D/bms"; cd "$D" || exit
    TMPDIR=$D; dataDir=$D; ACC_PSY=$D
    currFile=$D/battery/current_now; temp=$D/battery/temp; voltNow=$D/battery/voltage_now
    battCapacity=$D/battery/capacity; battStatus=$D/battery/status
    cur(){ has current_now && current_now || cat "$currFile" 2>/dev/null; }
    tmp_(){ has temperature_now && temperature_now || cat "$temp" 2>/dev/null; }

    # C01 a node with no trailing newline
    wnn "$currFile" -895;  printf 'C01\t%s\n' "$(cur)"
    wnl "$currFile" -895;  printf 'C01b\t%s\n' "$(cur)"
    # C02 temperature scales
    wnl "$temp" 250;    printf 'C02\t%s\n' "$(tmp_)"
    wnl "$temp" 45000;  printf 'C02b\t%s\n' "$(tmp_)"
    wnl "$temp" 250
    # C03 voltage validation
    wnl "$voltNow" 3712937; printf 'C03\t%s\n' "$(volt_now 2>/dev/null)"
    wnl "$voltNow" 50001;   printf 'C03b\t%s\n' "$(volt_now 2>/dev/null)"
    wnl "$voltNow" 3712937
    # C04 charge counter
    wnl "$D/battery/charge_counter" 594000; printf 'C04\t%s\n' "$(cc_now 2>/dev/null)"
    wnl "$D/battery/charge_counter" -5;     printf 'C04b\t%s\n' "$(cc_now 2>/dev/null)"
    wnl "$D/battery/charge_counter" 594000
    # C05 input current: uA, a taper after uA history, a bare mA reading, explicit factors
    rm -f "$D/.iinmicro"; inputAmpFactor=
    wnl "$D/usb/input_current_now" 2696040; printf 'C05\t%s\n' "$(_iin_ma 2>/dev/null || echo unreadable)"
    wnl "$D/usb/input_current_now" 5353;    printf 'C05b\t%s\n' "$(_iin_ma 2>/dev/null || echo unreadable)"
    rm -f "$D/.iinmicro"
    wnl "$D/usb/input_current_now" 1800;    printf 'C05c\t%s\n' "$(_iin_ma 2>/dev/null || echo unreadable)"
    inputAmpFactor=1000;                    printf 'C05d\t%s\n' "$(_iin_ma 2>/dev/null || echo unreadable)"
    inputAmpFactor=
    # C06 bus voltage: real, and microvolt noise on an unplugged phone
    wnl "$D/usb/voltage_now" 9000000; printf 'C06\t%s\n' "$(_vbus_mv 2>/dev/null || echo unreadable)"
    wnl "$D/usb/voltage_now" 18000;   printf 'C06b\t%s\n' "$(_vbus_mv 2>/dev/null || echo unreadable)"
    # C07 exported input when nothing is online
    wnl "$D/usb/online" 0; wnl "$D/usb/current_now" 0
    has _se_input && printf 'C07\t%s\n' "$(_se_input)" || printf 'C07\tn/a\n'
    wnl "$D/usb/online" 1; wnl "$D/usb/voltage_now" 9000000; wnl "$D/usb/current_now" 1500000
    has _se_input && printf 'C07b\t%s\n' "$(_se_input)" || printf 'C07b\tn/a\n'
    # C08 the unit ladder on the daemon side. Every leftover node from C05/C07 has to go first: a
    # single microamp reading anywhere is (correctly) enough to stop the mA fallback, and leaving one
    # behind makes this measure the fixture rather than the ladder.
    rm -f "$D/usb/current_now" "$D/usb/input_current_now" "$D/bms/current_now"
    ampFactor=; ampFactor_=
    wnl "$currFile" -895; wnl "$D/bms/current_now" -900
    has current_factor && printf 'C08\t%s\n' "$(current_factor)" || printf 'C08\tn/a\n'
    wnl "$currFile" -895; wnl "$D/bms/current_now" -822265
    has current_factor && printf 'C08b\t%s\n' "$(current_factor)" || printf 'C08b\tn/a\n'
    rm -f "$D/bms/current_now"; wnl "$currFile" -1500; wnl "$D/usb/input_current_now" 1650000
    has current_factor && printf 'C08c\t%s\n' "$(current_factor)" || printf 'C08c\tn/a\n'
    wnl "$currFile" -8000; wnl "$D/usb/input_current_now" 2000000
    has current_factor && printf 'C08d\t%s\n' "$(current_factor)" || printf 'C08d\tn/a\n'
    wnl "$currFile" -1850000
    has current_factor && printf 'C08e\t%s\n' "$(current_factor)" || printf 'C08e\tn/a\n'
    # C09 status(): garbage, zero, and a clean reading with no provable unit
    read_status(){ echo Charging; }; battStatusWorkaround=false; idleThreshold=10
    wnl "$battStatus" Charging; curThen=$D/.mcc; wnl "$curThen" 0
    rm -f "$D/bms/current_now" "$D/usb/input_current_now" "$D/usb/current_now"
    ampFactor=; ampFactor_=; wnl "$currFile" -895
    status 2>/dev/null; printf 'C09\t%s/rc=%s\n' "${_status:-none}" "$?"
    ampFactor=; ampFactor_=; wnl "$currFile" 0
    status 2>/dev/null; printf 'C09b\t%s/rc=%s\n' "${_status:-none}" "$?"
    ampFactor=1000; ampFactor_=1000; wnl "$currFile" not-a-number
    status 2>/dev/null; printf 'C09c\t%s/rc=%s\n' "${_status:-none}" "$?"
    # C10 idle_discharging with a stub current sensor
    if has idle_discharging; then
      _idr(){ ( TMPDIR=$D; idleThreshold=10; curNow=$1; _CC=$2; _DPOL=+; _kstatus=Charging; _status=
                cc_now(){ echo "$_CC"; }; present(){ return 0; }; eq(){ return 1; }
                printf '%s %s\n' "$3" "$(( $(date +%s) - 10 ))" > "$D/.cc_then"
                idle_discharging >/dev/null 2>&1; echo "$_status" ) 2>/dev/null; }
      printf 'C10\t%s\n'  "$(_idr 0 2758000 2757000)"
      printf 'C10b\t%s\n' "$(_idr 0 2758000 2758000)"
      printf 'C10c\t%s\n' "$(_idr 0 2757000 2758000)"
      printf 'C10d\t%s\n' "$(_idr -1752000 2758000 2758000)"
    else printf 'C10\tn/a\nC10b\tn/a\nC10c\tn/a\nC10d\tn/a\n'; fi
    # C11 the cut flag cannot survive the charger being gone
    _blk=$(sed -n '/if not_charging && present; then/,/^    fi$/p' "$E/misc-functions.sh")
    [ -n "$_blk" ] || _blk=$(sed -n '/^    if not_charging; then/,/^    fi$/p' "$E/misc-functions.sh")
    _cf(){ ( chDisabledByAcc=true
             eval "not_charging(){ return $1; }; present(){ return $2; }; switch_release_observed(){ return $3; }"
             eval "$_blk"; echo "$chDisabledByAcc" ) 2>/dev/null; }
    printf 'C11\t%s\n'  "$(_cf 0 1 1)"
    printf 'C11b\t%s\n' "$(_cf 0 0 1)"
    # C12 watts, fractional
    has _se_charge && printf 'C12\t%s\n' "$(ampFactor=1000000 ampFactor_=1000000 _se_charge 5000 895 895000 4000000 Charging 250 50)" || printf 'C12\tn/a\n'
    # C13 counter-direction with a reset in the window
    if has _se_ccdir; then
      SE_CCCACHE=$D/ccdir; printf '1000000 %s\n' "$(( $(date +%s) - 10 ))" > "$SE_CCCACHE"
      printf 'C13\t%s\n' "$(_se_ccdir 1)"
    else printf 'C13\tn/a\n'; fi
    # C14 units reported for the exported state
    has _se_units && printf 'C14\t%s\n' "$(ampFactor= ampFactor_= _se_units 6163)" || printf 'C14\tn/a\n'
    has _se_units && printf 'C14b\t%s\n' "$(ampFactor= ampFactor_= _se_units 895000)" || printf 'C14b\tn/a\n'
    # C15 config validation: which factor values survive a write
    printf 'C15\t%s\n' "$(grep -c 'inputAmpFactor' "$E/write-config.sh" 2>/dev/null)"
    printf 'C15b\t%s\n' "$(grep -cE "case .af in ''\|1000\|1000000" "$E/write-config.sh" 2>/dev/null)"
    # C16 the one-time-charge hook
    printf 'C16\t%s\n' "$(grep -c 'read_status.*Full' "$E/acc.sh" 2>/dev/null)"
    # C17 every switch-clearing path leaves a record
    printf 'C17\t%s\n' "$(grep -cE 'swclear-|resume-reselect|swblocked' "$E/accd.sh" 2>/dev/null)"
    # C18 DJS detection in the diagnostic
    printf 'C18\t%s\n' "$(grep -c 'djsc --list' "$E/diag-collect.sh" 2>/dev/null)"
    printf 'C18b\t%s\n' "$(grep -c 'pgrep -f "\[d\]js.sh"' "$E/diag-collect.sh" 2>/dev/null)"

    # ---- units added after the first matrix run --------------------------------------------------
    # C19 the input-current-limit guard: a supply reported drawing 9375 mA behind a 5000 mA limit
    # (Fairphone 5, second bundle). C19b a real reading under the same limit must survive, and C19c
    # a limit that does not itself convert must reject nothing.
    ACC_PSY=$W/c19; TMPDIR=$W
    wnl "$W/c19/usb/online" 1; wnl "$W/c19/usb/voltage_now" 8984000
    wnl "$W/c19/usb/current_now" 9375000; wnl "$W/c19/usb/input_current_limit" 5000000
    rm -f "$W/.iinmicro"; _sema=; _se_input_ma 9375000 usb/current_now 2>/dev/null
    printf 'C19\t%s\n' "${_sema:-n/a}"
    rm -f "$W/.iinmicro"; _sema=; _se_input_ma 2696040 usb/current_now 2>/dev/null
    printf 'C19b\t%s\n' "${_sema:-n/a}"
    rm -f "$W/.iinmicro"; wnl "$W/c19/usb/input_current_limit" 2000
    _sema=; _se_input_ma 2696040 usb/current_now 2>/dev/null
    printf 'C19c\t%s\n' "${_sema:-n/a}"
    # C19d the bus voltage survives even when the current beside it was rejected
    rm -f "$W/.iinmicro"; wnl "$W/c19/usb/input_current_limit" 5000000
    printf 'C19d\t%s\n' "$(_se_input 2>/dev/null | sed 's/.*voltageMv"://; s/,.*//')"
    ACC_PSY=; TMPDIR=/data/local/tmp

    # C20 the one-time-charge restore test. Both arms ask batt_cap, which prefers Android's level;
    # only the newer arm also asks the gauge, which is the difference between handing the config
    # back at the target and sitting on the throwaway for ever.
    printf 'C20\t%s\n' "$(grep -c '_ge_pause_cap_raw' "$E/accd.sh" 2>/dev/null)"
    printf 'C20b\t%s\n' "$(grep -c '_ge_pause_cap_raw' "$E/acc.sh" 2>/dev/null)"
    if grep -q '_ge_pause_cap_raw' "$E/accd.sh" 2>/dev/null; then
      eval "$(sed -n '/^  _ge_pause_cap_raw() {/,/^  }/p' "$E/accd.sh")" 2>/dev/null
      _r(){ ( battCapacity=$W/c20cap; capacity=(5 101 47 "$2" false); printf '%s\n' "$1" > "$W/c20cap"
              _ge_pause_cap_raw && echo reached || echo not-yet ) 2>/dev/null; }
      printf 'C20c\t%s\n' "$(_r 49 49)"
      printf 'C20d\t%s\n' "$(_r 48 49)"
    else
      printf 'C20c\tn/a\n'; printf 'C20d\tn/a\n'
    fi
  ) >> "$O" 2>/dev/null
done

# ---------- report ---------------------------------------------------------------------------------
printf '%-6s  %-28s  %s\n' UNIT A B
printf '%-6s  %-28s  %s\n' ------ ---------------------------- ----------------------------
_diff=0; _same=0
for id in $(awk -F'\t' '{print $1}' "$W/out.a" "$W/out.b" | sort -u); do
  va=$(awk -F'\t' -v k="$id" '$1==k{print $2; exit}' "$W/out.a"); [ -n "$va" ] || va='(missing)'
  vb=$(awk -F'\t' -v k="$id" '$1==k{print $2; exit}' "$W/out.b"); [ -n "$vb" ] || vb='(missing)'
  [ -n "$va" ] || va='(empty)'; [ -n "$vb" ] || vb='(empty)'
  if [ "$va" = "$vb" ]; then _same=$((_same+1)); mark=' '; else _diff=$((_diff+1)); mark='*'; fi
  printf '%s%-5s  %-28s  %s\n' "$mark" "$id" "$(printf '%s' "$va" | cut -c1-28)" "$(printf '%s' "$vb" | cut -c1-40)"
done
printf '\nunits=%s  changed=%s  identical=%s   (* = behaviour differs between rc24 and rc25)\n' \
  "$((_diff + _same))" "$_diff" "$_same"
