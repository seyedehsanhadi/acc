import csv
import json
import random
import statistics as st
import sys
from collections import defaultdict

SEED = 20260924
BOOT = 20000
METRICS = [
    ("drain_mA", "battery drain, mA"),
    ("daemon_cpu_ms_min", "daemon CPU, ms/min"),
    ("sys_busy_ms_min", "system busy CPU, ms/min"),
    ("awake_pct", "CPU awake, % of wall time"),
    ("suspends_per_h", "suspend cycles per hour"),
]


EXTERNAL_X = 3.0


def exclude_external(rows):
    kept, dropped = [], []
    for dev in {r["device"] for r in rows}:
        mine = [r for r in rows if r["device"] == dev]
        other = sorted(r["sys_busy_ms_min"] - r["daemon_cpu_ms_min"] for r in mine)
        med = st.median(other)
        for r in mine:
            x = r["sys_busy_ms_min"] - r["daemon_cpu_ms_min"]
            (dropped if x > EXTERNAL_X * med else kept).append(r)
    return kept, dropped


def load(paths):
    rows = []
    for p in paths:
        with open(p, newline="") as f:
            for r in csv.DictReader(f, delimiter="\t"):
                if r["valid"] != "yes":
                    continue
                el = int(r["elapsed_s"])
                rows.append({
                    "device": r["device"], "round": int(r["round"]), "arm": r["arm"],
                    "drain_mA": int(r["drain_uAh"]) * 3.6 / el,
                    "daemon_cpu_ms_min": float(r["daemon_cpu_ms_min"]),
                    "sys_busy_ms_min": float(r["sys_busy_ms_min"]),
                    "awake_pct": int(r["awake_permil"]) / 10,
                    "suspends_per_h": int(r["suspends"]) * 3600 / el,
                })
    return rows


def ci(xs, rng):
    if len(xs) < 2:
        return (float("nan"), float("nan"))
    means = sorted(st.fmean(rng.choices(xs, k=len(xs))) for _ in range(BOOT))
    return (means[int(0.025 * BOOT)], means[int(0.975 * BOOT) - 1])


def analyse(rows):
    rng = random.Random(SEED)
    out = {}
    for dev in sorted({r["device"] for r in rows}):
        by = defaultdict(dict)
        for r in rows:
            if r["device"] == dev:
                by[r["round"]][r["arm"]] = r
        arms = sorted({a for d in by.values() for a in d} - {"off", "off2"})
        res = {"rounds": len(by), "arms": {}, "aa": {}, "pairs": {}}
        for m, _ in METRICS:
            aa = [d["off2"][m] - d["off"][m] for d in by.values() if "off" in d and "off2" in d]
            res["aa"][m] = {"n": len(aa), "mean": st.fmean(aa) if aa else None,
                            "sd": st.stdev(aa) if len(aa) > 1 else None, "ci": ci(aa, rng)}
        for a in arms:
            res["arms"][a] = {}
            for m, _ in METRICS:
                raw = [d[a][m] for d in by.values() if a in d]
                diffs = []
                for d in by.values():
                    fl = [d[x][m] for x in ("off", "off2") if x in d]
                    if a in d and fl:
                        diffs.append(d[a][m] - st.fmean(fl))
                res["arms"][a][m] = {"n": len(raw), "mean": st.fmean(raw) if raw else None,
                                     "median": st.median(raw) if raw else None,
                                     "vs_floor_mean": st.fmean(diffs) if diffs else None,
                                     "vs_floor_ci": ci(diffs, rng)}
        floor = {m: st.fmean([d[x][m] for d in by.values() for x in ("off", "off2") if x in d] or [float("nan")])
                 for m, _ in METRICS}
        res["floor"] = floor
        for i, a in enumerate(arms):
            for b in arms[i + 1:]:
                res["pairs"][f"{b} - {a}"] = {}
                for m, _ in METRICS:
                    d = [x[b][m] - x[a][m] for x in by.values() if a in x and b in x]
                    res["pairs"][f"{b} - {a}"][m] = {"n": len(d), "mean": st.fmean(d) if d else None, "ci": ci(d, rng)}
        out[dev] = res
    return out


def fmt(v, nd=2):
    return "  n/a" if v is None or v != v else f"{v:.{nd}f}"


def text(res):
    lines = []
    for dev, r in res.items():
        lines.append(f"== {dev}: {r['rounds']} rounds")
        for m, label in METRICS:
            aa = r["aa"][m]
            lines.append(f"  {label}")
            lines.append(f"    floor (no ACC) mean {fmt(r['floor'][m])}   A/A off2-off: mean {fmt(aa['mean'])} sd {fmt(aa['sd'])} "
                         f"CI [{fmt(aa['ci'][0])}, {fmt(aa['ci'][1])}] n={aa['n']}")
            for a, v in r["arms"].items():
                x = v[m]
                lines.append(f"    {a:6s} mean {fmt(x['mean'])}  cost vs floor {fmt(x['vs_floor_mean'])} "
                             f"CI [{fmt(x['vs_floor_ci'][0])}, {fmt(x['vs_floor_ci'][1])}] n={x['n']}")
            for p, v in r["pairs"].items():
                x = v[m]
                lines.append(f"    {p:15s} {fmt(x['mean'])} CI [{fmt(x['ci'][0])}, {fmt(x['ci'][1])}] n={x['n']}")
    return "\n".join(lines)


if __name__ == "__main__":
    kept, dropped = exclude_external(load(sys.argv[1:]))
    for r in dropped:
        print(f"EXCLUDED (outside activity): {r['device']} round {r['round']} {r['arm']} "
              f"busy {r['sys_busy_ms_min']:.0f} ms/min, daemon {r['daemon_cpu_ms_min']:.0f}, drain {r['drain_mA']:.1f} mA")
    res = analyse(kept)
    print(text(res))
    with open("consumption-v2-summary.json", "w") as f:
        json.dump(res, f, indent=1)
