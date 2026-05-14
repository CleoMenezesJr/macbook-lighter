# Sensor-Brightness 1:1 Linear Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the adaptive brightness daemon from logarithmic mapping with per-bin offsets to a predictable 1:1 linear mapping (0-255 sensor → 0-100% brightness) with auto-calibration and decay.

**Architecture:** The sensor pipeline is simplified: raw → median → EWMA (no clamp) → auto-calibrator → linear mapping. Three-bin system, per-bin offsets, logarithmic `screen_target()`, battery coefficient, and `ML_SCREEN_MIN_BRIGHT` are all removed. New components: auto-calibration with proportional decay, manual-adjustment pause timer. The config file drops two variables and adds three.

**Tech Stack:** Bash, bc (arbitrary precision math), applesmc sysfs, intel_backlight sysfs, D-Bus (gdbus)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/macbook-lighter-ambient.sh` | Modify | Main daemon: sensor pipeline, auto-calib, linear mapping, manual pause |
| `macbook-lighter.conf` | Modify | Config: remove 2 vars, add 3 vars, update comments |

No new files. No GNOME extension changes required.

---

### Task 1: Update config defaults and variables in ambient script

**Files:**
- Modify: `src/macbook-lighter-ambient.sh:15-31` (Settings section)

Remove the old variables and add the new ones in the Settings section.

- [ ] **Step 1: Remove `ML_SCREEN_MIN_BRIGHT` and `ML_BATTERY_DIM` defaults, add new defaults**

Replace lines 15-31 with:

```bash
ML_DURATION=${ML_DURATION:-1.5}
ML_FRAME=${ML_FRAME:-0.017}
ML_INTERVAL=${ML_INTERVAL:-5}
ML_BRIGHT_ENOUGH=${ML_BRIGHT_ENOUGH:-8}
ML_KBD_BRIGHT=${ML_KBD_BRIGHT:-128}
ML_KBD_TIMEOUT=${ML_KBD_TIMEOUT:-30}
ML_AUTO_KBD=${ML_AUTO_KBD:-true}
ML_AUTO_SCREEN=${ML_AUTO_SCREEN:-true}
ML_DEBUG=${ML_DEBUG:-false}
ML_SENSOR_SAMPLES=${ML_SENSOR_SAMPLES:-3}
ML_SENSOR_SAMPLE_DELAY=${ML_SENSOR_SAMPLE_DELAY:-0.3}
ML_EWMA_ALPHA=${ML_EWMA_ALPHA:-0.2}
ML_HYSTERESIS_PCT=${ML_HYSTERESIS_PCT:-15}
ML_BRIGHTEN_CONFIRMS=${ML_BRIGHTEN_CONFIRMS:-1}
ML_DIM_CONFIRMS=${ML_DIM_CONFIRMS:-3}
ML_SENSOR_RANGE_MIN=${ML_SENSOR_RANGE_MIN:-10}
ML_DECAY_RATE=${ML_DECAY_RATE:-0.5}
ML_MANUAL_PAUSE=${ML_MANUAL_PAUSE:-300}
```

- [ ] **Step 2: Verify the file still sources the config and the new defaults are present**

Run: `grep -n 'ML_SENSOR_RANGE_MIN\|ML_DECAY_RATE\|ML_MANUAL_PAUSE\|ML_SCREEN_MIN_BRIGHT\|ML_BATTERY_DIM' src/macbook-lighter-ambient.sh`

Expected: The three new variables appear with defaults; the two removed variables are gone.

- [ ] **Step 3: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "refactor(ambient): replace old config defaults with new 1:1 mapping variables"
```

---

### Task 2: Remove sensor clamping from `get_smoothed_light`

**Files:**
- Modify: `src/macbook-lighter-ambient.sh` (get_smoothed_light function, ~lines 103-105)

- [ ] **Step 1: Remove the Stage 3 clamp block**

Delete these three lines from `get_smoothed_light`:

```bash
	# Stage 3: Clamp to [1, ML_BRIGHT_ENOUGH]
	(( smoothed > ML_BRIGHT_ENOUGH )) && smoothed=$ML_BRIGHT_ENOUGH
	(( smoothed < 1 )) && smoothed=1
```

The function should go directly from the EWMA block to `prev_smoothed=$smoothed` and `echo $smoothed`.

- [ ] **Step 2: Verify clamp is gone**

Run: `grep -n 'ML_BRIGHT_ENOUGH\|smoothed < 1' src/macbook-lighter-ambient.sh`

