# Advanced Charging Controller -- brick-safe switch probe journal
# Copyright 2017-2024, VR25 / community
# License: GPLv3+
#
# Problem (GitHub #305/#308): probing/flipping certain charging-switch nodes can
# instantly kernel-panic and REBOOT the device, before ACC ever gets to record that
# the node was dangerous. On the next boot ACC re-probes the SAME node and bricks the
# device into a reboot loop.
#
# Fix: a tiny write-ahead journal on persistent storage. Before a risky switch write
# we ARM the journal (persist the candidate switch line + fsync). After the write
# returns safely we DISARM it (remove the file). If the device panics/reboots mid-write,
# the file SURVIVES -- on the next boot accd calls journal_check(), which sees the
# leftover pending entry, BLACKLISTS that exact switch line, and removes it from the
# in-memory switch list so it is never probed again. cycle_switches additionally skips
# any switch already present in the blacklist.
#
# Contracts: additive + fail-safe only. Every helper is best-effort and MUST NOT abort
# the caller or break the pause/safety logic (all returns are forced to success). mksh /
# POSIX-sh compatible. dataDir is persistent (/data/adb/vr25/acc-data); the journal lives
# there on purpose so it outlives a reboot, unlike anything under tmpfs ($TMPDIR).

: ${dataDir:=/data/adb/vr25/acc-data}

# Persistent journal paths.
probePending=$dataDir/.probe-pending
probeBlacklist=$dataDir/.probe-blacklist

# rc21: global probe stop. Blacklisting one node per crash-boot is correct but the cost is one
# HARD REBOOT per bad node, and a Qualcomm device that keeps crashing early enough can fall into
# EDL before the candidate list is exhausted (field report: OnePlus SM8250 on KernelSU -- boot to
# desktop, freeze, no touch, reboot, EDL). After this many switches have taken the phone down,
# stop searching for one automatically; the user picks with `acc -ss`. Charging itself is never
# blocked by the latch. Cleared by `acc -sb clear`.
probeLatch=$dataDir/.no-probe
probeStrikeMax=${probeStrikeMax:-3}


# journal_arm <switch-line>
# Persist the candidate switch line that is ABOUT to be written, then flush it all the
# way to disk so it survives an immediate kernel panic / power loss. Call this right
# BEFORE a risky flip_sw write.
journal_arm() {
  mkdir -p "$dataDir" 2>/dev/null || :
  # Single line, exactly as it appears in $TMPDIR/ch-switches, so journal_check can match
  # and blacklist it verbatim.
  printf '%s\n' "${1-}" > "$probePending" 2>/dev/null || :
  # Push the write-ahead record to stable storage. sync(1) flushes all pending I/O; that
  # is the whole point -- a panic 1ms later must still find this file on reboot.
  sync 2>/dev/null || :
  return 0
}


# journal_disarm
# The risky write returned without panicking the kernel, so the candidate is proven safe
# for this attempt. Drop the pending record. Call this right AFTER the write returns.
journal_disarm() {
  rm -f "$probePending" 2>/dev/null || :
  return 0
}


# journal_check
# Called by accd ONCE on boot/init (this file only DEFINES it; accd invokes it). If a
# pending record survived from before a reboot, the switch it names panicked the device
# mid-write -- permanently BLACKLIST it (append to $probeBlacklist, de-duplicated) and
# strip it from the live switch list ($TMPDIR/ch-switches) so it is never probed again.
# Then clear the pending record. No-op (success) when nothing is pending.
journal_check() {
  [ -f "$probePending" ] || return 0
  local line=
  line="$(cat "$probePending" 2>/dev/null || :)"
  if [ -n "$line" ]; then
    mkdir -p "$dataDir" 2>/dev/null || :
    # A leftover pending record is NOT proof of a panic, and post-fs-data.sh already settled what
    # to do about that: latching is cheap and reversible, blacklisting is permanent and can cost
    # the user their only working switch, so blacklist only with the same panic evidence AMPS
    # demands, and always latch. This function never got that rule. cycle_switches arms the
    # journal, writes the switch and disarms it, so ANY SIGKILL in between -- AccA's 150s timeout
    # on `acc -t`, a killed foreground scan, a phantom process reaped by lowmemorykiller -- left
    # the file behind and permanently blacklisted a switch that had done nothing wrong. Three of
    # those and .no-probe turns auto-discovery off for good.
    _jcbr="$(getprop sys.boot.reason 2>/dev/null)$(getprop ro.boot.bootreason 2>/dev/null)"
    case "$_jcbr" in
      *panic*|*watchdog*|*wdog*|*kernel_panic*) _jcblame=true;;
      *) _jcblame=false;;
    esac
    # Append only if not already blacklisted (idempotent across repeated boots).
    if $_jcblame && { [ ! -f "$probeBlacklist" ] || ! grep -qxF "$line" "$probeBlacklist" 2>/dev/null; }; then
      printf '%s
