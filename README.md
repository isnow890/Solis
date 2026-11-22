<p align="center">
  <img src="docs/assets/icon.png" width="116" height="116" alt="halo app icon" />
</p>

<h1 align="center">halo</h1>

<p align="center">
  <strong>Lightweight native macOS menu bar app for cursor-aware per-display brightness &amp; HiDPI scaling.</strong>
</p>

<p align="center">
  <a href="https://github.com/isnow890/halo/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/isnow890/halo/ci.yml?label=build&style=flat-square" alt="CI Build" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-3ee6be?style=flat-square" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.ko.md">한국어</a>
</p>

---

## Why halo?

**halo** combines the two everyday features people actually use from **MonitorControl** and **BetterDisplay** into a single fast, zero-dependency, pure-Swift menu bar app — no Electron, no background daemons, no sprawling preferences tree.

- **Cursor-Aware Brightness Keys**: Press `F1` / `F2`, `F14` / `F15`, or `⌃⌥↑` / `⌃⌥↓` to adjust **only the display under your mouse cursor** (or switch to All / Main display), with a smooth 120Hz translucent HUD on that exact screen.
- **3-Tier Brightness Engine**:
  - **Native (`DisplayServices`)** for MacBook Liquid Retina / XDR & Apple displays
  - **Hardware DDC/CI (`IOAVService`)** for Apple Silicon external monitors (per-port serial queues & VCP readback verification)
  - **Software Dimming (Overlay / Gamma LUT)** automatic fallback for DisplayLink docks, DDC-less portable monitors, and sub-hardware dimming
- **Safe HiDPI & Refresh Rate Switcher**: Exposes hidden HiDPI/LoDPI modes and fractional refresh rates (`59.94Hz`, `47.95Hz`, `120Hz`, `130Hz`, etc.) with a **15-second auto-revert preview** so an unsupported mode never leaves you stuck.
- **One-Click Virtual HiDPI Mirroring (`CGVirtualDisplay`)**: Sharp 2× HiDPI scaling on non-Retina external monitors (including vertical/portrait displays) without rebooting or disabling SIP.
- **Hover-to-Identify & Display Override Export**: Hover a display card header to highlight that monitor on screen, or export native macOS `scale-resolutions` `.plist` overrides for permanent EDID-level HiDPI.
- **Built-in Update Checker**: Zero-dependency GitHub Releases check (once per day, toggleable in Settings).

### Quick Comparison

| Capability | halo | MonitorControl | BetterDisplay |
| :--- | :---: | :---: | :---: |
| Cursor-aware brightness keys + per-display HUD | ✅ | ✅ | ✅ |
| Native + Apple Silicon DDC/CI + SW fallback | ✅ | ✅ | ✅ |
| Native HiDPI & fractional refresh rate switcher | ✅ | — | ✅ |
| One-click virtual HiDPI mirroring (`CGVirtualDisplay`) | ✅ | — | ✅ (Pro) |
| 15s auto-revert resolution preview | ✅ | — | ✅ |
| Pure Swift, zero third-party dependencies, MIT open source | ✅ | ✅ (MIT) | Proprietary |

---

## Installation

### Option 1: Prebuilt Release (GitHub Releases)

