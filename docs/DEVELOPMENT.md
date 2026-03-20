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
│   ├── CGImageRotation.swift    # CGImage rotate + flip
│   └── Log.swift                # Unified logging (os.Logger categories + dynamic level)
├── ViewModels/       # Timeline section logic
└── Resources/        # App icon, bundled dylibs

gyro-wrapper/         # Rust cdylib wrapper for gyroflow-core
gyroflow/             # Git submodule — gyroflow
```

## Logging & Debugging

App 使用 `os.Logger`（subsystem: bundle ID）統一日誌，分 8 個 category（general, scanner, thumbnail, bookmark, video, gyro, player, network）。

### 在 Console.app 檢視

1. 開啟 Console.app → 選擇目標 Mac
2. 搜尋欄輸入 `Spectrum`（或 bundle ID）
3. 確認 Action → Include Info Messages / Include Debug Messages 已勾選

### 用 Terminal 即時串流

```bash
# 所有 Spectrum log
log stream --predicate 'subsystem == "com.chenpc.Spectrum"' --level debug

# 只看特定 category（例如 scanner）
log stream --predicate 'subsystem == "com.chenpc.Spectrum" AND category == "scanner"' --level debug

# 只看 error 以上
log stream --predicate 'subsystem == "com.chenpc.Spectrum"' --level error
```

### Log Level 設定

在 Settings → General → Developer section 可即時切換 Log Level：

- **Debug**（預設於 Debug build）：輸出所有 debug/info/error
- **Info**（預設於 Release build）：輸出 info/error
- **Error**：只輸出 error

對應 UserDefaults key `appLogLevel`（Int: 0=debug, 1=info, 2=error）。也可用指令設定：

```bash
defaults write com.chenpc.Spectrum appLogLevel -int 0   # debug
defaults write com.chenpc.Spectrum appLogLevel -int 2   # error only
```
