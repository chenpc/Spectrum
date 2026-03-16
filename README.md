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
- **All HDR formats** — HLG, HDR10, Dolby Vision, S-Log2, S-Log3, SDR
- **HDR/SDR toggle** — Switch between HDR and SDR during playback
- **Hardware decoding** — VideoToolbox acceleration via AVFoundation + Metal two-pass rendering pipeline
- **Playback diagnostics** — On-screen badge showing render FPS, video FPS, frame consistency (CV), colorspace info, and gyro stability index

### Real-Time Gyro Stabilization (Gyroflow)

Preview gyro-stabilized video without rendering — powered by [gyroflow-core](https://github.com/gyroflow/gyroflow) as an in-process library. Sony cameras (ZV-E1, A7C II, A7 IV, FX30, etc.) embed IMU gyroscope/accelerometer data in every video file; Spectrum reads this data and applies real-time 3D perspective correction during playback.

- **Zero-export preview** — See stabilized footage instantly while browsing, no need to render first
- **Sony IBIS support** — Per-scanline in-body image stabilization data correction (tested with ZV-E1)
- **Per-video config** — Each video can have custom gyro settings (smoothing, sync offset, horizon lock, etc.), stored in XMP sidecar
- **Configurable parameters** — Smoothing (global or per-axis pitch/yaw/roll), gyro sync offset, lens profile, FOV scaling, horizon lock, adaptive zoom
- **GoPro support** — Automatic detection skips rolling shutter correction for GoPro footage (handled internally by GoPro ISP)
- **Toggle on/off** — Press `s` during playback to enable/disable stabilization in real time

### Browsing & Navigation

- **Folder-based browsing** — Scan existing folders directly, no import or copy
- **Timeline grid** — Photos grouped by date (Today, This Week, This Month, Older) with adaptive column layout
- **Multi-select** — Cmd+click to toggle, Shift+click for range select, marquee (rubber-band) selection
- **Keyboard navigation** — Arrow keys to move, Enter to open, Escape to go back, Delete to trash
- **Subfolder tiles** — Subfolders displayed as cover-image tiles, sorted by most recent photo
- **Sidebar** — Folder tree with breadcrumb navigation, context menu (rename, copy, cut, paste, show in Finder)
- **Drag & drop** — Add folders by dragging from Finder

### Import Panel

- **Import from folder** — Browse external folders (SD card, external drive) and drag date-grouped media into your library
- **Date grouping** — Files auto-grouped by EXIF date with expand/collapse all toggle
- **Copy or move** — Drag groups or individual files; right-click for copy/cut
- **Context menu import** — Right-click any subfolder in grid view to add it to the import panel
- **Async file I/O** — All copy/move operations run in background without blocking UI
- **Status bar** — Unified progress bar at bottom of grid showing scan, copy, paste, and import progress with completion messages

### Metadata & Inspector

- **EXIF inspector** — Toggle with `i` key: file info, camera/lens, exposure settings (aperture, shutter, ISO, focal length, exposure bias, metering, flash, white balance), GPS coordinates
- **HDR metadata** — Color profile, bit depth, headroom value, dynamic range indicator
- **Video metadata** — Duration, video codec, audio codec

### Non-Destructive Editing

- **Rotate** — 90° counter-clockwise rotation
- **Flip** — Horizontal mirror, composable with rotation (D4 group math)
- **Crop** — Visual crop overlay with rule-of-thirds grid, drag handles, pixel dimensions
- **XMP sidecar** — All edits stored in `{filename}.{ext}.xmp` (EXIF orientation 1–8 + Camera Raw crop), never modifies original files
- **Restore** — One-click reset to original

### Other

- **Fullscreen mode** — `f` key for distraction-free viewing (photos and videos)
- **Thumbnail caching** — Three-tier cache (memory + disk + on-demand), configurable size limit (100 MB – 2 GB), LRU eviction
- **Security-scoped bookmarks** — macOS Sandbox compatible with persistent folder access
- **File format support** — JPEG, HEIF/HEIC, PNG, TIFF, RAW (DNG, CR3, NEF, etc.), MP4, MOV, MKV

## Requirements

- macOS 14.0 (Sonoma) or later
- HDR display recommended (e.g. Apple Pro Display XDR, MacBook Pro with Liquid Retina XDR)
- Video playback uses AVFoundation + Metal (no external dependencies)

## Build

```bash
git clone --recurse-submodules https://github.com/chenpc/Spectrum.git
cd Spectrum
./release.sh
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for prerequisites, build options, and architecture details.

## License

[GPL-3.0](LICENSE)
