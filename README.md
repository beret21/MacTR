# MacTR

[한국어](README.ko.md)

**Mac + Thermalright** — Native macOS menu bar app for the Thermalright Trofeo Vision 9.16 LCD display.

Turns the 1920x480 LCD on your Thermalright CPU cooler into a real-time system monitoring dashboard, directly from macOS. No Windows required.

![System Monitor Dashboard](img/monitor-final.png)

## Features

- **5-panel dashboard**: CPU, GPU, Memory, Disk, System
- **CPU temperature** via IOHIDEventSystemClient (no sudo required)
- **180° rotation toggle** — Settings option for displays with inverted orientation
- **Network traffic** with mirror bar chart (download/upload history)
- **Disk I/O** with mirror bar chart (read/write history)
- **USB hotplug** — auto-reconnect on plug/unplug and sleep/wake
- **Menu bar app** — runs in background, no dock icon
- **Connection status badge** — red indicator when LCD is disconnected
- **Software brightness** — 10 levels
- **Adaptive layout** — supports 8 to 24+ CPU cores (M1 through M5)

## Hardware

| | |
|---|---|
| **Product** | [Thermalright Trofeo Vision 9.16 LCD](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-black/) ([White](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-white/)) |
| **Display** | 9.16" IPS, 1920 x 480 |
| **Connection** | USB Type-C (USB 2.0) |
| **Windows Software** | [TRCC (official)](https://www.thermalright.com/support/download/) |

## Requirements

- macOS 26 (Tahoe) — developed and tested
- macOS 15 (Sequoia) — likely compatible (not tested)
- macOS 14 (Sonoma) — may work with minor changes (not tested)
- Apple Silicon (M1/M2/M3/M4/M5)
- [Homebrew](https://brew.sh)
- Thermalright LCD cooler (Trofeo Vision 9.16 or compatible)
- USB-C direct connection

## Install

### Download (recommended)

1. Download `MacTR.dmg` from [Releases](https://github.com/beret21/MacTR/releases)
2. Open the DMG and drag `MacTR.app` to Applications
3. First launch: **Right-click → Open** (required once for unsigned apps)

### Build from source

```bash
brew install libusb pkg-config

git clone https://github.com/beret21/MacTR.git
cd MacTR
swift build -c release

.build/release/MacTR
```

## Usage

### GUI Mode (default)

```bash
./MacTR
```

Runs as a menu bar app. Click the display icon to see connection status, open Settings, or quit.

### CLI Mode

```bash
./MacTR --cli                    # System monitor on LCD
./MacTR --cli --test             # USB connection test
./MacTR --cli -b 7              # Set brightness level 7
```

### Snapshot Mode

```bash
./MacTR --snapshot output.png            # Render one frame as PNG
./MacTR --snapshot output.png --cores 24 # Simulate 24-core layout
```

## Dashboard

| Panel | Metrics |
|-------|---------|
| **CPU** | Usage % arc gauge, per-core bars, CPU temperature, load average (1/5/15 min) |
| **GPU** | Device/Renderer/Tiler utilization %, VRAM usage |
| **Memory** | Active/Wired/Compressed/Available breakdown, swap, network traffic chart |
| **Disk** | APFS container usage, read/write I/O chart |
| **System** | Clock, date, uptime, process count, load average, battery |

## Supported Devices

| Device | VID:PID | Protocol | Status |
|--------|---------|----------|--------|
| Trofeo Vision 9.16 | `0416:5408` | LY Bulk | Tested |
| LY1 variant | `0416:5409` | LY1 Bulk | Supported (untested) |

## Acknowledgments

- [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) — LY Bulk protocol reverse engineering
- [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) — IOHIDEventSystemClient temperature reading

## Changelog

### v1.2.0 (2026-03-29)
- Add 180° rotation toggle in Settings > Display for displays with inverted orientation
- Rename temperature label from "Airflow" to "Temp"
- CLI: `--no-rotate` flag support

### v1.1.1 (2026-03-28)
- Fix: Disk I/O arithmetic overflow crash when disks are unmounted (e.g. DMG eject)

### v1.1.0 (2026-03-28)
- P-core / E-core distinction display
- Core type detection via `sysctl hw.perflevel0.logicalcpu`
- English day-of-week display
- Unified Network / I/O chart layout

### v1.0.0 (2026-03-28)
- 5-panel dashboard: CPU, GPU, Memory, Disk, System
- Airflow temperature (IOHIDEventSystemClient)
- Network traffic mirror bar chart (sysctl 64-bit)
- Disk I/O mirror bar chart (IOBlockStorageDriver)
- USB hotplug + sleep/wake recovery
- Menu bar app (NSStatusItem, connection status badge)
- Software brightness (10 levels)
- Adaptive layout for 8–24+ cores
- About menu with version display
- .app bundle packaging (embedded libusb)

## License

MIT

---

Built with Swift 6.3 + libusb. Co-developed with [Claude](https://claude.ai).
