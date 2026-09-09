from decimal import Decimal, ROUND_DOWN
from itertools import product
from pathlib import Path
import csv

rows = []


def add(family, vr, ir, vf=1000, af=1000, polarity="normal", valid_v=True, valid_i=True):
    v = Decimal(vr) / vf if valid_v else None
    a = Decimal(ir) / af if valid_i else None
    mv = int(v * 1000) if v is not None else None
    ma = int(a * 1000) if a is not None else None
    signed = a * 1000 * (-1 if polarity == "inverted" else 1) if a is not None else None
    watts = abs(Decimal(mv) * ma / 1000000).quantize(Decimal("0.001"), rounding=ROUND_DOWN) if v is not None and a is not None else None
    exact_watts = v * signed / 1000 if v is not None and signed is not None else None
    rows.append([len(rows) + 1, family, vr or "~", ir or "~", vf, af, polarity, mv, ma, watts,
                 int(a * 1000000) if a is not None else None, signed, exact_watts,
                 int(v * 1000000) if v is not None else None, int(abs(exact_watts) * 1000) if exact_watts is not None else None])


for mv, vf, ma, af, sign, polarity in product(
    (3700, 5000, 9000, 50000), (1000, 1000000), (0, 1, 30, 31, 50, 51, 895, 2000, 20000, 100000),
    (1000, 1000000), (-1, 1), ("normal", "inverted")
):
    add("scale-sign", str(mv * vf // 1000), str(ma * af // 1000 * sign), vf, af, polarity)

for vr, ir in product(("+0005000", "0009000"), ("+0000895", "-0000895", "-0000")):
    add("decimal-integers", vr, ir)

for vr, ir, polarity in product(("3712937", "5000001", "8999999"), ("1234567", "-10001", "1", "-1"), ("normal", "inverted")):
    add("precision", vr, ir, 1000000, 1000000, polarity)

for bad in ("", "null", "unknown", "garbage", "NaN", "Infinity", "-Infinity", "1.5", "1e3", "+", "-", "--1", "1-2", "2 3", "0x1000", "999999999999999999999999"):
    add("bad-voltage", bad, "895", valid_v=False)
    add("bad-current", "5000", bad, valid_i=False)

for vr in ("-5000", "-9000000", "0", "1", "5", "9", "999", "50001", "50001000", "9000000000"):
    add("voltage-range", vr, "895", valid_v=False)

for ir, af in product(("100001", "-100001"), (1000, 1000000)):
    add("current-range", "5000", str(int(ir) * (af // 1000)), 1000, af, valid_i=False)

for af in (0, 1, 1000000000):
    add("unsupported-scale", "5000", "2000", af=af, valid_i=False)

out = Path(__file__).parent / "sensor-matrix.tsv"
with out.open("w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f, delimiter="\t", lineterminator="\n")
    writer.writerow(["id", "family", "voltage_raw", "current_raw", "voltage_factor", "current_factor", "polarity", "mv", "ma_integer", "watts_milli_precision", "current_ua", "signed_ma", "signed_watts", "voltage_uv", "power_mw"])
    writer.writerows([["null" if x is None else str(x) for x in row] for row in rows])
print(f"{len(rows)} scenarios -> {out}")
