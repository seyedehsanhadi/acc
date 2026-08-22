#!/system/bin/sh
# consumption-report.sh - turn consumption-3way's TSV into a table and a verdict.
#
#   sh consumption-report.sh [/data/local/tmp/consumption-3way.tsv]
#
# THE STATISTIC, AND WHY IT IS THIS ONE
#   Every round contains one `off` window and one window per build, measured minutes apart under
#   near-identical conditions. The figure reported for a build is the MEDIAN OF THE PAIRED
#   DIFFERENCES against its own round's floor - not the difference of two hour-long medians.
#   Temperature falls, the pack drains and the radio wakes and sleeps over a run this long; all of
#   that moves both members of a pair together and cancels out of a paired difference. It does not
#   cancel out of an unpaired one, and a build measured mostly early would beat a build measured
#   mostly late for reasons that have nothing to do with the build.
#
#   The median, not the mean: one window disturbed by a background app should not move the answer.
#
# THE RESOLUTION RULE
#   This rig's resolution is the spread of the floor windows: the gap between the highest and the
#   lowest of them. A difference smaller than that has not been measured, it has been guessed at,
#   and this script says so instead of ranking builds by noise.
#
# THE FROZEN-GAUGE RULE - the one that stops this being a lie on half the fleet
#   charge_counter is only a coulomb counter on phones that actually integrate one. On a Mi A3 it
#   is derived from the capacity percentage and does not move for tens of minutes at a time:
#   measured across 200s of confirmed discharge it returned the identical value ten times. Read
#   naively that is "0 uAh/min", and every arm ties at zero - a phone where ACC appears to cost
#   nothing because the instrument is stuck. So: if the counter never moves across the whole run,
#   the drain column is declared UNMEASURABLE on this phone and no verdict is drawn from it. The
#   CPU, busy and fork columns are unaffected; they come from /proc and are exact.
#
# THE DERIVED COST
#   Where the drain data IS usable, the hog window gives a device-measured coefficient: how many
#   uAh a second of busy CPU costs on this phone, today, at this temperature. Applied to each arm's
#   measured CPU time it gives a battery figure with far better resolution than the gauge itself,
#   because the CPU time is exact and only the coefficient carries noise.
#
#   The coefficient is built on SYSTEM-WIDE busy CPU, not on the daemon's own process time. A shell
#   daemon's real cost is mostly fork, schedule and teardown work that the kernel charges elsewhere,
#   so utime+stime understates it. Differenced against the floor arm the system total captures all
#   of it and is still attributable, because the floor arm is the same phone doing the same nothing.

TSV=${1:-/data/local/tmp/consumption-3way.tsv}
[ -f "$TSV" ] || { echo "no TSV at $TSV"; exit 1; }