1. Download `halo-vX.Y.Z-arm64.dmg` (or `.zip`) from [Releases](https://github.com/isnow890/halo/releases).
2. Drag **halo.app** into `/Applications`.
3. Open **halo.app** from Applications. For an older download labeled *Ad-Hoc Signed Build*, see the first-launch instructions on its release page.

### Option 2: Build from Source

Requires macOS 14+ (Apple Silicon) and Xcode Command Line Tools (`swift`).

```bash
git clone https://github.com/isnow890/halo.git
cd halo

# Ad-hoc local build (or omit CODESIGN_IDENTITY to sign with your Apple Development certificate)
CODESIGN_IDENTITY="-" ./scripts/build-app.sh --install
open /Applications/halo.app
```

Package a `.dmg`, `.zip`, and `SHA256SUMS.txt`:

```bash
VERSION=0.1.0 ./scripts/package-dmg.sh
```

---

## Permissions & Shortcuts

Sliders, resolution switching, and virtual HiDPI work **without** any special permissions. To intercept global brightness keys, grant `halo` access in:

- **macOS 14–26**: `System Settings → Privacy & Security → Accessibility`
- **macOS 27+**: `System Settings → Privacy & Security → Device Control and Data Access`

| Shortcut | Action |
| :--- | :--- |
| `☀` Brightness keys / `F14` · `F15` | Adjust brightness on the target display (default: cursor display) |
| Standard `F1` · `F2` | Enabled via *"Use standard F1 / F2"* in Settings (auto-enabled when `fnState = 1`) |
| `⌥ + ⇧ + Brightness Key` | Fine 1/64-step brightness adjustment |
| `⌃ + ⌥ + ↑ / ↓` | External keyboard fallback shortcut (toggleable in Settings) |

---

## Read-Only Diagnostics

Inspect connected displays, Apple Silicon DDC/CI probe status, event tap permissions, and HiDPI modes without modifying any display state:

```bash
/Applications/halo.app/Contents/MacOS/halo --diagnose
```

---

## Privacy, Signing & Honest Notes

1. **Daily Update Check (Opt-Out)**: When *"Check for updates automatically"* is on, `halo` sends one unauthenticated `GET` request per day to `https://api.github.com/repos/isnow890/halo/releases/latest` to compare the latest version tag. No analytics, telemetry, or personal data are collected, and you can disable it anytime in Settings.
2. **Permissions after an update**. When switching from an ad-hoc build to a Developer ID build, macOS may ask for Accessibility or Device Control permission again.
3. **Private macOS APIs**: Uses `DisplayServices`, `IOAVService`, and `CGVirtualDisplay` (the same underlying frameworks used by MonitorControl and BetterDisplay). All private symbols are loaded dynamically and degrade safely if a future macOS update changes them.
4. **Not on the Mac App Store**: Global `CGEventTap` and `IOAVService` DDC/CI are incompatible with App Sandbox.
5. **Hardware Variance**: DDC/CI depends on monitor firmware, hubs, and cables. DisplayLink adapters do not expose Apple Silicon `IOAVService` DDC/CI, so `halo` automatically falls back to Software Overlay / Gamma dimming.
6. **Virtual Display Lifecycle**: Virtual HiDPI displays exist in process memory and disappear when `halo` quits. Clean exits restore prior mirror layouts; an abrupt crash (`SIGKILL`) may require re-arranging displays in System Settings.

<details>
<summary><strong>Troubleshooting / FAQ</strong></summary>

- **If macOS reports that halo is damaged**, download the DMG again and compare its SHA-256 with the checksum on the same release page.
- **Brightness keys don't respond even though `halo` is toggled on in Settings**: macOS sometimes retains a stale TCC entry after replacing an ad-hoc signed app. Select `halo` in Privacy & Security, click `−` to remove it, relaunch `halo`, and grant permission again.
- **External monitor only shows Software Dimming (`SW`)**: Verify DDC/CI is enabled in the monitor's own OSD menu. DisplayLink docks and some HDMI/USB-C adapters block I2C/DDC packets; run `/Applications/halo.app/Contents/MacOS/halo --diagnose` to see the exact probe result.

</details>

---

## Architecture

```text
Sources/
├── CDisplayBridge/        # Thin Objective-C bridge (DisplayServices, IOAVService DDC/CI, CGVirtualDisplay)
└── halo/
    ├── HaloApp.swift      # Pure AppKit menu bar entry point, custom template icon & --diagnose CLI
    ├── Models/            # DisplayItem, DisplayModeItem, VirtualDisplayPreset
    ├── Services/          # DisplayController, DDCChannel, BrightnessKeyMonitor, BrightnessOSDController,
    │                      # SoftwareDimmer, DisplayModeManager, VirtualDisplayManager, DisplayTopology,
    │                      # UpdateChecker
    └── UI/                # SwiftUI MenuBarPopoverView
```

---

## License

Released under the [MIT License](LICENSE).
