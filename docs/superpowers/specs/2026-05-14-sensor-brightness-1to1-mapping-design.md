# Sensor-to-Brightness 1:1 Linear Mapping Refactor

## Problem Statement

The current adaptive brightness daemon uses a logarithmic mapping with per-bin offsets, battery coefficients, and a hardcoded sensor ceiling (`ML_BRIGHT_ENOUGH=8`) that wastes 97% of the sensor's resolution (real range: 0-255). This causes:

1. **Unbounded brightness values** — the mapping can produce values outside the hardware's 0-100% range, "breaking" the GNOME brightness slider
2. **Unpredictable behavior** — bins, offsets, and log curves make it impossible to predict what brightness corresponds to a given sensor reading
3. **Poor slider sync** — the GNOME extension can't reliably sync when the daemon writes values outside 0-100%

## Core Requirements

- Brightness must always be within 0-100% of the hardware range (never below 0, never above max)
- Mapping must be predictable: a given sensor value always produces the same brightness
- GNOME extension slider must sync correctly
- Sensor range is 0-255 (confirmed by hardware testing with flashlight)
- Auto-calibration with decay to adapt to changing environments

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Mapping curve | Linear 1:1 | Predictable, simple, meets core requirement |
| Sensor range | 0-255 (initial), auto-calibrates up | Confirmed by flashlight test; auto-calib handles outliers |
| Min brightness | 0 (hardware absolute minimum) | User explicitly wants 0-100% coverage |
| Bins/offsets | Removed | 1:1 mapping is predictable without offsets |
| Battery coefficient | Removed | Simplifies mapping; user can configure OS power settings |
| Keyboard mapping | Inverse linear 1:1 | Sensor min → kbd max, sensor max → kbd 0 |
| Manual adjustment | Temporarily pause auto (5 min) | Respects user intent, then resumes |
| Decay rate | ~1 min to shrink range back | Fast enough to adapt when moving from sun to indoor |

## Architecture

### Sensor Pipeline (Simplified)

```
raw sensor → median filter → EWMA smoothing → [NO CLAMP] → auto-calibrator → linear mapping
```

**Removed from pipeline:**
- Clamping to `[1, ML_BRIGHT_ENOUGH]`
- Per-bin offset calculation
- Battery coefficient multiplication

**Kept from pipeline:**
- Median filter (3 samples, 0.3s apart)
- EWMA smoothing (alpha=0.2)
- Hysteresis + asymmetric confirmation (1 poll brighten, 3 polls dim)

### Auto-Calibration with Decay

**State variables:**
- `sensor_min` — lowest smoothed value ever observed (initial: 0)
- `sensor_max` — highest smoothed value ever observed (initial: 255)

**Update rules (each poll):**
1. If `smoothed > sensor_max` → `sensor_max = smoothed`
2. If `smoothed < sensor_min` → `sensor_min = smoothed`

**Decay (each poll):**
- Range: `R = sensor_max - sensor_min`
- Decay per poll: `delta = max(1, R * ML_DECAY_RATE / (60 / ML_INTERVAL))`
- If `smoothed < sensor_max` → `sensor_max -= delta` (floor: `sensor_min + ML_SENSOR_RANGE_MIN`)
- If `smoothed > sensor_min` → `sensor_min += delta` (ceiling: `sensor_max - ML_SENSOR_RANGE_MIN`)

**With defaults** (`ML_DECAY_RATE=0.5`, `ML_INTERVAL=5`): `delta = max(1, R * 0.5 / 12) = max(1, R * 0.042)`. For a range of 200: ~8/poll, range halves in ~1 minute.

**Range protection:**
- `ML_SENSOR_RANGE_MIN` (default: 10) — `sensor_max - sensor_min` never goes below this
- Prevents division-by-zero and ensures usable resolution

**Initialization:**
- `sensor_min = 0`, `sensor_max = 255` (based on confirmed hardware range)
- If the sensor ever reports above 255, `sensor_max` grows automatically

### Screen Brightness Mapping

```
brightness_pct = (smoothed - sensor_min) / (sensor_max - sensor_min)
brightness_raw = brightness_pct * screen_max
```

- `sensor_min` → brightness 0 (screen off)
- `sensor_max` → brightness `screen_max` (full brightness)
- Division-by-zero protection: if `sensor_max == sensor_min`, use 50% of `screen_max`
- Result is clamped to `[0, screen_max]` (redundant with the math, but defensive)

### Keyboard Brightness Mapping

```
kbd_pct = 1 - (smoothed - sensor_min) / (sensor_max - sensor_min)
kbd_raw = kbd_pct * kbd_max
```

- `sensor_min` (dark) → kbd at `kbd_max` (255)
- `sensor_max` (bright) → kbd at 0
- If `smoothed >= ML_BRIGHT_ENOUGH` → kbd = 0 (override: "bright enough" threshold)
- Idle timeout preserved: after `ML_KBD_TIMEOUT` seconds idle → kbd = 0

