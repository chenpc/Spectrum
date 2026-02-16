# Spectrum

A native macOS photo viewer built for **HDR photography** — specifically designed to correctly render Sony HLG (Hybrid Log-Gamma) HDR photos and videos that macOS Photos cannot properly display.

## Why Spectrum?

Apple's Photos app does not correctly tone-map Sony's HLG HDR images, resulting in washed-out or incorrectly exposed photos. Spectrum solves this by implementing a dedicated HDR rendering pipeline that properly handles:

- **HLG (Hybrid Log-Gamma)** — Sony's HDR format, with CIToneMapHeadroom and BT.2020 → Display P3 gamut mapping
- **Apple Gain Map HDR** — iPhone HDR photos with auxiliary gain map data
- **EDR (Extended Dynamic Range)** — leverages your display's full HDR headroom

## Features

- **HDR Rendering Pipeline** — Protocol-based architecture with per-format render specs (HLG, Gain Map)
- **HDR/SDR Toggle** — Instantly switch between HDR and SDR rendering to compare
- **Folder-Based Browsing** — Scan existing folders directly, no import or copy needed
- **Timeline Grid View** — Photos organized by month with keyboard arrow-key navigation
- **Subfolder Navigation** — Expandable folder tree in sidebar with lazy loading
- **Video Playback** — HDR video support with AVPlayer and HDR/SDR composition switching
- **Fullscreen Mode** — Distraction-free viewing with Cmd+F
- **EXIF Inspector** — View photo metadata, camera settings, and HDR info
- **Thumbnail Caching** — HEIC-based disk cache with configurable size limits
- **Drag & Drop** — Add folders by dragging from Finder
- **Security-Scoped Bookmarks** — Sandboxed app with persistent folder access

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ (for building from source)
- HDR display recommended (e.g. Apple Pro Display XDR, MacBook Pro with Liquid Retina XDR)

## Build

```bash
# Clone
git clone https://github.com/chenpc/Spectrum.git
cd Spectrum

# Build Release
./release.sh
```

The DMG will be created in the project root directory.

## Architecture

```
Spectrum/
├── Models/          # SwiftData models (Photo, ScannedFolder, Tag)
├── Views/
│   ├── Sidebar/     # Folder tree navigation
│   ├── Grid/        # Timeline photo grid with keyboard nav
│   └── Detail/      # HDR photo/video detail view
├── Services/
│   ├── HDRRenderSpec.swift    # HDR protocol + shared pipeline
│   ├── HLGHDRSpec.swift       # Sony HLG rendering
│   ├── GainMapHDRSpec.swift   # Apple Gain Map rendering
│   ├── FolderScanner.swift    # Filesystem scanning
│   ├── ThumbnailService.swift # Cached thumbnail generation
│   └── BookmarkService.swift  # Security-scoped bookmarks
├── ViewModels/      # Timeline section logic
├── Extensions/      # Date formatting, URL helpers
└── Resources/       # App icon SVG source
```

## License

MIT