Expected: No occurrences inside `get_smoothed_light`. `ML_BRIGHT_ENOUGH` may still appear elsewhere (kbd logic).

- [ ] **Step 3: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "refactor(ambient): remove sensor clamping from get_smoothed_light"
```

---

### Task 3: Replace private state variables

**Files:**
- Modify: `src/macbook-lighter-ambient.sh:50-60` (Private States section)

- [ ] **Step 1: Replace bin offset variables with auto-calibration and manual pause state**

Replace lines 50-60 with:

```bash
# Private States
prev_smoothed="" # EWMA state — empty means uninitialized
sensor_min=0 # auto-calibration: lowest smoothed value observed
sensor_max=255 # auto-calibration: highest smoothed value observed
screen_last_set=0 # last brightness value written by this script
last_trigger_light=0 # smoothed light that last triggered a change
brighten_count=0 # asymmetric confirmation counters
dim_count=0
kbd_adjusted_at=0
kbd_off_for_idle=false
manual_pause_until=0 # epoch timestamp: auto-adjust paused until this time
```

- [ ] **Step 2: Verify old bin variables are gone**

Run: `grep -n 'screen_user_offset' src/macbook-lighter-ambient.sh`

Expected: No matches.

- [ ] **Step 3: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "refactor(ambient): replace bin offset state with auto-calib and manual pause state"
```

---

### Task 4: Remove bin functions and battery coefficient function

**Files:**
- Modify: `src/macbook-lighter-ambient.sh` (remove `light_bin`, `get_bin_offset`, `set_bin_offset`, `power_coef`, `screen_range`)

- [ ] **Step 1: Delete the five functions**

Delete these entire functions:
- `light_bin` (lines ~151-161)
- `get_bin_offset` (lines ~163-170)
- `set_bin_offset` (lines ~172-180)
- `screen_range` (lines ~219-228)
- `power_coef` (lines ~350-357)

Also delete the `power_file=` line at the top (line ~6) since it's only used by `power_coef`.

- [ ] **Step 2: Verify functions are gone**

Run: `grep -n 'function light_bin\|function get_bin_offset\|function set_bin_offset\|function power_coef\|function screen_range\|power_file=' src/macbook-lighter-ambient.sh`

Expected: No matches.

- [ ] **Step 3: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "refactor(ambient): remove bin functions, screen_range, and power_coef"
```

---

### Task 5: Replace `screen_target` with linear mapping and auto-calibration

**Files:**
- Modify: `src/macbook-lighter-ambient.sh` (replace `screen_target` function, add `update_calibration` function)

- [ ] **Step 1: Add the `update_calibration` function after `get_smoothed_light`**

Insert this new function after `get_smoothed_light` (after the `echo $smoothed` line):

```bash
function update_calibration {
	local smoothed=$1

	# Expand range if smoothed exceeds current bounds
	(( smoothed > sensor_max )) && sensor_max=$smoothed
	(( smoothed < sensor_min )) && sensor_min=$smoothed

	# Proportional decay: shrink range toward current value
	local range=$(( sensor_max - sensor_min ))
	(( range <= ML_SENSOR_RANGE_MIN )) && return

	local polls_per_min
	polls_per_min=$(echo "scale=0; 60 / $ML_INTERVAL" | bc)
	local delta
	delta=$(echo "scale=0; $range * $ML_DECAY_RATE / $polls_per_min / 1" | bc)
	(( delta < 1 )) && delta=1

	# Decay sensor_max down if current value is below it
	if (( smoothed < sensor_max )); then
		sensor_max=$(( sensor_max - delta ))
		(( sensor_max < sensor_min + ML_SENSOR_RANGE_MIN )) && sensor_max=$(( sensor_min + ML_SENSOR_RANGE_MIN ))
	fi

	# Decay sensor_min up if current value is above it
	if (( smoothed > sensor_min )); then
		sensor_min=$(( sensor_min + delta ))
		(( sensor_min > sensor_max - ML_SENSOR_RANGE_MIN )) && sensor_min=$(( sensor_max - ML_SENSOR_RANGE_MIN ))
	fi

	$ML_DEBUG && echo "calib: sensor_min=$sensor_min sensor_max=$sensor_max range=$((sensor_max - sensor_min))"
}
```

- [ ] **Step 2: Replace `screen_target` with linear mapping**

Replace the entire `screen_target` function with:

```bash
function screen_target {
	# Linear 1:1 mapping: sensor [sensor_min..sensor_max] → brightness [0..screen_max]
	local light=$1
	local range=$(( sensor_max - sensor_min ))
	if (( range <= 0 )); then
		# Degenerate range: use 50% brightness
		echo $(( screen_max / 2 ))
		return
	fi
	local screen_to
	screen_to=$(( (light - sensor_min) * screen_max / range ))
	# Clamp to [0, screen_max]
	(( screen_to < 0 )) && screen_to=0
	(( screen_to > screen_max )) && screen_to=$screen_max
	echo $screen_to
}
```

- [ ] **Step 3: Verify the new functions exist and old log formula is gone**

Run: `grep -n 'l(\$light)\|l(\$ML_BRIGHT_ENOUGH)\|function screen_target\|function update_calibration' src/macbook-lighter-ambient.sh`

Expected: `update_calibration` and `screen_target` defined; no `l($light)` or `l($ML_BRIGHT_ENOUGH)` (the old `bc -l` log calls).

- [ ] **Step 4: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "feat(ambient): add auto-calibration with decay and linear screen_target"
```