awk -F'\t' '
function med(cnt,   i, j, t) {
  for (i = 1; i < cnt; i++) for (j = i + 1; j <= cnt; j++) if (S[j] < S[i]) { t = S[i]; S[i] = S[j]; S[j] = t }
  return (cnt % 2) ? S[int(cnt/2) + 1] : int((S[cnt/2] + S[cnt/2 + 1]) / 2)
}
function medof(a, key, cnt,   i) { for (i = 1; i <= cnt; i++) S[i] = V[a, key, i]; return med(cnt) }
function spanof(a, key, cnt,   i, lo, hi) {
  lo = V[a, key, 1]; hi = lo
  for (i = 2; i <= cnt; i++) { if (V[a, key, i] < lo) lo = V[a, key, i]; if (V[a, key, i] > hi) hi = V[a, key, i] }
  return hi - lo
}
NR == 1 { next }
$3 != "yes" { inval[$2]++; next }
{
  a = $2
  n[a]++
  V[a, "dq", n[a]] = $4 + 0
  V[a, "cp", n[a]] = $5 + 0
  V[a, "fk", n[a]] = $6 + 0
  V[a, "bs", n[a]] = $9 + 0
  seen[a] = 1
  if ($4 + 0 != 0) moved = 1
  if (a == "off" && $1 != "probe") floor_of[$1] = $4 + 0
  if ($1 != "probe") { rnd[a, n[a]] = $1; rdq[a, n[a]] = $4 + 0 }
}
END {
  order[1] = "off"; order[2] = "vr25"; order[3] = "rc23"; order[4] = "rc24"; order[5] = "hog"

  for (k = 1; k <= 5; k++) {
    a = order[k]; if (!seen[a]) continue
    pc = 0
    if (a != "off") {
      for (i = 1; i <= n[a]; i++) {
        r = rnd[a, i]
        if (r in floor_of) { pc++; V[a, "pd", pc] = rdq[a, i] - floor_of[r] }
      }
    }
    pm[a] = (pc > 0) ? medof(a, "pd", pc) : 0
    pn[a] = pc
    mdq[a] = medof(a, "dq", n[a])
    mcp[a] = medof(a, "cp", n[a])
    mfk[a] = medof(a, "fk", n[a])
    mbs[a] = medof(a, "bs", n[a])
  }

  res = spanof("off", "dq", n["off"])
  # MINIMUM SAMPLE COUNT. With one surviving floor window the spread is zero by construction, so
  # every difference looks larger than the resolution and the script confidently reports noise as a
  # finding. It did exactly that on a run where a low-battery warning woke the screen and eleven of
  # seventeen windows were correctly discarded - leaving n=1 and a "real difference" drawn from a
  # single pair. Three is the floor for a median to mean anything at all.
  MINN = 3
  usable = (moved && mdq["off"] > 0 && n["off"] >= MINN)

  print ""
  printf "%-6s %3s %13s %14s %11s %12s %10s\n", "arm", "n", "drain uAh/min", "paired vs off", "cpu ms/min", "busy ms/min", "forks/min"
  printf "%-6s %3s %13s %14s %11s %12s %10s\n", "------", "---", "-------------", "--------------", "-----------", "------------", "----------"
  for (k = 1; k <= 5; k++) {
    a = order[k]; if (!seen[a]) continue
    dcol = usable ? sprintf("%d", mdq[a]) : "n/a"
    pcol = (a == "off") ? "-" : ((usable && pn[a] > 0) ? sprintf("%+d (n=%d)", pm[a], pn[a]) : "n/a")
    printf "%-6s %3d %13s %14s %11d %12d %10d", a, n[a], dcol, pcol, mcp[a], mbs[a], mfk[a]
    if (inval[a]) printf "   %d discarded", inval[a]
    print ""
  }

  if (!usable && n["off"] < MINN) {
    print ""
    printf "only %d floor window(s) survived, against a minimum of %d.\n", n["off"], MINN
    print "Too few to form a resolution or a median, so NO DRAIN VERDICT is given. The most common"
    print "cause is the screen waking mid-run, which every affected window is discarded for. The CPU"
    print "and fork columns below come from /proc and are still exact."
  } else if (!usable) {
    print ""
    print "charge_counter did not move across this run. On this phone it is derived from the capacity"
    print "percentage rather than integrated, so it cannot resolve anything at this window length. The"
    print "drain column is UNMEASURABLE here and no verdict is drawn from it. The CPU, busy and fork"
    print "columns come from /proc and are exact."
  } else {
    print ""
    printf "resolution: the %d floor windows spanned %d uAh/min end to end.\n", n["off"], res
    print "            Nothing smaller than that has been measured on this phone today."
  }

  cost = 0
  if (seen["hog"] && usable) {
    hd = mdq["hog"] - mdq["off"]
    hc = mbs["hog"] - mbs["off"]
    print ""
    printf "sensitivity: the deliberate hog cost %+d uAh/min over the floor for %+d ms/min of busy CPU.\n", hd, hc
    if (res > 0 && hd > res * 3) {
      printf "             That is %.1fx the resolution, so the rig separates real load from idle.\n", hd / res
      if (hc > 0) {
        cost = hd / (hc / 1000.0)
        printf "             Device coefficient: %.1f uAh per second of busy CPU.\n", cost
      }
    } else if (hd > 0 && res == 0) {
      print "             The floor spread was zero, so no ratio can be formed."
    } else {
      print "             NOT clear of the noise. NO DRAIN VERDICT: a rig that cannot see a known-large"
      print "             difference cannot be trusted on the small ones above."
      usable = 0
    }
  }

  if (usable) {
    print ""
    print "verdict, measured drain:"
    for (k = 2; k <= 4; k++) {
      a = order[k]; if (!seen[a] || pn[a] < MINN) continue
      d = pm[a]; ad = (d < 0) ? -d : d
      printf "  %-5s %+d uAh/min against no ACC at all", a, d
      if (ad <= res) print "   - inside the resolution, indistinguishable from zero"
      else printf "   = %.1f mAh/day\n", d * 1.44
    }
    for (k = 3; k <= 4; k++) {
      a = order[k]; b = order[k-1]
      if (!seen[a] || !seen[b] || pn[a] < MINN || pn[b] < MINN) continue
      g = pm[a] - pm[b]; ag = (g < 0) ? -g : g
      if (ag <= res) printf "  %s vs %s: %+d uAh/min, inside the resolution - INDISTINGUISHABLE\n", a, b, g
      else printf "  %s vs %s: %+d uAh/min, outside the resolution - a real difference\n", a, b, g
    }
  }

  print ""
  print ""
  print "verdict, attributable CPU - exact, and the mechanism behind any drain difference:"
  worst = 0
  for (k = 2; k <= 4; k++) {
    a = order[k]; if (!seen[a]) continue
    c = mcp[a] - mcp["off"]
    bb = mbs[a] - mbs["off"]
    printf "  %-5s daemon %6d ms/min   system busy %6d ms/min   %5d forks/min\n", a, c, bb, mfk[a] - mfk["off"]
    if (cost > 0) {
      est = bb / 1000.0 * cost
      if (est > worst) worst = est
      printf "         upper bound %.0f uAh/min, %.0f mAh/day\n", est, est * 1.44
    }
  }
  if (cost > 0) {
    print ""
    print "  Why UPPER BOUND, and why it must not be quoted as the answer:"
    print "  the coefficient comes from a pegged core, which sits at the top of the DVFS range for the"
    print "  whole window. A daemon that wakes for a few milliseconds at a time runs at a far lower"
    print "  clock and costs correspondingly less per CPU-second, so scaling one by the other"
    print "  overstates it. Where the two disagree the DIRECT measurement wins."
    if (usable && worst > res) {
      printf "  They disagree here: the largest derived figure is %.0f uAh/min against a resolution of\n", worst
      printf "  %d uAh/min, so a cost that size would have been plainly visible in the drain column and\n", res
      print "  it was not. Read the CPU and fork columns as the finding; read the drain column as the"
      print "  ceiling it puts on all of them."
    }
  }

  if (seen["rc23"] && seen["rc24"]) {
    x = mcp["rc24"] - mcp["off"]; y = mcp["rc23"] - mcp["off"]
    if (y > 0) { print ""; printf "  rc24 uses %.1f%% of rc23 daemon CPU (%d vs %d ms/min over the floor).\n", x * 100.0 / y, x, y }
  }
  if (seen["vr25"] && seen["rc24"]) {
    x = mcp["rc24"] - mcp["off"]; v = mcp["vr25"] - mcp["off"]
    if (x > 0) printf "  VR25 original uses %.1fx rc24 daemon CPU (%d vs %d ms/min over the floor).\n", v * 1.0 / x, v, x
  }
}
' "$TSV"
