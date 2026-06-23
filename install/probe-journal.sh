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
    # Append only if not already blacklisted (idempotent across repeated boots).
    if [ ! -f "$probeBlacklist" ] || ! grep -qxF "$line" "$probeBlacklist" 2>/dev/null; then
      printf '%s\n' "$line" >> "$probeBlacklist" 2>/dev/null || :
    fi
    # Remove the offending switch from the in-memory probe list so this boot does not
    # re-trigger the panic. Match the whole line (same anchoring accd uses elsewhere).
    if [ -f "$TMPDIR/ch-switches" ]; then
      sed -i "\|^${line}\$|d" "$TMPDIR/ch-switches" 2>/dev/null || :
    fi
    # rc6 (C2): tell the user WHY a switch vanished. A node that panic-rebooted the device is now
    # permanently blacklisted; without this the switch silently disappears and the phone can be left
    # with no working limit and no explanation.
    command -v notif >/dev/null 2>&1 && notif "⚠️ ACC: a charging switch crash-rebooted this phone and was permanently disabled for safety ($line). If charging no longer stops at your limit, run a switch scan in AccA → Scripts." || :
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
