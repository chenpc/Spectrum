# Spectrum

A native macOS photo and video viewer built with a **Sony camera workflow** in mind — correctly renders HLG HDR photos and videos, and plays back gyro-stabilized footage in real time, all things that macOS Preview/Photos cannot do.

<img src="Spectrum/Resources/AppIcon.svg" width="250">

## Why Spectrum?

If you shoot with a Sony camera (ZV-E1, A7 series, etc.), you likely have:

1. **HLG Still Images** (.HIF / HEIF) — Sony's HDR photo format. Apple Preview and Photos display them washed-out because they don't correctly tone-map HLG with BT.2020 gamut.
2. **HLG / S-Log Video** — HDR video that needs proper color space handling for accurate playback.
3. **Gyroscope data embedded in video** — Sony cameras record IMU sensor data for post-stabilization, but no viewer lets you preview the stabilized result without rendering first.

Spectrum solves all three: HDR photos render with full EDR headroom, HDR video plays back correctly, and gyro-stabilized video previews in real time — powered by [gyroflow-core](https://github.com/gyroflow/gyroflow) running as an in-process library, not a subprocess.

## Features

### Sony HLG Still Image

- **Native HLG rendering** — Sony `.HIF` (HEIF with HLG transfer function) rendered via `itur_2100_HLG` color space with BT.2020 gamut and full EDR headroom on HDR displays
- **10-bit 4:2:2** — Preserves the full dynamic range Sony cameras capture (PictureProfile 10, headroom ~4.93x)
- **HDR/SDR Toggle** — Click the HDR badge to instantly compare HDR vs tone-mapped SDR
- **Apple Gain Map HDR** — Also supports iPhone HDR photos with auxiliary gain map data

### Sony HLG / S-Log Video

- **HLG video** — Correct BT.2100 HLG playback with HDR pass-through to display
- **S-Log2 / S-Log3** — Sony's log gamma curves with proper EOTF rendering
- **Dual player backends** — libmpv (OpenGL render API) and AVPlayer, selectable per HDR type
- **All HDR formats** — HLG, HDR10, Dolby Vision, S-Log2, S-Log3, SDR
- **HDR/SDR toggle** — Switch between HDR and SDR during playback
- **Hardware decoding** — VideoToolbox acceleration with configurable decode modes
- **Per-type player override** — Choose libmpv or AVPlayer independently for each format (e.g. AVPlayer for Dolby Vision, mpv for HLG)
- **Playback diagnostics** — On-screen badge showing render FPS, stability metric, codec info, and dropped frame counts

### Real-Time Gyro Stabilization (Gyroflow)

Preview gyro-stabilized video without rendering — powered by [gyroflow-core](https://github.com/gyroflow/gyroflow) as an in-process library. Sony cameras (ZV-E1, A7C II, A7 IV, FX30, etc.) embed IMU gyroscope/accelerometer data in every video file; Spectrum reads this data and applies real-time 3D perspective correction during playback.

- **Zero-export preview** — See stabilized footage instantly while browsing, no need to render first
- **Sony IBIS support** — Per-scanline in-body image stabilization data correction (tested with ZV-E1)
- **Per-video config** — Each video can have custom gyro settings (smoothing, sync offset, horizon lock, etc.), stored in XMP sidecar
- **Configurable parameters** — Smoothing (global or per-axis pitch/yaw/roll), gyro sync offset, lens profile, FOV scaling, horizon lock, adaptive zoom
- **Toggle on/off** — Press `s` during playback to enable/disable stabilization in real time

### Browsing & Navigation

- **Folder-based browsing** — Scan existing folders directly, no import or copy
- **Timeline grid** — Photos grouped by date (Today, This Week, This Month, Older) with adaptive column layout
- **Keyboard navigation** — Arrow keys to move, Enter to open, Escape to go back
- **Subfolder tiles** — Subfolders displayed as cover-image tiles, sorted by most recent photo
- **Sidebar** — Folder tree with breadcrumb navigation, context menu (rename, copy, cut, paste, show in Finder)
- **Drag & drop** — Add folders by dragging from Finder

### Metadata & Inspector

- **EXIF inspector** — Toggle with `i` key: file info, camera/lens, exposure settings (aperture, shutter, ISO, focal length, exposure bias, metering, flash, white balance), GPS coordinates
- **HDR metadata** — Color profile, bit depth, headroom value, dynamic range indicator
- **Video metadata** — Duration, video codec, audio codec

### Non-Destructive Editing

- **Rotate** — 90° counter-clockwise rotation
- **Flip** — Horizontal mirror, composable with rotation (D4 group math)
- **Crop** — Visual crop overlay with rule-of-thirds grid, drag handles, pixel dimensions
- **XMP sidecar** — All edits stored in `{filename}.xmp` (EXIF orientation 1–8 + Camera Raw crop), never modifies original files
- **Restore** — One-click reset to original

### Other

- **Fullscreen mode** — `f` key for distraction-free viewing (photos and videos)
- **Thumbnail caching** — Three-tier cache (memory + disk + on-demand), configurable size limit (100 MB – 2 GB), LRU eviction
- **Security-scoped bookmarks** — macOS Sandbox compatible with persistent folder access
- **File format support** — JPEG, HEIF/HEIC, PNG, TIFF, RAW (DNG, CR3, NEF, etc.), MP4, MOV, MKV

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16+ (for building from source)
- [Rust toolchain](https://rustup.rs/) (for gyroflow-core; optional if you don't need gyro stabilization)
- HDR display recommended (e.g. Apple Pro Display XDR, MacBook Pro with Liquid Retina XDR)

## Build

### Prerequisites

```bash
# Build tools and library headers (required for compiling libmpv from source)
brew install meson ninja nasm pkg-config libass libplacebo little-cms2

# Rust toolchain (required for gyroflow-core)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Build & Package

```bash
# Clone with submodules (mpv, FFmpeg, gyroflow)
git clone --recurse-submodules https://github.com/chenpc/Spectrum.git
cd Spectrum

# Build Release (automatically compiles mpv + FFmpeg on first run)
./release.sh
```

The DMG will be created in the project root directory.

To rebuild mpv or gyroflow-core manually:

```bash
./mpv-build/build-all.sh        # build FFmpeg + mpv + bundle dylibs
./mpv-build/build-all.sh clean   # remove all build artifacts

cd gyro-wrapper && cargo build --release   # rebuild gyroflow-core
```

### Without building from source

If you skip the Homebrew prerequisites, the Xcode build will:
- **libmpv** — fall back to IINA.app's bundled libmpv (if IINA is installed)
- **gyroflow-core** — gyro stabilization will be unavailable

The app works without either library — video playback falls back to AVPlayer.

## Architecture

```
Spectrum/
├── Models/           # SwiftData models (Photo, ScannedFolder)
├── Views/
│   ├── Sidebar/      # Folder tree navigation
│   ├── Grid/         # Timeline photo grid with keyboard nav
│   └── Detail/       # HDR photo/video detail view, mpv + AVPlayer
├── Services/
│   ├── ImagePreloadCache.swift  # HDR format detection + rendering
│   ├── MPVLib.swift             # libmpv runtime loader (dlopen)
│   ├── GyroCore.swift           # gyroflow-core runtime loader
│   ├── FolderScanner.swift      # Filesystem scanning (@ModelActor)
│   ├── ThumbnailService.swift   # Three-tier thumbnail cache
│   ├── XMPSidecarService.swift  # XMP sidecar read/write (edits + gyro config)
│   └── CGImageRotation.swift    # CGImage rotate + flip
├── ViewModels/       # Timeline section logic
└── Resources/        # App icon, bundled dylibs

mpv-build/            # Shell scripts to build libmpv from source
mpv/                  # Git submodule — mpv player
FFmpeg/               # Git submodule — FFmpeg
gyro-wrapper/         # Rust cdylib wrapper for gyroflow-core
gyroflow/             # Git submodule — gyroflow
```

## License

[GPL-3.0](LICENSE)
