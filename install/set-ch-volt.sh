set_ch_volt() {

  local f=$TMPDIR/.volt-custom
  local isAccd=${isAccd:-false}
  local _scvOnDisk= _scvDisk=

  # Avoid CLI/daemon races.
  $isAccd && [ -f $TMPDIR/.mcv-settling ] && return 0 || :

  if ${_accdRelease:-false}; then
    _scvDisk=$(sed -n 's/^maxChargingVoltage=(\([0-9][0-9]*\).*/\1/p' "${config:-$dataDir/config.txt}" 2>/dev/null)
    [ -z "${_scvDisk:-}" ] || return 0
  fi

  # Same reboot hole as set-ch-curr: the tmpfs marker alone must not gate a restore (a post-reboot
  # clear must still drop a stored config value), but the gate must not depend on the resolved
  # control files either - the daemon calls `set_ch_volt -` every loop when no limit is set, and a
  # ctrl-files clause made that a full default rewrite each tick on voltage-node phones.
  # CONSULT THE CONFIG ON DISK, not the arrays in memory. set-prop.sh clears maxChargingVoltage=()
  # for `acc -s mcv=` BEFORE it calls this function, so by the time the fast path below tested
  # those three names they were ALREADY empty -- it returned 0 every time, and the clear branch,
  # which is the only thing that restores the nodes, never ran at all.
  #
  # Device-proven on a Mi A3: after `acc -s mcv=` the config read maxChargingVoltage=() while
  # battery/voltage_max and main/voltage_max were still pinned at 4150000 against a 4400000
  # default. A 4.15V ceiling holds that pack near 70%, and NOTHING in the config or the UI said
  # so -- only reading the sysfs nodes showed it. It survives unplug and reboot.
  #
  # write-config has not run yet at this point, so the on-disk value is still the OLD one, and that
  # is exactly the signal wanted: a limit is still on record, therefore there is something to undo.
  # Same rule set-ch-curr.sh already applies ("a daemon release must consult the config ON DISK,
  # not the copy it loaded at the top").
  _scvOnDisk=$(sed -n 's/^maxChargingVoltage=(\([0-9][0-9]*\).*/\1/p' "${config:-$dataDir/config.txt}" 2>/dev/null)
  [[ ! -f $f && .${1-} = .- ]] \
    && [ -z "${maxChargingVoltage[0]-}${max_charging_voltage-}${mcv-}${_scvOnDisk}" ] && return 0 || :

  if [ -n "${1-}" ]; then

    set -- $*

    apply_on_boot_() {
      (applyOnBoot=()
      apply_on_boot ${*-})
    }

    # A clear (-) must succeed even when the control files were never resolved this boot (phone
    # not charged since reboot): drop the config value unconditionally and restore the stored node
    # defaults only when they are known. Mirrors set-ch-curr's not-charging clear so a disabled
    # voltage limit can never linger on the config (resurrected by the editor on reload) or on the
    # nodes until the next reboot.
    if [ $1 = - ]; then
      # Release blocked controls too.
      grep -q / $TMPDIR/ch-volt-ctrl-files 2>/dev/null && _BLRELEASE=1 apply_on_boot_ default force || :
      max_charging_voltage=
      maxChargingVoltage=()
      unset mcv
      $isAccd || print_volt_restored
      rm $f 2>/dev/null || :
      return 0
    fi

    # A numeric SET needs the resolved control files to know which nodes to write. Current-control
    # files and switches are NOT a completion signal for this probe: on a live Mi A3 they existed
    # before ch-volt-ctrl-files was published, so the CLI discarded 4150 during that small window.
    # Keep bare intent until accd publishes the explicit completion marker; its next charging tick
    # expands the value to node entries and writes the config again.
    grep -q / $TMPDIR/ch-volt-ctrl-files 2>/dev/null || {
      if [ ! -f $TMPDIR/.mcv-read ]; then
        maxChargingVoltage=($1)
        unset max_charging_voltage mcv
        return 0
      fi

      # Discovery really completed and found no usable voltage node. Do not leave AccA displaying
      # a cap that cannot act, and do not print a success tick for it.
      $isAccd || print_no_ctrl_file v
      max_charging_voltage=
      maxChargingVoltage=()
      unset mcv
      return 1
    }

    apply_voltage() {
      eval "maxChargingVoltage=($1 $(sed "s|::v|::$1|" $TMPDIR/ch-volt-ctrl-files) ${2-})" \
        && unset max_charging_voltage mcv \
        && apply_on_boot_ || return 1

      local _mcvTarget=$1 _mcvExtra=${2-}
      local _mcvHeld=false _mcve _mcvf _mcvt _mcvd _mcvm _mcvOk= _mcvWasFV=false
      : > "$TMPDIR/ch-volt-ctrl-files.ok"
      for _mcve in ${maxChargingVoltage[@]-}; do
        case "$_mcve" in *::*::*) ;; *) continue;; esac
        case "$_mcve" in *pmic-votable/FV/*) _mcvWasFV=true;; esac
        set -- ${_mcve//::/ }
        _mcvf=${1-}; _mcvt=${2-}
        case "$_mcvf" in /*) ;; *) _mcvf=${PS:-/sys/class/power_supply}/$_mcvf;; esac
        if [ "$(cat "$_mcvf" 2>/dev/null)" = "$_mcvt" ]; then
          _mcvHeld=true
          _mcvOk="${_mcvOk:+$_mcvOk }$_mcve"
          _mcvd=${_mcve##*::}
          # Preserve the discovery marker, rather than reconstructing it from the default's digit
          # count. Qualcomm FV/force_val defaults to 0 but still needs v000 (mV -> uV), while its
          # paired force_active entry has a fixed target of 1. Guessing turns both into 4150.
          _mcvm=$(awk -F'::' -v p="${_mcve%%::*}" '$1 == p { print $2; exit }' "$TMPDIR/ch-volt-ctrl-files" 2>/dev/null)
          [ -n "$_mcvm" ] || _mcvm=v${_mcvd#????}
          printf '%s::%s::%s\n' "${_mcve%%::*}" "$_mcvm" "$_mcvd" >> "$TMPDIR/ch-volt-ctrl-files.ok"
        fi
      done
      if ! $_mcvHeld; then
        # A VOTABLE THAT NEVER HOLDS MUST NOT LOCK OUT THE NODES THAT WOULD.
        #
        # The wipe below deliberately forces one clean rediscovery. On a phone whose FV votable
        # exists but does not actually take the vote, that rediscovery sees FV present, goes
        # exclusive on it again, fails to hold again, and wipes again - forever. The power_supply
        # voltage_max mirrors are dropped from the list the moment FV is chosen, so the user is
        # left with NO voltage cap on a phone where the mirrors would have worked.
        #
        # Leave a breadcrumb so the next discovery skips FV exclusivity and keeps the mirrors.
        # It lives in tmpfs, so a reboot retries the votable once: a transient miss must not
        # disable the better control permanently.
        $_mcvWasFV && { : > $TMPDIR/.fv-nohold 2>/dev/null || :; } || :
        _BLRELEASE=1 apply_on_boot_ default force || :
        max_charging_voltage=
        maxChargingVoltage=()
        unset mcv
        # A transient writer/daemon overlap can make every candidate miss this one verification
        # pass. Invalidate completion with the failed list so the caller forces one clean init;
        # otherwise a stale .mcv-read turns "retry discovery" into "unsupported forever".
        rm -f "$f" "$TMPDIR/.mcv-read" "$TMPDIR/ch-volt-ctrl-files" "$TMPDIR/ch-volt-ctrl-files.ok" 2>/dev/null || :
        $isAccd || print_no_ctrl_file v
        return 1
      fi
      mv -f "$TMPDIR/ch-volt-ctrl-files.ok" "$TMPDIR/ch-volt-ctrl-files"
      eval "maxChargingVoltage=($_mcvTarget $_mcvOk $_mcvExtra)"
      $isAccd || print_volt_set $_mcvTarget
    }

    # REJECT A NON-NUMBER INSTEAD OF REPORTING SUCCESS FOR IT.
    #
    # The three branches below are all arithmetic comparisons. Given a value like `abc` every one
    # of them is false, execution falls past the whole if/elif chain to the `touch $f` after it, and
    # the caller returns 0 -- so `acc -s maxChargingVoltage=abc` printed the success tick, wrote
    # nothing, and left the previous limit standing. Device-verified on a Mi A3: exit 0 and a ✅ for
    # a value that is not a voltage. The same hole is in the current setter, which was believed to
    # have a guard and does not: `acc -s maxChargingCurrent=abc` answers ✅ as well.
    #
    # A front-end cannot tell that apart from a cap that was accepted, which is the whole problem:
    # AccA shows the tick and the user believes a limit is in force.
    case "${1:-}" in
      ''|*[!0-9]*)
        $isAccd || echo "[3700-4300]$(print_mV; print_only)"
        return 1
      ;;
    esac

    # = [3700-4300] millivolts
    if [ $1 -ge 3700 -a $1 -le 4300 ]; then
      apply_voltage $1 ${2-} || return 1

    # < 3700 millivolts
    elif [ $1 -lt 3700 ]; then
      $isAccd || echo "[3700-4300]$(print_mV; print_only)"
      apply_voltage 3700 ${2-} || return 1

    # > 4300 millivolts
    elif [ $1 -gt 4300 ]; then
      $isAccd || echo "[3700-4300]$(print_mV; print_only)"
      apply_voltage 4300 ${2-} || return 1
    fi
    touch $f

  else
    # print current value
    $isAccd && echo ${maxChargingVoltage[0]-} \
      || echo "${maxChargingVoltage[0]:-$(print_default)}$(print_mV)"
    return 0
  fi
}
