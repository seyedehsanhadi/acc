# How ACC's four charging limits interact

ACC exposes four limits. Users set them together and expect a predictable result. This is what the
daemon actually does, which combinations are meaningful, and which ones look applied but cannot act.

Derived from `install/accd.sh` and verified on hardware with `acc-limit-matrix.sh`, which runs all
15 non-empty combinations and checks each outcome against the rules below.

## The two classes

The four limits are not peers. Two of them stop charging; two of them shape it.

| Limit | Config | Mechanism | Class |
|---|---|---|---|
| Capacity | `capacity=(shutdown cooldown resume pause mask)` | charging switch on/off | **PAUSE**, binary |
| Temperature | `temperature=(cooldown max resume shutdown)` | charging switch on/off | **PAUSE**, binary |
| Current | `maxChargingCurrent` | `*/current_max`, `constant_charge_current_max` | **THROTTLE**, continuous |
| Voltage | `maxChargingVoltage` | `*/voltage_max` | **THROTTLE**, continuous |

A pause is all or nothing. A throttle only shapes a charge that is already permitted to happen.

## Order of evaluation, per loop

```
is_charging ?                                  no  -> nothing below runs at all
  |
  +-- PAUSE   mt_reached OR _ge_pause_cap      -> disable_charging
  +-- COOLDOWN  (only if not paused)           -> duty-cycle the switch
  +-- THROTTLE  set_ch_curr, set_ch_volt       -> shape the rate
  |
RESUME  _le_resume_cap AND temp <= resume_temp -> enable_charging
```

Three consequences worth stating plainly.

**Pause beats throttle, always.** With a capacity or temperature limit holding, a current or voltage
cap has nothing to act on. It is not being ignored; there is simply no charge to shape.

**Pausing is an OR, resuming is an AND.** One reason is enough to stop. Every reason must clear
before charging restarts. That asymmetry is deliberate and is what stops a hot phone at 50% from
resuming just because it is below the capacity limit.

**Everything hangs off `is_charging`.** If the charge-direction verdict is wrong, all four limits go
blind simultaneously. That is not a theoretical concern: on a phone whose current reads negative
while charging, `acc -i` reported Discharging at 41 °C against a 40 °C limit and charging never
paused. Direction is decided by arbitration between the kernel status node, the current sign with a
per-device polarity, and the charge counter, in that order of increasing authority.

## Degrees of freedom

Within each limit the values are ordered, and `write-config.sh` enforces the ordering rather than
letting a contradictory band through.

| Constraint | Enforced by | If violated |
|---|---|---|
| `shutdown_capacity < resume_capacity` | write-config | corrected on write |
| `resume_capacity < pause_capacity` | write-config | corrected on write |
| `pause - resume <= 3` | `config_sanity` warning | charger re-arms every few points, audible on some phones |
| `max_temp` in 20..60 | write-config | clamped |
| `resume_temp < max_temp` | write-config | hysteresis would collapse into a pulse |
| `cooldown_temp < max_temp` | write-config | cooldown enters and instantly breaks, never throttles |
| `cooldown_temp >= resume_temp` | write-config | band rebuilt around `max_temp` |
| `shutdown_temp >= max(max_temp, 40)`, `<= 70` | write-config | phone would power off before it ever paused |

So temperature is really one free choice, `max_temp`, with a band rebuilt around it if you collapse
it. Capacity is `pause`, with `resume` free below it. Current and voltage are independent scalars.

## The 15 combinations

`C` capacity, `T` temperature, `A` current, `V` voltage. Expected state, from the rules above.

| # | Set | Expected | Why |
|---|---|---|---|
| 1 | none | FULL | nothing limiting |
| 2 | C | PAUSED | binary limit |
| 3 | T | PAUSED | binary limit |
| 4 | A | THROTTLED | rate shaped |
| 5 | V | THROTTLED or BLOCKED | depends where the cap sits vs the pack's terminal voltage |
| 6 | C T | PAUSED | either alone would do it |
| 7 | C A | PAUSED | pause beats throttle; the current cap cannot be observed |
| 8 | C V | PAUSED | as above |
| 9 | T A | PAUSED | as above |
| 10 | T V | PAUSED | as above |
| 11 | A V | THROTTLED or BLOCKED | the tighter of the two decides; the other looks ignored |
| 12 | C T A | PAUSED | |
| 13 | C T V | PAUSED | |
| 14 | C A V | PAUSED | |
| 15 | T A V | PAUSED | |
| 16 | C T A V | PAUSED | |

Ten of the sixteen rows are PAUSED. That is the point: once either binary limit is active, the two
throttles are unobservable, and a user who sets a current cap while sitting at their capacity limit
has no way to tell whether it works.

## Charge direction: the single point of failure

All four limits are evaluated only while ACC believes charging is happening, so the direction
verdict is not one input among many — it gates everything. It is decided by four things in
increasing order of authority:

| # | Arbiter | Rules when | Fails when |
|---|---|---|---|
| 1 | current sign through the cached `_DPOL` | always | the cached polarity is wrong |
| 2 | `charge_counter` delta over a 3-90s window | `abs(delta) >= 150 uAh` | the gauge is too coarse to move |
| 3 | kernel status, one-way Discharging -> Charging | the counter could not rule | the status node lies |
| 4 | `present()` — is a cable attached at all | always | never; it is a fact, not an inference |