---

### Task 6: Rewrite `update_screen` with linear mapping (no offsets)

**Files:**
- Modify: `src/macbook-lighter-ambient.sh` (update_screen function, ~lines 242-257)

- [ ] **Step 1: Replace `update_screen` body**

Replace the entire `update_screen` function with:

```bash
function update_screen {
	local light=$1
	local screen_from=$(cat $screen_file)
	local screen_to=$(screen_target $light)

	if (( screen_to == screen_from )); then
		$ML_DEBUG && echo "screen no change ($screen_from), skip"
		return
	fi

	transition $screen_from $screen_to $screen_file
	screen_last_set=$screen_to
}
```

- [ ] **Step 2: Verify no bin/offset/power references remain in update_screen**

Run: `grep -n 'light_bin\|get_bin_offset\|screen_range\|power_coef\|offset' src/macbook-lighter-ambient.sh`

Expected: No matches in `update_screen`. (The word "offset" should not appear in the file at all now.)

- [ ] **Step 3: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "refactor(ambient): rewrite update_screen with linear mapping, no offsets"
```

---

### Task 7: Rewrite `update_kbd` with inverse linear mapping

**Files:**
- Modify: `src/macbook-lighter-ambient.sh` (update_kbd function, ~lines 259-296)

- [ ] **Step 1: Replace `update_kbd` body**

Replace the entire `update_kbd` function with:

```bash
function update_kbd {
	local light=$1
	local kbd_from=$(cat $kbd_file)
	local kbd_max
	kbd_max=$(cat $kbd_dir/max_brightness)

	$ML_DEBUG && echo "kbd: light=$light, kbd_from=$kbd_from"

	local kbd_to

	# Idle timeout override
	if is_idle_for "$ML_KBD_TIMEOUT"; then
		$ML_DEBUG && echo "idle for ${ML_KBD_TIMEOUT}s, turning off kbd"
		kbd_to=0
		kbd_off_for_idle=true
	elif $kbd_off_for_idle; then
		# User returned from idle — restore inverse linear value
		kbd_off_for_idle=false
		if (( light >= ML_BRIGHT_ENOUGH )); then
			kbd_to=0
		else
			local range=$(( sensor_max - sensor_min ))
			if (( range > 0 )); then
				kbd_to=$(( kbd_max - (light - sensor_min) * kbd_max / range ))
			else
				kbd_to=$(( kbd_max / 2 ))
			fi
		fi
	elif (( light >= ML_BRIGHT_ENOUGH )); then
		kbd_to=0
	else
		# Inverse linear: sensor_min → kbd_max, sensor_max → 0
		local range=$(( sensor_max - sensor_min ))
		if (( range > 0 )); then
			kbd_to=$(( kbd_max - (light - sensor_min) * kbd_max / range ))
		else
			kbd_to=$(( kbd_max / 2 ))
		fi
	fi

	# Clamp
	(( kbd_to < 0 )) && kbd_to=0
	(( kbd_to > kbd_max )) && kbd_to=$kbd_max

	if (( kbd_to == kbd_from )); then
		$ML_DEBUG && echo "kbd no change ($kbd_from), skip"
		return
	fi

	transition $kbd_from $kbd_to $kbd_file
}
```

- [ ] **Step 2: Verify old proportional formula is gone**

Run: `grep -n 'ML_KBD_BRIGHT.*ML_BRIGHT_ENOUGH.*light' src/macbook-lighter-ambient.sh`

Expected: No matches (the old `ML_KBD_BRIGHT * (ML_BRIGHT_ENOUGH - light) / ML_BRIGHT_ENOUGH` formula is gone).

- [ ] **Step 3: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "refactor(ambient): rewrite update_kbd with inverse linear mapping"
```