' "$line" >> "$probeBlacklist" 2>/dev/null || :
    fi
    $_jcblame || printf '%s probe pending survived, reboot reason not a panic (%s); latched this boot, NOT blacklisted (%s)
'       "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$_jcbr" "$line" >> "$dataDir/probe-journal.log" 2>/dev/null || :
    # Remove the offending switch from the in-memory probe list so this boot does not
    # re-trigger the panic. Match the whole line (same anchoring accd uses elsewhere).
    if [ -f "$TMPDIR/ch-switches" ]; then
      sed -i "\|^${line}\$|d" "$TMPDIR/ch-switches" 2>/dev/null || :
    fi
    # rc6 (C2): tell the user WHY a switch vanished. A node that panic-rebooted the device is now
    # permanently blacklisted; without this the switch silently disappears and the phone can be left
    # with no working limit and no explanation.
    $_jcblame && command -v notif >/dev/null 2>&1 && notif "⚠️ ACC: a charging switch crash-rebooted this phone and was permanently disabled for safety ($line). If charging no longer stops at your limit, run a switch scan in AccA → Scripts." || :
    # rc21: trip the global latch once probing has taken this phone down too many times. Counted
    # from the blacklist itself, which only ever grows by a crash attribution -- no extra state to
    # keep in sync. Guarded so a device with a legitimately odd driver still gets its 3 attempts.
    # Counted with the shell, not grep. toybox grep has no \s, and this runs early enough that
    # busybox is not guaranteed on PATH -- a miscount here silently disables the whole latch.
    _pbn=0
    # Guard the redirect. `2>/dev/null` on the `done` line silences the loop's stderr but NOT a
    # failed open of the input file, so an unreadable/absent blacklist aborted here under set -e
    # -- and `rm -f "$probePending"` below never ran, stranding .probe-pending on persistent
    # storage, which makes the NEXT boot look like a probe crash. Same failed-open class as the
    # `acc -sb list` abort fixed in acc.sh.
    if $_jcblame && [ -r "$probeBlacklist" ]; then
      # The case WORD was unquoted. A device shell field-splits it, so a whitespace-only line
      # collapses to '' and an indented '#' loses its leading blank and reads as a comment --
      # both get skipped, the strike count comes out short, and the latch never trips on a
      # hand-edited blacklist. Quote it, and precompute the CR once instead of nesting quotes
      # inside ${..} inside the quoted word (and forking a printf per line). Same idiom as
      # sw_blacklisted in misc-functions.sh and bl_in in amps.sh.
      _pbcr=$(printf '\r')
      while IFS= read -r _pbl || [ -n "${_pbl:-}" ]; do
        _pbl=${_pbl%"$_pbcr"}
        case "$_pbl" in ''|'#'*) continue;; esac
        _pbn=$(( _pbn + 1 ))
      done < "$probeBlacklist"
    fi
    if [ "$_pbn" -ge "${probeStrikeMax:-3}" ] && [ ! -f "$probeLatch" ]; then
      : > "$probeLatch" 2>/dev/null || :
      sync 2>/dev/null || :
      command -v notif >/dev/null 2>&1 && notif "⚠️ ACC: $_pbn charging switches have crash-rebooted this phone. Automatic switch searching is now OFF so it cannot happen again. Pick one by hand with 'acc -ss', or clear with 'acc -sb clear'." || :
    fi
  fi
  rm -f "$probePending" 2>/dev/null || :
  sync 2>/dev/null || :
  return 0
}


# journal_blacklisted <switch-line>
# True (0) when the given switch line is on the persistent blacklist, so callers can SKIP
# a node that previously bricked the device. False (1) otherwise, including when no
# blacklist exists yet. Pure read; never mutates state.
journal_blacklisted() {
  [ -f "$probeBlacklist" ] || return 1
  grep -qxF "${1-}" "$probeBlacklist" 2>/dev/null
}
