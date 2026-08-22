# Changelogs (short form)

ACC v2025.5.18-6.5.1-rc24 (202505332) - AMPS 7.2.4 - AccA 2.0.1-rc22 (222)

---

## ACC rc24

### Charging / HV contract
Fixed: bus voltage and current are normalised before comparison, so a microvolt node no longer reads as a collapsed supply.
Fixed: contract bar raised 6.0 V to 6.5 V; a QC3 contract under ~2 A no longer looks dead.
Added: the highest voltage seen on a plug is recorded and latches the contract.
Added: a high-voltage charger type (HVDCP / PD / QC) latches a contract on its own.
Fixed: a sustained sag or a collapsed input no longer releases the latch.
Changed: all re-detection goes through one gate, `_hv_may_kick`, with six conditions.

### Repair path
Changed: a stalled supply is answered by lifting the input current limit, not by re-running detection.
Fixed: input current is read from whichever node the kernel provides, and the node's scale is learned.
Changed: with no readable current node the gate fails closed - a kick needs positive proof.
Fixed: the current lift uses an allow-list and never writes a negotiation supply.
Fixed: uninstall applies the same rule; it previously left the phone on a 5 V floor.
Changed: the re-kick's restore releases the limit high instead of replaying a stale default.

### Daemon startup
Fixed: `service.sh` reported the launcher's exit code, not the daemon's, so a dead daemon read as success.
Fixed: the fallback launcher spells out `/system/bin/sh` rather than trusting PATH.
Fixed: the first-install probe can no longer take the daemon down with it under `set -e`.

### Pause and resume
Fixed: `flip` is cleared before the resume-time charge check.
Fixed: the plug edge comes from `present()`, so an input-cut replug re-arms.
Fixed: `generic_rearm` gates on `present()` instead of `online()`.
Fixed: aim-high yields while ACC is holding a pause at or above the pause level.

### Switch discovery
Fixed: the sweep budget covers both directions.
Fixed: the fallback sweep is bounded - unbounded, it held a plugged Mi A3 dark for minutes.
Fixed: a candidate that was not adopted is cleared from the global, so the next cut cannot use it.

### Write path
Fixed: `write()`'s retry was attached to the already-verified branch, causing five redundant writes.
Changed: the retry re-reads the node and compares to target after every attempt.

### CLI and config
Fixed: `acc -t`'s wait ceiling reads the clock; it counted loop passes, so 180 meant ~2 hours.
Fixed: `acc -t` hands its lock over before restarting the daemon, so it no longer exits 143.
Fixed: `acc -t` suppresses the tie-break with a dedicated flag, so an interrupted wait forges nothing.
Fixed: `acca` assigns config values without `export`, so a value is taken literally.
Fixed: `acca` accepts a glued `-sdcapacity` filter.
Fixed: `ui_refresh` is readable back through the config printer.
Fixed: `apply_on_plug`'s default restore covers `*/input_current_max`.

### Diagnostics
Fixed: the verdict no longer calls a working firmware limit a broken switch, and resolves `pcap`/`rcap`.
Fixed: the collector now carries the `SYSTEM_LAST_KMSG` body its own index advertises.
Fixed: the reboot note counts what landed instead of asserting it.
Fixed: the redactor no longer replaces DropBox filenames with `[EMAIL]`.
Fixed: a zero-byte artifact is never announced as collected; empty sources read `EMPTY`.

---

## AMPS 7.2.4

### Scanning
Fixed: a phone with no current sensor could not be scanned at all; a missing reading is no longer read as zero.
Fixed: `--unplug` ran on quick's caps and deadline while advertising Deep; it now gets Deep's budget.
Changed: the bypass/cut test order matches `reco_pick`'s ranking, so one report no longer gives two answers.

### Reporting
Fixed: a node reading exactly 100000 was printed unconverted - a Pixel 6a reported "Imax=100000mA".
Fixed: a low ceiling is no longer blamed on the cable when the port says HVDCP3.
Fixed: the input-capped branch now honours the `_iinbad` flag, which was dead.
Fixed: the battery-current veto only applies while the pack is charging.
Added: a current magnitude with no direction says so when the pack is not charging.
Fixed: a level node promoted from ACC's own config is no longer labelled "verified".
Fixed: a deferred scan no longer ships `class=throttle` for a confirmed bypass.
Changed: docs corrected - unknown/vendor/learned nodes are written, by deny-list shape, not name trust.

---

## AccA 2.0.1-rc22 (222)

### App
Added: UNDO for applying a profile, snapshotting the live config first.
Fixed: turning the Cool Down switch on left the row reading "-" until a picker was nudged.

## AccA 2.0.1-rc21

### App
Fixed: a charge limit of 100% silently became 80%.
Fixed: exporting several profiles or scripts produced a truncated file.
Fixed: importing could overwrite a local profile or script sharing a name.
Fixed: settings showed the default refresh interval rather than ACC's value.
Fixed: the dashboard could show wrong watts/amps/volts, and 0.00 W while current flowed.
Removed: the fast-charge re-kick and its setting; it dropped a healthy 9 V contract to the 5 V floor.
Changed: export saves to its own Download/AccA folder by default and never overwrites a backup.
Changed: import offers the same three routes as export.
Changed: "Find my charging switch" has its own dashboard card.