Measured 2026-08-04 with **both** phones holding an inverted `_DPOL` and `.dpol_unstable` armed,
so nothing could re-latch it. What arbiter 1 alone concluded, on every sample of both phones while
they pulled 2-3 A:

```
A3     sign-alone = Discharging x10   actual: charging at 2.0-2.5 A, counter delta 0 on 9 of 10
Pixel  sign-alone = Discharging x10   actual: charging at 2.7-3.0 A, counter delta 6000-8000
```

Arbiter 3 rescued 20 of 20. Without it `is_charging` would have been false on every loop of both
phones and every limit would have been skipped — the reported symptom of charging past a
temperature limit.

The A3 is also why arbiter 2 must only claim a verdict when it actually has one: its counter delta
is 0 on nine samples in ten. A raw delta of 0 recorded as "the counter decided" stands arbiter 3
down, and the rescue never fires.

Arbiter 4 exists because arbiters 1-3 all failed together on an unplugged phone: opposite current
signs, opposite cached polarities, both reported as charging. It keys on `present`, not `online`,
because an input-cut switch drives `online` to 0 while the cable is still attached.

Known limit of arbiter 4: it answers "is a cable attached", not "is current flowing". A phone whose
input the charger driver has cut to zero still reads `present=1`, so a wrong current sign can still
report Charging there. Observed on a Mi A3 where the vendor's own `hvdcp_opti` daemon voted
`USB_ICL` to 0 and suspended the input. That state is indistinguishable from ACC's own input cut
without more context, and believing "charging" is the safe direction: ACC pauses something that is
not happening, rather than letting a real charge run unguarded. The cost is a wrong word in
`acc -i` while the pack drains, not a missed limit.

## Measured, 2026-08-04

Two phones, opposite switch classes, run with `acc-limit-matrix.sh`.

| | Mi A3 (laurus) | Pixel 6a (bluejay) |
|---|---|---|
| Switch | `input_suspend`, generic cut | `charge_stop_level`, native firmware |
| Gauge | `battery/*` | `maxfg/*` |
| Charging polarity | negative | positive |
| Free rate on a PC port | 157 mA | 353 mA |
| Pause-dominant rows correct | 8 of 10 | 10 of 10 |

Every combination containing a capacity or temperature limit paused, on both phones, with the two
exceptions noted below. The precedence claim holds: a binary limit dominates every throttle, and a
throttle never touched the charging switch.

Two things the run established that reading the code did not.

**A throttle tight enough to stop the charge suppresses the binary limits.** Once a voltage cap
brings the current to nothing, ACC no longer believes charging is happening, so it never evaluates
the capacity or temperature limit and never asserts the pause. Nothing is charging, so nothing is
harmed, but the switch is left in its on position and the hold depends entirely on the throttle. If
that throttle stops holding, charging resumes with no pause in place until the next loop notices.

**Neither phone could demonstrate a current cap on a PC USB port.** ACC's smallest current cap is
300 mA and the A3 was drawing 157 mA, so there was nothing to cap; writing the current nodes only
re-triggered AICL, the negotiated rate collapsed, and with the phone still drawing its own keep-alive
the pack went net negative. The matrix now detects that and skips those rows rather than reporting a
failure. Covering the current and voltage rows needs a wall charger and a battery around 60%.

## Settings that are accepted but cannot act

These are legal, get written to the config exactly as asked, and then do nothing a user can see.

| Setting | What happens | Covered? |
|---|---|---|
| `cooldown_temp >= max_temp` | cooldown never throttles | write-config rebuilds the band |
| `resume_temp >= max_temp` | pause/resume flutter | write-config clamps |
| `resume` within 3 of `pause` | charger re-arm churn | `config_sanity` warns |
| voltage cap far below the cell's rated maximum | gauge drifts, percentage stops matching | `config_sanity` warns |
| voltage cap at or below the pack's present voltage | charging never starts; no limit "fires" | **not covered** |
| current cap and voltage cap together | the looser one appears ignored | **not covered** |
| any throttle while a pause is active | the throttle appears ignored | **not covered** |
| voltage cap on a phone whose charger ignores `voltage_max` | accepted, no effect | **not covered** |

## Per-phone differences

Not every phone has the same degrees of freedom, and the switch class changes how a pause is even
observable.

| Class | Switch | Pause looks like | Notes |
|---|---|---|---|
| Generic cut | `input_suspend`, `charge_disable` | node reads its off value; charger reads offline | `usb/online` drops to 0, so the phone looks unplugged |
| Generic gate | `charging_enabled`, `battery_charging_enabled` | node reads 0 | charger stays online |
| Native firmware | `charge_stop_level` + `charge_start_level` | `stop_level <= level` | ACC records the off value as the sentinel `pcap`, which the node never contains, so a node-vs-off-value test is always "on" and tells you nothing |
| Current cap | `constant_charge_current_max` | node reads 0 or a token | a pause and a throttle share a node here |

A current or voltage limit is only available where the phone exposes the nodes for it. ACC accepts
the setting either way; whether it lands is visible in the config after a write.
