# Changelog

All notable changes to NanoViz are documented in this file. Pre-fork
history (audioleaf v3.x and earlier) is captured in
[NOTICE](NOTICE); the version line below resets to `1.0.0` as the
starting point for the NanoViz fork.

## [1.0.0] — 2026-05-24

First NanoViz release. The project was forked from
[audioleaf](https://github.com/alfazet/audioleaf) by Antoni Zasada and
pivoted from a terminal-only macOS visualizer into a Pi-first AirPlay
appliance with a React control panel. Headline changes vs. the upstream:

### Added

- **AirPlay 2 receiver** baked into the container via `shairport-sync` +
  `nqptp` (built from source). NanoViz appears in any iOS/macOS AirPlay
  picker; no separate receiver needed.
- **Volume-driven brightness.** The AirPlay volume slider on the
  streaming device controls panel brightness; audio playback volume is
  unaffected (`ignore_volume_control = "yes"`). Linear map `[-30, 0] dB
  → [1, 100]` brightness; mute holds the current value.
- **Album-art palette extraction.** `color_source = "artwork"` pulls
  colors from the current track's cover art instead of a fixed palette.
- **Web control panel** (React + axum). Pair devices, switch
  effects/palettes, watch live panel preview, see now-playing track and
  configured AirPlay name, browse panel layout. Replaces the old TUI.
- **Web-UI device pairing.** `POST /api/devices/discover` runs SSDP and
  `POST /api/devices/pair` calls the Nanoleaf `/api/v1/new` flow. No
  more "pair from the CLI first."
- **Containerized deployment.** `pi/setup.sh` installs podman, the
  `snd-aloop` kernel module, a Quadlet drop-in, and a polkit rule for
  no-sudo `systemctl` control. `pi/uninstall.sh` reverses it.
- **Multi-instance support.** `--name=NAME` lets you run more than one
  receiver per Pi with separate config dirs, container names, services,
  and AirPlay names.
- **Configurable AirPlay display name.** `--airplay-name="..."` or the
  `NANOVIZ_AIRPLAY_NAME` env var; surfaced in the web UI header.
- **Auto image-tag detection.** `pi/setup.sh` defaults to `:dev` on
  non-`main` git branches and `:latest` on `main`; override with
  `--image-tag=`.
- **Palettes pulled live from the device.** No more static
  `src/palettes.rs` catalog; whatever palettes are saved as effects on
  the connected Nanoleaf are what show up in the dropdown, with inline
  color swatches.
- **Panic hook** that flushes panic info + backtrace to stderr before
  the `panic = "abort"` runtime kills the process — so panics are
  visible in `journalctl` / `podman logs` instead of vanishing into
  exit code 134.

### Changed

- Renamed crate, binary, container image, env vars (`AUDIOLEAF_*` →
  `NANOVIZ_*`), default config dir (`~/.config/audioleaf` →
  `~/.config/nanoviz`), systemd unit, polkit rule, and Quadlet
  filename. Migration: `mv ~/.config/audioleaf ~/.config/nanoviz` or
  re-run setup with `--config-dir`.
- Effect names: `Pulse` → `Ripple`.
- Build matrix: Linux + macOS only. Windows was never functional
  (entire AirPlay/visualizer stack is Linux-gated) and has been removed
  from CI and source.

### Removed

- TUI / keybind controls (replaced by the web UI).
- Native GUI window (replaced by the web UI).
- `dump layout`, `dump info`, `dump palettes` CLI subcommands.
- Static palette catalog (palettes now come from the device).
- Windows code paths and CI matrix entry.
