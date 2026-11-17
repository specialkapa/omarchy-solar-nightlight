# Solar Nightlight ☀️

![Solar Nightlight](preview.png)

> **Fork note (specialkapa.solar-nightlight):** this fork also makes **display brightness follow the sun** at your location and adds a bar widget with a **timed brightness offset**. See [Solar brightness](#solar-brightness) below.


> **Astronomical solar nightlight daemon for `hyprsunset` on Hyprland & Omarchy Linux.**

`solar-nightlight` dynamically calculates your real-world astronomical sunrise, sunset, and civil twilight times based on your local geolocation, and smoothly eases screen color temperature between crisp daylight (`6500K`) and warm nightlight (`4000K`).

Written in pure standard-library Python 3 with **zero external dependencies**.

---

## What It Does
Instead of an arbitrary clock timer that turns your screen suddenly orange, `solar-nightlight` uses real-world astronomical NOAA math to calculate exact sunrise, sunset, and twilight times for your local coordinates. 

Over a 45-minute window at dawn and dusk, it gently ramps your display between crisp daylight (`6500K`) and warm nightlight (`4000K`) using smooth cosine easing—so gradual your eyes will never notice the change.

## Who It's For
* **Night Owls & Late Workers:** Reduces eye fatigue, headaches, and sleep disruption automatically without needing to remember to toggle night mode.
* **Zero-Maintenance Minimalists:** Requires zero manual scheduling. It dynamically adjusts as daylight hours lengthen in summer and shorten in winter, completely offline.
* **Anyone Disliking Sudden Color Jumps:** Eliminates the jarring, instant orange snap common in basic schedulers.

---

## Features

- ☀️ **Astronomical Solar Calculations**: Pure implementation of NOAA solar position equations calculating daily solar declination, civil dawn/dusk, and sunrise/sunset.
- 🌍 **Auto-Geolocation with Offline Caching**: Automatically discovers local coordinates via IP on initial run and caches locally in `~/.cache/solar-nightlight/location.json` for 100% offline reliability.
- 🌊 **Smooth Cosine Transition**: Gently ramps color temperature over a 45-minute window during dawn and dusk using smoothstep easing, eliminating jarring screen color jumps.
- 🔄 **Self-Healing IPC**: Continuously tests `hyprsunset` socket connectivity. Automatically cleans up stale or orphaned processes after Hyprland compositor reloads or sleep/wake cycles.
- 🎛️ **Manual Override Aware**: Respects manual temperature adjustments made via the Omarchy bar, `omarchy toggle nightlight`, or custom keybindings until the next solar phase transition.
- ⚙️ **Native Shell Service & Systemd**: Runs natively as an Omarchy background service (`Service.qml`) with automatic crash recovery, or as a standalone user systemd service for raw Hyprland setups.

---

## Installation

### Method 1: Omarchy Plugin (Recommended)

For **Omarchy Linux** users, install and enable directly via Omarchy's plugin manager:

```bash
omarchy plugin add https://github.com/sunshine144/solar-nightlight --enable
```

*Managed natively as a background service by Omarchy Shell (`Service.qml`). No systemd setup required.*

---

### Method 2: Standalone Hyprland (Non-Omarchy)

For **standalone Hyprland** setups (Arch, Fedora, NixOS, etc.) using systemd:

```bash
# 1. Clone repository
git clone https://github.com/sunshine144/solar-nightlight.git ~/.local/share/solar-nightlight

# 2. Symlink executable to PATH
mkdir -p ~/.local/bin ~/.config/systemd/user
ln -sf ~/.local/share/solar-nightlight/bin/solar-nightlight ~/.local/bin/solar-nightlight

# 3. Enable and start user service
cp ~/.local/share/solar-nightlight/systemd/solar-nightlight.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now solar-nightlight.service
```

---

## CLI Usage

Inspect live solar times, current phase, target temperature, and override status:

```bash
solar-nightlight --status
```

Output:
```text
--- solar-nightlight Status ---
Location:           Washington, District of Columbia (38.9072, -77.0369)
Current Local Time: 2026-08-30 14:00:11
Dawn (Civil):       06:08:42
Sunrise:            06:36:15
Sunset:             19:46:18
Dusk (Civil):       20:13:51
Solar Phase:        DAY
Target Temperature: 6500K
Actual hyprsunset:  6500K
Manual Override:    Inactive
```

### Customization Flags

```bash
# Custom night temperature (e.g. extra warm 3500K)
solar-nightlight --night-temp 3500

# Custom transition window (e.g. 60 minutes)
solar-nightlight --transition-mins 60

# Force reset any manual overrides and reapply solar target
solar-nightlight --force
```

---

## Management & Service Logs

### For Omarchy Plugin Users:
```bash
# Toggle plugin off or on
omarchy plugin disable sunshine144.solar-nightlight
omarchy plugin enable sunshine144.solar-nightlight

# View live Omarchy shell logs
journalctl --user -u omarchy-shell -f
```

### For Standalone Hyprland (systemd) Users:
```bash
# View live service logs
journalctl --user -u solar-nightlight -f

# Restart daemon
systemctl --user restart solar-nightlight

# Stop daemon
systemctl --user stop solar-nightlight
```

---

## Solar brightness

The daemon computes the sun's elevation at your location every tick and maps it to a brightness:
`night_brightness` at or below `low_elevation` (civil twilight, -6°), `day_brightness` at or above
`high_elevation` (25°), cosine-eased in between. So brightness rises through the morning, peaks around
noon (lower in winter, when the sun stays low) and falls towards dusk.

It is written to:

- **External monitors** over DDC/CI (`ddcutil setvcp 10`), auto-detected and re-detected when monitors change.
- **The laptop panel** via `brightnessctl`, only while the internal display (eDP/LVDS/DSI) is enabled.

**Colour temperature scale.** The panel shows a warm-to-cool bar from your night to day temperature with a marker at the current value. If you set a temperature by hand, a tick marks the solar target and a **Resume solar schedule** button appears.

**Cloud cover.** While the sun is up the daemon fetches current total cloud cover for your coordinates
from [Open-Meteo](https://open-meteo.com) (keyless, HTTPS, 5s timeout, every `cloud_refresh_mins`, default 15)
and shrinks the daylight part of the curve by up to `cloud_strength` (default 0.4): at full overcast, midday
brightness lands 40% of the way back towards the night level. Readings older than 90 minutes are ignored, so
being offline just means clear-sky behaviour. Set `"clouds": false` or pass `--no-clouds` to turn it off.

Displays are only rewritten when the target moves by `brightness_step` points (default 2) to spare the monitors' controllers.

### Offset override

Click the bar icon to open the panel: pick an offset (-50..+50 points, on top of the solar brightness),
a duration (30m, 1h, 2h, 4h or ∞ = until cleared) and press **Apply**. The bar icon shows the active offset;
**right-click** the icon (or press **Reset**) to clear it. The daemon picks changes up within a second.

From the CLI:

```bash
solar-nightlight --offset +15 --for 60   # 15 points brighter for an hour
solar-nightlight --offset -20            # 20 points dimmer until cleared
solar-nightlight --clear-offset
solar-nightlight --status
```

### Configuration

Optional `~/.config/solar-nightlight/config.json` (see `config.example.json`). CLI flags win over the file.
Location is taken from, in order: `"lat"`/`"lon"` (+ optional `"location_name"`) in this file;
the coordinates set for Omarchy's weather widget (`omarchy-weather-location --set <name> <lat>,<lon>`);
an IP lookup via `geo.omarchy.org` (falling back to `ipapi.co`), cached for 30 days. IP lookups are
usually within a few tens of km, which moves sun times by a minute or two, so the config file is optional. Set `"brightness": false` (or pass `--no-brightness`) to
manage only colour temperature. Restart the daemon after editing: `omarchy plugin disable specialkapa.solar-nightlight && omarchy plugin enable specialkapa.solar-nightlight`.

---

## License

[MIT](LICENSE) © 2026 sunshine144