---

### Task 8: Rewrite `update` with auto-calibration call and manual pause logic

**Files:**
- Modify: `src/macbook-lighter-ambient.sh` (update function, ~lines 298-340)

- [ ] **Step 1: Replace the `update` function**

Replace the entire `update` function with:

```bash
function update {
	$ML_DEBUG && echo "--- poll ---"
	local lid=$(awk '{print $2}' $lid_file)
	if [ "$lid" == "closed" ]; then
		$ML_DEBUG && echo "lid closed, skip"
		return
	fi

	local light=$(get_smoothed_light)
	$ML_DEBUG && echo "smoothed light: $light"

	# Update auto-calibration every poll
	update_calibration $light

	# Manual adjustment detection
	if $ML_AUTO_SCREEN; then
		local screen_from=$(cat $screen_file)
		if (( screen_last_set > 0 )); then
			local diff=$(( screen_from - screen_last_set ))
			(( diff < 0 )) && diff=$(( -diff ))

			# Allow +/- 30 margin to ignore GNOME slider rounding write-backs
			if (( diff > 30 )); then
				manual_pause_until=$(( $(date +%s) + ML_MANUAL_PAUSE ))
				screen_last_set=$screen_from
				$ML_DEBUG && echo "manual adjust detected (diff $diff), pausing auto for ${ML_MANUAL_PAUSE}s"
				$ML_AUTO_KBD && update_kbd $light
				return
			fi
		fi

		# Check if manual pause is active
		local now=$(date +%s)
		if (( now < manual_pause_until )); then
			$ML_DEBUG && echo "manual pause active ($(( manual_pause_until - now ))s remaining), skip screen"
			$ML_AUTO_KBD && update_kbd $light
			return
		fi
	fi

	# Hysteresis + asymmetric timing gate
	if ! should_update_brightness $light; then
		return
	fi

	$ML_DEBUG && echo "brightness update confirmed"
	$ML_AUTO_SCREEN && update_screen $light
	$ML_AUTO_KBD && update_kbd $light
}
```

- [ ] **Step 2: Verify no bin/offset references in update**

Run: `grep -n 'light_bin\|set_bin_offset\|screen_target.*light\|screen_range' src/macbook-lighter-ambient.sh`

Expected: No matches in the `update` function. `screen_target` should only be called inside `update_screen`.

- [ ] **Step 3: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "refactor(ambient): rewrite update with auto-calib and manual pause"
```

---

### Task 9: Rewrite `init` function

**Files:**
- Modify: `src/macbook-lighter-ambient.sh` (init function, ~lines 359-392)

- [ ] **Step 1: Replace the `init` function**

Replace the entire `init` function with:

```bash
function init {
	$ML_DEBUG && echo "initializing backlights..."

	local light=$(get_smoothed_light)
	last_trigger_light=$light

	# Initialize auto-calibration with confirmed hardware range
	sensor_min=0
	sensor_max=255

	# If first reading is above 255, expand sensor_max
	(( light > sensor_max )) && sensor_max=$light

	$ML_DEBUG && echo "init: sensor_min=$sensor_min sensor_max=$sensor_max light=$light"

	local screen_from=$(cat $screen_file)
	local kbd_from=$(cat $kbd_file)

	if $ML_AUTO_SCREEN; then
		local screen_to
		screen_to=$(screen_target $light)
		if (( screen_to != screen_from )); then
			transition $screen_from $screen_to $screen_file
		fi
		screen_last_set=$screen_from
		$ML_DEBUG && echo "init: screen_from=$screen_from screen_to=$screen_to"
	fi

	if $ML_AUTO_KBD; then
		update_kbd $light
	fi
}
```

- [ ] **Step 2: Verify no bin/offset/power references in init**

Run: `grep -n 'screen_user_offset\|init_offset\|power_coef\|universal_offset' src/macbook-lighter-ambient.sh`

Expected: No matches anywhere in the file.

- [ ] **Step 3: Commit**

```bash
git add src/macbook-lighter-ambient.sh
git commit -m "refactor(ambient): rewrite init with auto-calib, remove bin/power logic"
```

---

### Task 10: Update config file

**Files:**
- Modify: `macbook-lighter.conf`

- [ ] **Step 1: Update the config file**

Replace the entire content of `macbook-lighter.conf` with:

```conf
# configuration for macbook-lighter

# duration for each transition, in seconds
ML_DURATION=1.5

# time frame (in seconds) for each step
ML_FRAME=0.017

# check interval (in seconds)
ML_INTERVAL=5

