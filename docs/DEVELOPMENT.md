# Development Guide

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16+ (for building from source)
- [Rust toolchain](https://rustup.rs/) (for gyroflow-core; optional if you don't need gyro stabilization)
- HDR display recommended (e.g. Apple Pro Display XDR, MacBook Pro with Liquid Retina XDR)

## Prerequisites

```bash
# Rust toolchain (required for gyroflow-core)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

## Build & Package

```bash
# Clone with submodules (gyroflow)
git clone --recurse-submodules https://github.com/chenpc/Spectrum.git
cd Spectrum

# Build Release
./release.sh
```

The DMG will be created in the project root directory.

To rebuild gyroflow-core manually:

```bash
cd gyro-wrapper && cargo build --release   # rebuild gyroflow-core
```

## Without building from source

If you skip the Rust toolchain, gyro stabilization will be unavailable. The app works without it — video playback uses AVFoundation + Metal natively.

## Architecture

```
Spectrum/
├── Models/           # SwiftData models (Photo, ScannedFolder)
├── Views/
│   ├── Sidebar/      # Folder tree navigation
│   ├── Grid/         # Photo grid with multi-select, marquee, keyboard nav
│   ├── Detail/       # HDR photo/video detail view (AVFoundation + Metal)
│   └── Import/       # Import panel for external folder browsing
├── Services/
│   ├── ImagePreloadCache.swift  # HDR format detection + rendering
│   ├── StatusBarModel.swift     # Unified async operation progress
│   ├── GyroCore.swift           # gyroflow-core runtime loader (one-shot API)
│   ├── GyroConfig.swift         # Gyro config + GyroCoreProvider protocol
│   ├── FolderScanner.swift      # Filesystem scanning (@ModelActor)
│   ├── ThumbnailService.swift   # Three-tier thumbnail cache
│   ├── XMPSidecarService.swift  # XMP sidecar read/write (edits + gyro config)
│   └── CGImageRotation.swift    # CGImage rotate + flip
├── ViewModels/       # Timeline section logic
└── Resources/        # App icon, bundled dylibs

gyro-wrapper/         # Rust cdylib wrapper for gyroflow-core
gyroflow/             # Git submodule — gyroflow
```
