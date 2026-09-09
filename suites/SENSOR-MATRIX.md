# Sensor matrix: ACC, AccA and AMPS

Test scope: unplugged Pixel 6a and Mi A3, using isolated synthetic sensor files and production readers. The 5 V and 9 V values are fixtures. No charger negotiation or switch enforcement was exercised by this matrix.

| Scenario | Coverage | Expected behavior |
|---|---|---|
| Voltage and current scales | mV/uV independently crossed with mA/uA | Convert each sensor with its own scale |
| Current polarity | Positive and negative raw current; normal and inverted polarity | Preserve magnitude and normalize direction |
| Voltage levels | 3.7 V, 5 V, 9 V and synthetic 50 V bound | Correct conversion and power |
| Current levels | 0, 1, 30, 31, 50, 51, 895, 2000, 20000 and 100000 mA | Correct values at idle thresholds and bounds |
| Mode changes on one reader | Repeated 5 V/9 V, scale and sign changes | Recompute from the supplied scale; no stale conversion |
| Direction evidence | Rising/falling charge counter versus cached polarity | Recent valid counter evidence wins |
| Fractional power | 5 V x 895 mA = 4.475 W; 9 V x 895 mA = 8.055 W | Preserve fractional watts |
| Raw precision | Fractional mA/mV represented as integer uA/uV | AMPS preserves raw precision through power; AccA retains float precision; ACC charge power resolves to 1 mW from integer mV/mA |
| Formatting | Leading plus, leading zeros, negative zero | Parse as decimal integers |
| Malformed readings | Missing, null, text, NaN, infinity, decimal/exponent/hex strings, malformed signs, oversized integers | Unavailable reading; no overflow into a plausible value |
| Invalid voltage | Negative, zero, below 1 V or above 50 V | Reject |
| Invalid current | Magnitude above 100 A or unsupported scale | Reject |
| Counter faults | Missing, malformed, zero, reset, implausible jump, stale/future time | Reject counter evidence; do not certify a hold from invalid counters |
| Undetectable sensor fault | Plausible stuck, biased or drifting value | Cannot certify correctness without an independent reference |
| Unannounced scale change | Identical raw value could mean mA or uA | Cannot infer every such change; requires trustworthy metadata or calibration |
| Inverted voltage wiring | Negative voltage | Reject; signed battery-current semantics do not apply to supply voltage |

The generated TSV contains 719 scenarios: 640 scale/sign combinations, 6 decimal-integer cases, 24 precision cases, 32 malformed readings, 10 voltage-bound cases, 4 current-bound cases and 3 unsupported scales. Tests additionally cover 10,000 changing-mode rounds and counter faults. These are supported combinations and defined fault classes, not a proof against every possible kernel or sensor failure.

Fixes include fractional charge power, overflow-safe AMPS power arithmetic, strict current and counter validation, symmetric handling of tiny negative current, and AccA direction handling based on valid counter evidence.

Run the reproducible checks from the repository root:

```sh
python suites/make-sensor-matrix.py
execDir="$PWD/install" AMPS="$PWD/amps.sh" sh suites/accd/t-sensor-matrix.sh
execDir="$PWD/install" sh suites/accd/t-sensor-transitions.sh
AMPS="$PWD/amps.sh" sh suites/amps/t-sensor-faults.sh
```

AccA runs SensorMatrixTest through its existing testDebugUnitTest Gradle task; its test resource is the same TSV.

Results, 2026-09-08:

| Target | Result |
|---|---|
| Pixel 6a, unplugged | 719 scenarios / 5,752 checks; 30,164 transition checks including 10,000 stress rounds; 175 AMPS self-tests; all 12 AMPS suites; sensor-validation and charge-power regressions passed |
| Mi A3, unplugged | Same checks passed; DEEP_MATRIX_FAILED=0 on both devices |
| AccA on host JVM | 155 tests passed, including 719 scenarios repeated 10 times and 128 direction transitions; lintDebug passed |
| Packages | ACC ZIP validation passed; APK signature verified; packaged AMPS and shared matrix match source |

Both phones reported Discharging before and after testing. Their ACC configuration hashes were unchanged. The test harness used isolated files and a temporary timed wake lock; it did not install a daemon or APK.

Local test packages are in ../_builds/ACC-rc25-sensor-test.zip and ../_builds/AccA-sensor-test.apk. The APK uses the local Android test key and cannot update an installation signed with a different key. No release was pushed or published. The actual OnePlus and physical plugged-in 5 V/9 V transitions remain untested in this phase.