# ambient light threshold above which keyboard backlight turns off
ML_BRIGHT_ENOUGH=8

# keyboard brightness in dark (0-255)
ML_KBD_BRIGHT=128

# turn off keyboard backlight after N seconds of inactivity (0 = disabled)
ML_KBD_TIMEOUT=30

# enable auto adjust keyboard backlight
ML_AUTO_KBD=true

# enable auto adjust screen backlight
ML_AUTO_SCREEN=true

# sub-samples per poll for median filter
ML_SENSOR_SAMPLES=3

# seconds between sub-samples
ML_SENSOR_SAMPLE_DELAY=0.3

# EWMA smoothing factor (0.0-1.0, lower = smoother)
ML_EWMA_ALPHA=0.2

# proportional dead-band percentage to prevent oscillation
ML_HYSTERESIS_PCT=15

# polls to confirm before brightening (fast)
ML_BRIGHTEN_CONFIRMS=1

# polls to confirm before dimming (slow)
ML_DIM_CONFIRMS=3

# minimum sensor range to prevent calibration collapse
ML_SENSOR_RANGE_MIN=10

# fraction of sensor range that decays per minute (0.0-1.0)
ML_DECAY_RATE=0.5

# seconds to pause auto screen adjust after manual slider change
ML_MANUAL_PAUSE=300

# debug info to stdout
# Available values: false, true
ML_DEBUG=false
```

- [ ] **Step 2: Verify old variables are gone and new ones are present**

Run: `grep -c 'ML_SCREEN_MIN_BRIGHT\|ML_BATTERY_DIM' macbook-lighter.conf && echo "FAIL" || echo "PASS"`

Expected: PASS (0 matches for removed variables).

Run: `grep -c 'ML_SENSOR_RANGE_MIN\|ML_DECAY_RATE\|ML_MANUAL_PAUSE' macbook-lighter.conf`

Expected: 3 matches (one per new variable).

- [ ] **Step 3: Commit**

```bash
git add macbook-lighter.conf
git commit -m "refactor(conf): replace old vars with 1:1 mapping config"
```

---

### Task 11: Final validation — syntax check and full review

**Files:**
- Verify: `src/macbook-lighter-ambient.sh`
- Verify: `macbook-lighter.conf`

- [ ] **Step 1: Bash syntax check**

Run: `bash -n src/macbook-lighter-ambient.sh`

Expected: No output (clean syntax).

- [ ] **Step 2: Verify no references to removed components remain**

Run: `grep -n 'screen_user_offset\|light_bin\|get_bin_offset\|set_bin_offset\|power_coef\|screen_range\|ML_SCREEN_MIN_BRIGHT\|ML_BATTERY_DIM\|power_file=' src/macbook-lighter-ambient.sh`

Expected: No matches.

- [ ] **Step 3: Verify all new components are present**

Run: `grep -n 'function update_calibration\|function screen_target\|sensor_min\|sensor_max\|manual_pause_until\|ML_SENSOR_RANGE_MIN\|ML_DECAY_RATE\|ML_MANUAL_PAUSE' src/macbook-lighter-ambient.sh`

Expected: All present.

- [ ] **Step 4: Verify the script still has the correct entry point**

Run: `tail -3 src/macbook-lighter-ambient.sh`

Expected: `init`, `watch` on separate lines at the end.

- [ ] **Step 5: Commit (only if any fixes were needed)**

```bash
git add -A
git commit -m "fix(ambient): final cleanup from validation pass"
```

(If no fixes needed, skip this commit.)

---

### Task 12: Install and smoke test

**Files:**
- Test: live system

- [ ] **Step 1: Install the updated files**

Run: `sudo make install`

- [ ] **Step 2: Restart the daemon**

Run: `systemctl --user restart macbook-lighter.service`

- [ ] **Step 3: Verify the daemon is running**

Run: `systemctl --user status macbook-lighter.service`

Expected: Active (running).

- [ ] **Step 4: Enable debug and check calibration values**

Run: `ML_DEBUG=true /usr/bin/macbook-lighter-ambient` (in a separate terminal, for a few seconds)

Expected: Output shows `calib: sensor_min=X sensor_max=Y range=Z` with sensible values, `init:` message, and smooth polling.

- [ ] **Step 5: Verify slider sync**

Change ambient light (cover sensor, shine light), observe the GNOME brightness slider moves predictably between 0% and 100%.

- [ ] **Step 6: Final commit if any live-test fixes were needed**

```bash
git add -A
git commit -m "fix(ambient): fixes from smoke test"
```