### Manual Adjustment Pause

**Detection:** If `screen_from` differs from `screen_last_set` by more than 30 units (GNOME rounding tolerance), it's a manual adjustment.

**Behavior:**
1. Record the manual adjustment timestamp
2. Enter "paused" mode — don't update screen brightness
3. Continue reading sensor and updating `sensor_min`/`sensor_max`
4. After `ML_MANUAL_PAUSE` seconds (default: 300 = 5 min), resume auto-adjustment
5. On resume: the next `update()` cycle computes the 1:1 target from the current sensor reading and transitions to it via the normal `transition()` function (smooth interpolation over `ML_DURATION` seconds)

### Transition (Unchanged)

Smooth linear interpolation over `ML_DURATION` seconds with `ML_FRAME` step size. After transition completes, notify GNOME extension via D-Bus.

### Initialization

On daemon start:
1. Read first smoothed sensor value
2. Set `sensor_min = 0`, `sensor_max = 255`
3. Set `last_trigger_light = smoothed`
4. Compute initial brightness from 1:1 mapping
5. Apply smoothly via transition
6. Set `screen_last_set = current_brightness`
7. All bins/offsets removed — no bin initialization needed

## Configuration Changes

### Removed
| Variable | Reason |
|----------|--------|
| `ML_SCREEN_MIN_BRIGHT` | 1:1 maps sensor_min→0 |
| `ML_BATTERY_DIM` | Battery coefficient removed |
| `ML_BRIGHT_ENOUGH` (as sensor ceiling) | No longer clamps sensor; kept only for kbd threshold |

### Changed
| Variable | Old Role | New Role |
|----------|----------|----------|
| `ML_BRIGHT_ENOUGH` | Sensor ceiling + kbd threshold | Kbd off-threshold only (default: 8) |

### New
| Variable | Default | Purpose |
|----------|---------|---------|
| `ML_SENSOR_RANGE_MIN` | 10 | Minimum sensor range to prevent collapse |
| `ML_DECAY_RATE` | 0.5 | Fraction of range that decays per minute |
| `ML_MANUAL_PAUSE` | 300 | Seconds to pause auto-adjust after manual change |

### Kept Unchanged
`ML_DURATION`, `ML_FRAME`, `ML_INTERVAL`, `ML_KBD_BRIGHT`, `ML_KBD_TIMEOUT`, `ML_AUTO_KBD`, `ML_AUTO_SCREEN`, `ML_DEBUG`, `ML_SENSOR_SAMPLES`, `ML_SENSOR_SAMPLE_DELAY`, `ML_EWMA_ALPHA`, `ML_HYSTERESIS_PCT`, `ML_BRIGHTEN_CONFIRMS`, `ML_DIM_CONFIRMS`

## Removed Components

1. **Three-bin system** (dark/indoor/bright) — no longer needed with predictable 1:1 mapping
2. **Per-bin offsets** (`screen_user_offset_dark/indoor/bright`) — replaced by manual pause
3. **`screen_target()` logarithmic function** — replaced by linear formula
4. **`power_coef()` battery coefficient** — removed
5. **`light_bin()` function** — removed
6. **`get_bin_offset()` / `set_bin_offset()`** — removed
7. **Sensor clamping** to `[1, ML_BRIGHT_ENOUGH]` — removed (auto-calibration handles range)

## GNOME Extension Impact

The extension receives raw brightness values via D-Bus (`SetScreenBrightness(uint32)`). With the new mapping:

- Values are always in `[0, screen_max]` — never out of bounds
- The extension converts raw → percentage for the slider: `pct = raw * 100 / screen_max`
- Slider position always reflects actual hardware brightness
- No more "stuck slider" when daemon tries to write beyond 0-100%

No changes required to the GNOME extension code itself.

## Sensor Floor Consideration

The applesmc sensor has a floor of 0 — it reports 0 for any environment below its resolution threshold. This means:

- `sensor_min` will likely stay at 0 in practice
- The auto-calibration's decay for `sensor_min` will rarely activate (only if the sensor never reports 0)
- Mapping 0→brightness 0 is correct: if the sensor can't detect any light, minimum brightness is appropriate
- The `ML_SENSOR_RANGE_MIN` protection ensures the denominator never collapses

## Files to Modify

1. **`src/macbook-lighter-ambient.sh`** — Major refactor: remove bins/offsets/log-mapping, add auto-calibration, linear mapping, manual pause
2. **`macbook-lighter.conf`** — Remove `ML_SCREEN_MIN_BRIGHT` and `ML_BATTERY_DIM`, add `ML_SENSOR_RANGE_MIN`, `ML_DECAY_RATE`, `ML_MANUAL_PAUSE`, update `ML_BRIGHT_ENOUGH` comment
