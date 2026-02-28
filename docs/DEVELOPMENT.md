# Development Guide

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16+ (for building from source)
- [Rust toolchain](https://rustup.rs/) (for gyroflow-core; optional if you don't need gyro stabilization)
- HDR display recommended (e.g. Apple Pro Display XDR, MacBook Pro with Liquid Retina XDR)

## Prerequisites

```bash
# Build tools and library headers (required for compiling libmpv from source)
brew install meson ninja nasm pkg-config libass libplacebo little-cms2

# Rust toolchain (required for gyroflow-core)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

## Build & Package

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

## Without building from source

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
