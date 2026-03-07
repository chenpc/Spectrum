# Spectrum — 完整設計文件

> **目的**：供 Rust + Tauri 改寫時參考。涵蓋每個檔案的精確行為、資料模型、服務 API、視圖結構、鍵盤快捷鍵、平台整合細節。

---

## 目錄

1. [專案概覽](#1-專案概覽)
2. [檔案清單與職責](#2-檔案清單與職責)
3. [資料模型](#3-資料模型)
4. [服務層](#4-服務層)
5. [ViewModel 與可觀測狀態](#5-viewmodel-與可觀測狀態)
6. [視圖層次結構](#6-視圖層次結構)
7. [HDR 影像處理](#7-hdr-影像處理)
8. [影片播放架構](#8-影片播放架構)
9. [匯入面板](#9-匯入面板)
10. [Gyroflow 陀螺儀穩定](#10-gyroflow-陀螺儀穩定)
11. [鍵盤快捷鍵與選單命令](#11-鍵盤快捷鍵與選單命令)
12. [安全作用域書籤（Sandbox）](#12-安全作用域書籤sandbox)
13. [設定系統](#13-設定系統)
14. [網路磁碟支援](#14-網路磁碟支援)
15. [資料夾剪貼簿](#15-資料夾剪貼簿)
16. [Entitlements 與沙盒](#16-entitlements-與沙盒)
17. [關鍵設計模式](#17-關鍵設計模式)
18. [Tauri 改寫注意事項](#18-tauri-改寫注意事項)

---

## 1. 專案概覽

**Spectrum** 是一款 **macOS 原生相簿瀏覽器**（非匯入制）。核心理念：

- **掃描既有資料夾**，不複製/搬移檔案
- **無「全部照片」視圖**；側邊欄直接列出資料夾
- **時間軸網格**：照片按月份分組、降序排列
- **子資料夾瓷磚**：在網格中顯示為可導航的封面磁貼
- **影片播放**：AVFoundation + Metal 兩段式渲染管線（YCbCr→RGB → warp stabilization）
- **HDR**：圖片（Gain Map、HLG）與影片（HLG、HDR10、Dolby Vision）
- **Gyroflow 穩定**：即時透過 gyroflow-core 矩陣套用於 Metal warp shader
- **資料夾管理**：複製/剪下/貼上/重新命名子資料夾，多選（Cmd/Shift/圈選）
- **匯入面板**：從外部資料夾瀏覽/拖放媒體到庫中
- **網路磁碟**：SMB 自動重新掛載

**技術堆疊**：Swift 6 + SwiftUI + SwiftData + AVFoundation + Metal

**視窗結構**：單一 `WindowGroup`，`NavigationSplitView`（側邊欄 + 內容），加上 `Settings` 視窗。

---

## 2. 檔案清單與職責

### App 進入點
| 檔案 | 職責 |
|------|------|
| `SpectrumApp.swift` | `@main`；WindowGroup + Settings；定義選單命令（File、Edit、Navigate、Delete、Playback） |

### 模型
| 檔案 | 職責 |
|------|------|
| `Models/Photo.swift` | `@Model` SwiftData — 照片/影片記錄（EXIF、影片、Gyro） |
| `Models/ScannedFolder.swift` | `@Model` SwiftData — 已掃描資料夾（書籤、SMB URL） |

### 服務
| 檔案 | 職責 |
|------|------|
| `Services/ThumbnailService.swift` | Actor：生成/快取縮圖（記憶體 NSCache + 磁碟 HEIC），LRU 逐出 |
| `Services/BookmarkService.swift` | 靜態：安全作用域書籤的建立/解析/包裝 |
| `Services/FolderScanner.swift` | `@ModelActor`：掃描資料夾、EXIF/影片元資料讀取、批次 insert、delta 移除 |
| `Services/EXIFService.swift` | 靜態：CGImageSource EXIF 解析（TIFF、Exif、GPS、ExifAux、Headroom） |
| `Services/ImagePreloadCache.swift` | 靜態 async：HDR 圖片/影片載入，VideoHDRType 偵測 |
| `Services/VideoMetadataService.swift` | 靜態 async：AVAsset 元資料（duration、codec、GPS） |
| `Services/GyroCore.swift` | `final class`：dlopen libgyrocore_c.dylib，FFI 矩陣計算 |
| `Services/StatusBarModel.swift` | `@Observable` 單例：統一 async 操作進度（掃描、複製、匯入） |
| `Services/NetworkVolumeService.swift` | 靜態：網路卷偵測、自動掛載、輪詢等待 |
| `Services/FolderClipboard.swift` | `@Observable` 單例：資料夾剪貼簿（複製/剪下/貼上） |
| `Services/FolderListCache.swift` | 單例：子資料夾清單持久快取（JSON） |

### ViewModel
| 檔案 | 職責 |
|------|------|
| `ViewModels/LibraryViewModel.swift` | 照片時間軸分組、flatPhotos、方向鍵導航 |

### 視圖 — 主要
| 檔案 | 職責 |
|------|------|
| `Views/ContentView.swift` | 根 NavigationSplitView + Inspector；Escape 鍵監控；全螢幕管理 |
| `Views/SettingsView.swift` | TabView（Cache / Playback / Gyro）設定 |

### 視圖 — 側邊欄
| 檔案 | 職責 |
|------|------|
| `Views/Sidebar/SidebarView.swift` | 資料夾列表 + DisclosureGroup 遞迴子資料夾 + 拖放加入 |
| `Views/Sidebar/CacheSidebarFooter.swift` | 縮圖快取用量與清除 UI |

### 視圖 — 網格
| 檔案 | 職責 |
|------|------|
| `Views/Grid/PhotoGridView.swift` | LazyVGrid 主網格；子資料夾/照片；多選/圈選；剪貼簿；狀態列 |
| `Views/Grid/PhotoThumbnailView.swift` | 單張照片磁貼（HDR 縮圖 + 影片徽章） |
| `Views/Grid/TimelineSectionHeader.swift` | 時間軸月份 sticky header |

### 視圖 — 匯入
| 檔案 | 職責 |
|------|------|
| `Views/Import/ImportPanelView.swift` | 匯入面板：掃描外部資料夾、日期分組、拖放/複製/剪下 |

### 視圖 — 詳情
| 檔案 | 職責 |
|------|------|
| `Views/Detail/PhotoDetailView.swift` | 圖片/影片查看器；HDR 切換；Gyro 整合 |
| `Views/Detail/HDRImageViews.swift` | HDRImageView、HLGImageView、HDRVideoPlayerView |
| `Views/Detail/AVFMetalView.swift` | AVFoundation + Metal 渲染引擎（YCbCr→RGB → warp）；CVDisplayLink |
| `Views/Detail/MetalShaders.swift` | Metal shader 源碼（YCbCr→RGB、warp 畸變模型） |
| `Views/Detail/VideoPlayerNSView.swift` | NSView 包裝 AVFMetalView；SwiftUI bridge |
| `Views/Detail/VideoController.swift` | `@Observable` 影片播放狀態；Gyro 生命週期 |
| `Views/Detail/VideoControlBar.swift` | 浮動影片控制列 |
| `Views/Detail/PhotoInfoPanel.swift` | Inspector：EXIF/影片資訊 + 每影片 Gyro 設定 |

### 擴充
| 檔案 | 職責 |
|------|------|
| `Extensions/Date+Formatting.swift` | timelineLabel、monthYearKey、shortDate、formatDuration() |
| `Extensions/URL+ImageTypes.swift` | isImageFile、isVideoFile、isCameraRawFile、isMediaFile |

### 其他
| 檔案 | 職責 |
|------|------|
| `ThumbnailCacheState.swift` | `@Observable` generation 計數器 + EnvironmentKey |

---

## 3. 資料模型

### Photo（SwiftData @Model）

```
@Attribute(.unique) filePath: String     ← 主鍵（檔案絕對路徑）
fileName: String
dateTaken: Date                          ← EXIF DateTimeOriginal 或檔案修改時間
dateAdded: Date                          ← 加入 DB 時間
fileSize: Int64
pixelWidth: Int
pixelHeight: Int

// EXIF 基本
cameraMake, cameraModel, lensModel: String?
focalLength, aperture: Double?
shutterSpeed: String?                    ← 格式化後（"1/125s"）
iso: Int?
latitude, longitude: Double?

// EXIF 擴充
exposureBias: Double?
exposureProgram, meteringMode, flash, whiteBalance: Int?
brightnessValue: Double?
focalLenIn35mm, sceneCaptureType, lightSource: Int?
digitalZoomRatio: Double?
contrast, saturation, sharpness: Int?
lensSpecification: [Double]?             ← 4 元素 [minFL, maxFL, minAp, maxAp]
offsetTimeOriginal, subsecTimeOriginal, exifVersion: String?

// 頂級中繼資料
headroom: Double?                        ← Sony HLG 頂級 or MakerApple[33]
profileName: String?
colorDepth, orientation: Int?
dpiWidth, dpiHeight: Double?
software: String?                        ← TIFF.Software
imageStabilization: Int?                 ← ExifAux

// 影片欄位
isVideo: Bool = false
duration: Double?
videoCodec, audioCodec: String?

// 每影片 Gyro 覆蓋
gyroConfigJson: String?                  ← JSON(GyroConfig)；nil = 全域設定

// 關係
folder: ScannedFolder?                   ← 反向多對一
```

**重要方法**：
```swift
func resolveBookmarkData(from folders: [ScannedFolder]) -> Data?
  // 1. folder?.bookmarkData（Swift Data 關係）
  // 2. fallback: folders.first { filePath.hasPrefix($0.path) }?.bookmarkData
  // 因為 SwiftData 延遲載入，folder 可能為 nil
```

### ScannedFolder（SwiftData @Model）

```
path: String
bookmarkData: Data?                      ← 安全作用域書籤
remountURL: String?                      ← "smb://server/share"
dateAdded: Date
sortOrder: Int = 0
@Relationship(deleteRule: .cascade) photos: [Photo] = []
```

### TimelineSection（結構體，非持久化）

```
id: String      ← "yyyy-MM-dd"（用於排序與去重）
label: String   ← "2024/01/15"（顯示用）
photos: [Photo] ← dateTaken 降序
```

### 其他資料結構

**EXIFData**：`EXIFService.readEXIF()` 的返回值，與 Photo 欄位一一對應。

**VideoMetadata**：`VideoMetadataService.readMetadata()` 返回值——duration、pixelWidth/Height、videoCodec、audioCodec、creationDate、latitude、longitude。

**SubfolderInfo**：`{ name, path, coverPath?, coverDate? }`——網格中子資料夾磁貼的資料。

**ClipboardFolder**：`{ sourcePath, bookmarkData, isCut, name }`——剪貼簿項目。

**FolderListEntry**：`{ name, path, coverPath?, coverDate? }` Codable——持久化子資料夾快取項。

**GyroConfig**：Codable 結構體，19 個可調參數（readoutMs、smooth、gyroOffsetMs、integrationMethod、imuOrientation、fov、lensCorrectionAmount、zoomingMethod、adaptiveZoom、maxZoom、maxZoomIterations、useGravityVectors、videoSpeed、horizonLockAmount、horizonLockRoll、perAxis、smoothnessPitch/Yaw/Roll）。JSON CodingKeys 使用 snake_case。

---

## 4. 服務層

### 4.1 ThumbnailService（Actor 單例）

**快取目錄**：`~/Library/Caches/Spectrum/Thumbnails/`

**雙層快取**：
- 記憶體：`NSCache<NSString, NSImage>`（500 項上限）
- 磁碟：`SHA256(filePath + "_" + mtime).heic`

**大小限制**：`@AppStorage("thumbnailCacheLimitMB")` 預設 500 MB，0 = 無限。

**API**：
```
cachedThumbnail(for: filePath) → NSImage?     // nonisolated，僅記憶體快取
thumbnail(for: filePath, bookmarkData:) async → NSImage?
  1. 記憶體快取命中 → 返回
  2. 磁碟快取命中 → 載入、存記憶體、返回
  3. 解析書籤 → 啟動作用域 → 生成 → 停止作用域 → 寫磁碟 → 存記憶體 → 逐出檢查

clearCache()
diskCacheSize() async → Int64
```

**生成策略**：
- **一般圖片**：`CGImageSourceCreateThumbnailAtIndex`（300px）+ Alpha 移除（避免 "AlphaPremulLast" 警告）
- **SVG**：`NSImage` → `CGContext` 重繪為 300px
- **影片**：`AVAssetImageGenerator.image(at: .zero)`
- **Camera RAW**：嘗試第二個子影像（>1000px），fallback 到 CreateThumbnail
- 磁碟格式：HEIC（`CGImageDestination`）

**LRU 逐出**：
- `evictIfNeeded()` 在每次新增後呼叫
- background Task：列舉磁碟、按 `contentAccessDate` 排序、刪除最舊直到低於限制

### 4.2 BookmarkService（靜態）

```
createBookmark(for: URL) → Data           // .withSecurityScope
resolveBookmark(Data) → URL               // 偵測 stale、嘗試刷新
remountURL(for: URL) → URL?               // volumeURLForRemounting
withSecurityScope<T>(URL, body:) → T      // 同步版：start → body → stop
withSecurityScope<T>(URL, body:) async → T // 非同步版
```

### 4.3 FolderScanner（@ModelActor）

接受 **`PersistentIdentifier`**（非模型物件），以符合 `@ModelActor` 隔離。

```
scanFolder(id:, subPath:, clearAll:)
  1. 取得 ScannedFolder → 解析書籤 → 啟動作用域
  2. FM.contentsOfDirectory（一層、非遞迴）
  3. 過濾 isMediaFile + 不在 DB 中
  4. 對每個檔案：
     - 影片 → VideoMetadataService.readMetadata()
     - 圖片 → EXIFService.readEXIF()
  5. Photo insert（批次 100 筆 → save → 觸發 @Query）
  6. Delta 移除：DB 中有但磁碟上消失的同層 Photo

listSubfolders(id:, path:) → [(name, path, coverPath?, coverDate?)]
  1. 解析書籤 → withSecurityScope
  2. 列舉子目錄
  3. 每個子目錄：
     - FolderListCache 命中 → 直接返回
     - 否則：讀內部檔案找封面 → EXIF 取日期 → fallback mtime
  4. 更新 FolderListCache
```

### 4.4 EXIFService（靜態）

```
readEXIF(from: URL) → EXIFData
  使用 CGImageSourceCopyPropertiesAtIndex：
  - {TIFF}: cameraMake, cameraModel, software
  - {Exif}: 全部曝光參數、鏡頭、ISO、日期（支援 OffsetTimeOriginal 時區）
  - {GPS}: lat/lon（含 N/S E/W 正負號）
  - {ExifAux}: imageStabilization
  - 頂級: pixelWidth/Height, colorDepth, orientation, DPI, profileName
  - Headroom: 頂級 "Headroom" 或 {MakerApple}["33"]
```

### 4.5 ImagePreloadCache（靜態 enum）

```
loadVideoEntry(path:, bookmarkData:) async → CachedVideoEntry?
  1. 解析書籤 → 作用域
  2. AVURLAsset → loadTracks(.video)
  3. HDR 偵測：
     - kCMVideoCodecType_DolbyVisionHEVC → .dolbyVision
     - SampleDescriptionExtensionAtoms["dvcC"/"dvvC"] → .dolbyVision
     - TransferFunction == HLG → .hlg
     - TransferFunction == PQ → .hdr10
  4. 若 HDR：構建 AVVideoComposition（HDR 版 + SDR 版）
  5. 建立 AVPlayer → 返回 CachedVideoEntry

detectVideoHDRType(path:, bookmarkData:) async → VideoHDRType?
  ← 輕量版，僅偵測 HDR 類型，不建立 AVPlayer

loadImageEntry(path:, bookmarkData:) async → CachedImageEntry
  1. 作用域 + CGImageSource
  2. detectHDR()：
     - AuxiliaryData(HDRGainMap) → .gainMap
     - EXIF CustomRendered==3 → .gainMap（舊 iPhone）
     - CGColorSpaceUsesITUR_2100TF → .hlg
  3. Camera RAW → 多 frame 或 thumbnail
  4. HLG → 保存原始 CGImage（用於 CALayer 直接渲染）

enum VideoHDRType: String, CaseIterable {
  dolbyVision, hlg, hdr10, slog2, slog3
  var playerStorageKey: String  // "playerForXxx"
  static let sdrPlayerStorageKey = "playerForSDR"
}

enum HDRFormat { gainMap, hlg }
struct CachedImageEntry { image, hlgCGImage?, hdrFormat? }
struct CachedVideoEntry { player, hdrType?, hdrComposition?, sdrComposition? }
```

### 4.6 VideoMetadataService（靜態）

```
readMetadata(from: URL) async → VideoMetadata
  - AVAsset.load(.duration, .creationDate)
  - Video track: naturalSize (applying preferredTransform), formatDescriptions → fourCC
  - Audio track: formatDescriptions → fourCC
  - GPS: metadata common key .commonKeyLocation → "+lat+lon" 字串解析
```

### 4.7 GyroCore（final class, @unchecked Sendable）

**dylib 搜尋**：
1. `Bundle.main.resourcePath/lib/libgyrocore_c.dylib`
2. `gyro-wrapper/target/release/libgyrocore_c.dylib`（本 repo）
3. `~/gyroflow/target/release/libgyrocore_c.dylib`

**C FFI 函式**：
```c
void* gyrocore_load(const char* video_path, const char* lens_path, const char* config_json);
int   gyrocore_get_params(void* handle, void* out_buf);  // 40 bytes
int   gyrocore_get_frame(void* handle, uint32_t frame_idx, float* out_buf);
void  gyrocore_free(void* handle);
```

**params 佈局（40 bytes）**：
```
offset 0:  uint32 frame_count
offset 4:  uint32 row_count
offset 8:  uint32 video_width
offset 12: uint32 video_height
offset 16: float64 fps
offset 24: float32 fx (focal_x)
offset 28: float32 fy (focal_y)
offset 32: float32 cx (principal_x)
offset 36: float32 cy (principal_y)
```

**get_frame 輸出**：`row_count × 14 floats`，每行 = `[mat3×3(9), sx, sy, ra(IBIS), ox, oy(OIS)]`

**computeMatrix 展開**：`rawBuf[rowCount×14]` → `matsBuf[videoHeight×16]`（RGBA32F texture, width=4）
- 每行 4 texels：`[col0(3)+sx, col1(3)+sy, col2(3)+ra, ox, oy, 0, 0]`
- 使用逐行插值：`row = y * rowCount / videoHeight`

**生命週期**：
```
start(videoPath, lensPath, config, onReady, onError)
  → ioQueue（背景）: dlopen + gyrocore_load（~0.3s）→ get_params → 預配置 buffer
  → main queue: onReady()

computeMatrix(frameIdx) → (UnsafeBufferPointer<Float>, changed: Bool)?
  → coreLock 保護；快取命中返回 (buf, false)

stop()
  → readyLock: _isReady = false
  → ioQueue.sync {} 等待載入完成
  → coreLock: gyrocore_free + dlclose
```

### 4.8 NetworkVolumeService（靜態）

```
volumeRoot(for: path) → String?       // "/Volumes/MyNAS"
isVolumeMounted(path:) → Bool
ensureMounted(folder:) async → Bool   // @MainActor
  1. 若已掛載 → true
  2. 若有 remountURL → NSWorkspace.open(smb://...)
  3. 否則 → NSWorkspace.open(/Volumes/name)
  4. 輪詢 15s（30 × 0.5s）等待出現
```

### 4.9 FolderClipboard（@Observable @MainActor 單例）

```
content: ClipboardFolder?
hasContent: Bool
copy(path:, bookmarkData:)
cut(path:, bookmarkData:)
clear()
```

### 4.10 FolderListCache（單例，NSLock 線程安全）

```
memory: [String: [FolderListEntry]]
entries(for: parentPath) → [FolderListEntry]?
entry(forChildPath:, underParent:) → FolderListEntry?
setEntries(_:, for:)
invalidate(parentPath:)
clear()
persistAsync()  // DispatchQueue.global → JSON 寫入磁碟
```

**檔案位置**：`~/Library/Caches/Spectrum/FolderList.json`

---

## 5. ViewModel 與可觀測狀態

### 5.1 LibraryViewModel（@Observable）

```swift
flatPhotos: [Photo] = []

timelineSections(from: [Photo]) → [TimelineSection]
  1. Dictionary(grouping: by: monthYearKey)
  2. 每組按 dateTaken 降序
  3. 組按 id 降序（最新優先）
  4. 填充 flatPhotos = sections.flatMap(\.photos)

navigatePhoto(from: Photo?, direction: Int) → Photo?
  在 flatPhotos 中找 index → 加 direction → 邊界 clamp
```

### 5.2 VideoController（@Observable, @unchecked Sendable）

**狀態屬性**（主執行緒可觀測）：
```
isPlaying, currentTime, duration: Double
renderFPS, renderCV, renderStability, videoFPS: Double
gyroComputeMs: Double
gyroStabEnabled, gyroAvailable: Bool
diagnosticsEnabled: Bool
layerColorspaceInfo, decodeColorspaceInfo: String
```

**方法**：
```
reset()
togglePlayPause()                          // 含 EOF 重播、deferredPlay（等 Gyro）
seek(to: seconds)
startGyroStab(videoPath:, fps:, config:, lensPath:)
stopGyroStab()
```

**渲染架構**：
- AVFoundation + Metal 兩段式管線（AVFMetalView）
- Pass 1: YCbCr (Y + CbCr planes) → RGBA16Float offscreen texture
- Pass 2: Warp shader（gyro matTex + 畸變模型）→ CAMetalLayer drawable
- CVDisplayLink 驅動 renderFrame()
- `copyPixelBuffer(forItemTime:itemTimeForDisplay:)` 提供精確 PTS → gyro 對齊

### 5.3 ThumbnailCacheState（@Observable @MainActor 單例）

```
generation: Int
invalidate() → generation += 1
// 注入為 EnvironmentValue：\.thumbnailCacheState
// PhotoThumbnailView.task(id: filePath + generation) → generation 變化時重新載入
```

---

## 6. 視圖層次結構

```
SpectrumApp (@main)
├── WindowGroup
│   └── ContentView
│       ├── NavigationSplitView(columnVisibility)
│       │   ├── sidebar: SidebarView
│       │   │   ├── List(Folders)
│       │   │   │   ├── ForEach(sortedFolders)
│       │   │   │   │   ├── folderLabel（tag: .folder）
│       │   │   │   │   └── DisclosureGroup → SubfolderSidebarRow（遞迴）
│       │   │   │   │       └── DisclosureGroup → 子的子...
│       │   │   │   └── Section footer（已移除）
│       │   │   └── .onDrop(fileURL) → addFolderURL
│       │   └── detail:
│       │       ├── 有 detailPhoto →
│       │       │   PhotoDetailView(photo, showInspector, isHDR, viewModel)
│       │       │   ├── imageContent（圖片路徑）
│       │       │   │   ├── ScrollView { HLGImageView 或 HDRImageView }
│       │       │   │   └── HDR Badge（點擊切換）
│       │       │   └── videoContent（影片路徑）
│       │       │       └── VideoPlayerNSView(AVFMetalView) + VideoControlBar + diagBadge
│       │       ├── 有 subfolder 選擇 → PhotoGridView + Back 按鈕
│       │       └── 有 folder 選擇 → PhotoGridView
│       ├── .inspector { PhotoInfoPanel }
│       └── ImportPanelView（右側匯入面板，可開關）
│
└── Settings
    └── SettingsView
        ├── Tab: CacheSettingsTab
        ├── Tab: PlaybackSettingsTab
        └── Tab: GyroSettingsTab
```

### 6.1 ContentView 行為

- **selectedSidebarItem**: `SidebarItem`（.folder / .subfolder(folder, subPath)）
- **selectedPhoto**: 網格中的單選高亮
- **detailPhoto**: 進入詳情視圖的照片（雙擊或 Enter）
- **columnVisibility**: 全螢幕時自動收合側邊欄
- **EscapeKeyMonitor**:
  - 全螢幕 → 退出全螢幕
  - 詳情 → 返回網格
  - 子資料夾 → 返回上層
- **啟動掃描**: `.task` 對所有資料夾做 delta scan
- **全螢幕**: toolbar 隱藏/顯示、側邊欄自動收合/恢復

### 6.2 SidebarView 行為

- **sortedFolders**: 按最新 Photo.dateTaken 排序（最新優先），無照片時按路徑字母序
- **folderChildren**: `[folderPath: [(name, path, ...)]]`
- **啟動載入**: `loadAllFolderChildren()` — 先顯示快取、再 async 刷新
- **新增資料夾**: NSOpenPanel（可多選） → BookmarkService.createBookmark → insert
- **拖放**: `onDrop(of: .fileURL)` → 偵測目錄 → addFolderURL
- **右鍵**: Rescan（clearAll）、Show in Finder、Remove

### 6.3 PhotoGridView 行為

- **columns**: `GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 2)`
- **subfolders**: scannedSubfolders ?? inferredSubfolders（推斷 = 從 DB 路徑推導，無 I/O）
- **directPhotos**: 同層照片（filePath 以 effectivePath 為前綴、無更深斜線）
- **pendingPaths**: 磁碟上存在但尚未入 DB 的檔案（顯示 PlaceholderTileView）
- **scanCurrentLevel()**:
  1. 網路掛載檢查
  2. 快取子資料夾 → 刷新子資料夾
  3. 快速列舉磁碟 → pendingPaths
  4. Delta scan → pendingPaths 清空
- **導航**: buildFlatItems → navigate(by: offset) → Arrow 鍵
- **activateSelection**: 子資料夾 → onNavigateToSubfolder；照片 → onDoubleClick
- **多選**: Cmd+click toggle、Shift+click range、marquee（MarqueeNSView + NSView overlay）
- **排序**: subfoldersAreInOrder — 最新 coverDate 優先，相同日期時字母序
- **剪貼簿 UI**: context menu Copy/Cut/Paste + Cmd+C/X/V
- **匯入**: context menu "Add to Import" → 開啟匯入面板
- **重命名**: alert TextField → FileManager.moveItem
- **狀態列**: StatusBarModel 統一顯示掃描/複製/貼上/匯入進度
- **刪除**: Delete/Forward Delete 鍵，支援多選批量刪除

### 6.4 PhotoDetailView 行為

**圖片**：
- GeometryReader + ScrollView → 可縮放
- zoomLevel 控制（toolbar 按鈕）
- HLG: HLGImageView（CALayer + itur_2100_HLG）
- Gain Map/SDR: HDRImageView（NSImageView.preferredImageDynamicRange）

**影片**：
- `loadVideo()` → reset 所有狀態 → `startPlayback()`
- `startPlayback()`:
  1. `detectVideoHDRType()` 偵測 HDR 類型
  2. AVFMetalView 載入影片，Metal 兩段式渲染
  3. HDR colorspace 自動管理（HLG/PQ/sRGB/Display P3）
  4. DV P8.4 自動切換 HLG→PQ decode mode
- **HDR 切換**: showHDR toggle → Metal layer colorspace + decode mode
- **控制列**: 浮動可拖動，3 秒自動隱藏，滑鼠移動重設
- **鍵盤**: Space、F、S、I（見第 12 節）

---

## 7. HDR 影像處理

### 圖片 HDR 偵測

```
1. CGImageSourceCopyAuxiliaryDataInfoAtIndex(kCGImageAuxiliaryDataTypeHDRGainMap)
   → HDRFormat.gainMap

2. EXIF CustomRendered == 3（舊 iPhone Gain Map）
   → HDRFormat.gainMap

3. CGColorSpaceUsesITUR_2100TF(cgImage.colorSpace)
   → HDRFormat.hlg
```

### 圖片 HDR 渲染

**Gain Map / SDR Toggle**：
```
HDRImageView（NSViewRepresentable → FlexibleImageView : NSImageView）
  .preferredImageDynamicRange = showHDR ? .high : .standard
  // 系統自動處理 Gain Map tone mapping
```

**HLG（直接渲染）**：
```
HLGImageView（NSViewRepresentable → HLGNSView : NSView）
  layer.contents = cgImage（原始 CGImage，不經 NSImage）
  enableEDR():
    遍歷整個 layer tree：
      macOS 26+: preferredDynamicRange = .high
      舊版: wantsExtendedDynamicRangeContent = true
```

### 影片 HDR

**AVVideoComposition 方式（AVPlayer）**：
```
HDR 版: colorPrimaries=2020, transfer=HLG_or_PQ, YCbCr=2020
SDR 版: colorPrimaries=709, transfer=709, YCbCr=709
playerItem.videoComposition = showHDR ? hdrComp : sdrComp
```

**HDRVideoPlayerView**：
```
EDRPlayerView : AVPlayerView
  controlsStyle = .none（自訂控制列）
  enableEDR() 同 HLGNSView
```

---

## 8. 影片播放架構

### AVFoundation + Metal 管線

所有影片統一使用 AVFoundation 解碼 + Metal 渲染：

**流程**：
1. `detectVideoHDRType()` → 輕量偵測（~50ms）
2. AVFMetalView 載入影片（AVPlayer + AVPlayerItemVideoOutput）
3. CVDisplayLink 驅動 `renderFrame()`
4. 兩段式 Metal 管線：
   - Pass 1: YCbCr (Y + CbCr planes) → RGBA16Float offscreen texture
   - Pass 2: Warp shader（gyro matTex + 畸變模型）→ CAMetalLayer drawable
5. `copyPixelBuffer(forItemTime:itemTimeForDisplay:)` 提供精確 PTS → gyro 對齊

### HDR Colorspace 管理

```
HLG:   layer.colorspace = itur_2100_HLG
PQ:    layer.colorspace = itur_2100_PQ
SDR:   layer.colorspace = sRGB 或 displayP3
DV P8.4: 自動切換 HLG→PQ decode mode + PQ layer
```

### Decode Modes（14 種）

Metal fragment shader 支援 BT.601/709/2020 × video/full range + PQ↔HLG 轉換。自動偵測影片的 color primaries 和 transfer function 選擇正確的 decode mode。

### 診斷 Badge（右上角）

- HDR/SDR 切換 pill + GYRO 切換 pill
- Decode colorspace info
- renderFPS / videoFPS + CV dot（green/yellow/red）
- gyro compute time + stability index

**CV 門檻**：green < 0.05、yellow < 0.15、red ≥ 0.15

### Gyro Warp Shader（Metal）

```
renderFrame():
  1. 若 gyroCore != nil:
     pts = itemTimeForDisplay
     (matBuf, changed) = gyroCore.computeMatrixAtTime(pts)
     若 changed: upload matTex (MTLTexture, RGBA32F, width=4, height=vH)
  2. Pass 1: YCbCr → RGB（offscreen texture）
  3. Pass 2: Warp shader + matTex → drawable

Warp Shader (Metal):
  5 種畸變模型（None/OpenCVFisheye/Poly3/Poly5/Sony）
  從 matTex 讀取該行的 mat3×3 + IBIS(sx,sy,ra) + OIS(ox,oy)
  套用反畸變 → 矩陣變換 → 畸變 → 紋理取樣
```

### VideoPlayerNSView（NSView wrapper）

```
load(path:):
  解析書籤 → 啟動作用域
  prepareForContent(hdrType:) → 設定 Metal layer colorspace
  AVFMetalView.load(path:) → AVPlayer 載入 + 開始渲染

setPause(Bool), seek(to:)
loadGyroCore(GyroCoreProvider?)
```

### VideoControlBar

浮動可拖動控制列，3 秒自動隱藏，滑鼠移動重設。

---

## 9. 匯入面板

### ImportPanelModel（@Observable @MainActor 單例）

```
sourceURL: URL?              // 目前選擇的來源資料夾
items: [ImportItem]          // 掃描到的媒體檔案
isScanning: Bool
expandAll: Bool              // 全部展開/縮合控制
expandCollapseToken: Int     // 觸發 onChange 同步

selectFolder()               // NSOpenPanel 選擇資料夾
openFolder(url:)             // 直接開啟（從 grid view context menu）
scanFolder(url:) async       // 背景掃描媒體（Task.detached）
removeItems(Set<URL>)        // 移除已搬移的項目
close()                      // 釋放作用域
```

### ImportPanelView

- **日期分組**: 按 EXIF 日期分組（`ImportDateGroup`），最新優先
- **展開/縮合**: 預設全部展開，header 按鈕切換全部展開/縮合
- **雙擊展開**: 群組 header 雙擊展開/縮合
- **拖放**: 整組或單檔可拖放到 grid view
- **Context menu**: Copy / Cut

### 從 Grid View 觸發

- 子資料夾右鍵 → "Add to Import" → `importModel.openFolder(url:)`
- ContentView 監聽 `importModel.sourceURL` 變化 → 自動開啟 import panel

---

## 10. Gyroflow 陀螺儀穩定

### 啟動流程

```
PhotoDetailView.startPlayback()
  → VideoController.startGyroStab(videoPath, fps, config, lensPath)
    → GyroCore().start(...)
      → ioQueue（背景）: dylib 載入 + gyrocore_load（~0.3s）
      → onReady（main queue）:
        videoController.gyroStabEnabled = true
        nsView.loadGyroCore(core)  // 清除 waitingForGyro
        若 deferredPlay → nsView.setPause(false)
```

### 每幀矩陣計算

```
AVFMetalView.renderFrame():
  pts = itemTimeForDisplay（精確 PTS）
  (matBuf, changed) = gyroCore.computeMatrixAtTime(pts)
  若 changed:
    upload matTex (MTLTexture, RGBA32F, width=4, height=videoHeight)
  執行 Metal warp shader
```

### 每影片設定覆蓋

```
PhotoInfoPanel → GyroConfigSection
  Toggle "Custom Gyro Config"
  ON → photo.gyroConfigJson = JSON(config)
  OFF → photo.gyroConfigJson = nil（使用全域）
  Apply → 寫入 DB → onChange 觸發 stop+start
```

### readoutMs 自動估算

```
fps >= 100 → 8ms
fps >= 50  → 15ms
其他       → 20ms
```

---

## 11. 鍵盤快捷鍵與選單命令

### 選單命令（全域）

| 選單 | 項目 | 快捷鍵 | FocusedValue |
|------|------|--------|--------------|
| File | Add Folder... | ⌘⇧O | `\.addFolderAction` |
| Edit | Cut | ⌘X | `\.folderEditAction.cut` |
| Edit | Copy | ⌘C | `\.folderEditAction.copy` |
| Edit | Paste | ⌘V | `\.folderEditAction.paste` |
| Navigate | Left/Right/Up/Down | ←→↑↓ | `\.photoNavigation` |
| Navigate | Open | ↩ | `\.photoNavigation.enter` |
| Edit | Move to Trash | ⌫ / ⌦ | `\.deletePhotoAction` |
| Playback | Play / Pause | 無 | `\.videoPlayPause` |

### FocusedValues 定義

```swift
\.photoNavigation: PhotoNavigationAction
  { navigateLeft, navigateRight, navigateUp, navigateDown, enter }
  // 由 PhotoGridView（網格導航）和 ContentView（詳情左右切換）設定

\.addFolderAction: (() -> Void)?
  // 由 SidebarView 設定

\.folderEditAction: FolderEditAction
  { copy?, cut?, paste? }
  // 由 PhotoGridView 設定（選中子資料夾時啟用；重命名 alert 顯示時禁用）

\.videoPlayPause: (() -> Void)?
  // 由 PhotoDetailView 設定（videoController.togglePlayPause）
```

### 詳情頁自訂鍵監控（NSEvent.addLocalMonitorForEvents）

| 按鍵 | 行為 |
|------|------|
| Space | Play/Pause；首次按下時啟動 Gyro |
| F | toggleFullScreen |
| S | Toggle Gyro |
| I | Toggle Inspector |

### Escape 鍵（ContentView.EscapeKeyMonitor）

```
keyCode 53:
  全螢幕 → 退出
  詳情頁 → 返回網格
  子資料夾 → 返回上層
```

---

## 12. 安全作用域書籤（Sandbox）

### 流程

```
使用者選擇資料夾（NSOpenPanel / 拖放）
  ↓
BookmarkService.createBookmark(for: url)
  → url.bookmarkData(options: .withSecurityScope)
  ↓
ScannedFolder(path, bookmarkData, remountURL)
  → modelContext.insert + save
```

### 使用場景

| 操作 | 解析 | start/stop |
|------|------|------------|
| FolderScanner.scanFolder | resolveBookmark → rootURL | rootURL |
| FolderScanner.listSubfolders | resolveBookmark | withSecurityScope |
| ThumbnailService.thumbnail | resolveBookmark → folderURL | folderURL |
| ImagePreloadCache.loadVideoEntry | resolveBookmark → folderURL | folderURL |
| ImagePreloadCache.loadImageEntry | resolveBookmark → folderURL | folderURL |
| VideoPlayerNSView.load | resolveBookmark → folderURL | start in load, stop in stop() |
| PhotoGridView.scanCurrentLevel | resolveBookmark → rootURL | rootURL |
| PhotoGridView.performPaste | resolveBookmark × 2（src/dst） | srcRoot + dstRoot |
| PhotoGridView.performRename | resolveBookmark → rootURL | withSecurityScope |

### 重要模式

- `Photo.resolveBookmarkData(from:)` — 優先關係 fallback 路徑匹配
- 書籤 stale 時自動嘗試刷新
- 跨作用域操作（不同書籤根）：copy + remove 替代 moveItem

---

## 13. 設定系統

### CacheSettingsTab

| 控制項 | AppStorage Key | 預設值 |
|--------|----------------|--------|
| Disk Usage + Clear | — | — |
| Size Limit Picker | `thumbnailCacheLimitMB` | 500 |

### PlaybackSettingsTab

| 控制項 | AppStorage Key | 預設值 |
|--------|----------------|--------|
| Show diagnostics badge | `showDiagBadge` | true |

### GyroSettingsTab

| 控制項 | AppStorage Key | 預設值 |
|--------|----------------|--------|
| 啟用 Gyro | `gyroStabEnabled` | true |
| dylib 狀態 | — | 顯示 |
| Reset to Defaults | — | — |
| Smoothness | `gyroSmooth` | 0.5 |
| Per-axis | `gyroPerAxis` | false |
| Pitch/Yaw/Roll | `gyroSmoothnessPitch/Yaw/Roll` | 0 |
| Gyro Offset | `gyroOffsetMs` | 0 |
| Lens Profile | `gyroLensPath` | "" |
| Integration Method | `gyroIntegrationMethod` | 2 (VQF) |
| IMU Orientation | `gyroImuOrientation` | "YXz" |
| Use Gravity Vectors | `gyroUseGravityVectors` | false |
| FOV | `gyroFov` | 1.0 |
| Lens Correction | `gyroLensCorrectionAmount` | 1.0 |
| Zooming Method | `gyroZoomingMethod` | 1 |
| Adaptive Zoom | `gyroAdaptiveZoom` | 4.0 |
| Max Zoom | `gyroMaxZoom` | 130.0 |
| Max Zoom Iterations | `gyroMaxZoomIterations` | 5 |
| Horizon Lock Amount | `gyroHorizonLockAmount` | 0 |
| Horizon Lock Roll | `gyroHorizonLockRoll` | 0 |
| Video Speed | `gyroVideoSpeed` | 1.0 |

---

## 14. 網路磁碟支援

1. **加入資料夾時**：`BookmarkService.remountURL(for:)` 擷取 SMB URL
2. **瀏覽時**：`NetworkVolumeService.isVolumeMounted()` 檢查
3. **未掛載**：`ensureMounted()` → `NSWorkspace.open(smb://...)` → 輪詢 15s
4. **UI**：`isMounting` 狀態 → "Connecting…" ProgressView

---

## 15. 資料夾剪貼簿

### 操作

| 操作 | 觸發 | 行為 |
|------|------|------|
| Copy | ⌘C / 右鍵 | `FolderClipboard.copy(path, bookmarkData)` |
| Cut | ⌘X / 右鍵 | `FolderClipboard.cut(path, bookmarkData)` |
| Paste | ⌘V / 右鍵 | `performPaste()` |

### performPaste 邏輯

```
1. 解析 src 和 dst 書籤
2. 判斷 crossScope（不同書籤根）
3. 檢查 fileExists(dst)
4. isCut:
   - crossScope: copyItem + removeItem（rollback on failure）
   - sameScope: moveItem
   → clipboard.clear()
5. !isCut:
   - copyItem
6. scanCurrentLevel()（刷新 UI）
```

### performRename

```
withSecurityScope(rootURL) {
  FileManager.moveItem(at: src, to: dst)
}
scanCurrentLevel()
```

---

## 16. Entitlements 與沙盒

```xml
com.apple.security.cs.disable-library-validation = true   // dlopen gyrocore dylib
com.apple.security.files.bookmarks.app-scope = true       // 安全作用域書籤
com.apple.security.files.user-selected.read-write = true  // NSOpenPanel 使用者選擇
```

**注意**：**未啟用** `com.apple.security.app-sandbox`。App 有沙盒風格的書籤管理但實際上並非嚴格沙盒。`disable-library-validation` 允許載入未簽章的 gyrocore dylib。

---

## 17. 關鍵設計模式

### 資料存取

- **SwiftData @Model + @Query**：Photo 與 ScannedFolder 自動同步 UI
- **@ModelActor（FolderScanner）**：背景插入不阻塞 UI
- **PersistentIdentifier 傳遞**：跨 actor 安全
- **批次 save（100 筆）**：減少 @Query 更新頻率

### 並行安全

- **ThumbnailService**：Swift Actor
- **FolderListCache**：NSLock
- **GyroCore**：readyLock + coreLock（NSLock）
- **VideoController**：CVDisplayLink（背景執行緒）驅動渲染
- **@Observable 更新**：只在 main queue 做輕量賦值

### HDR 渲染

- **圖片**：`NSImageView.preferredImageDynamicRange`（Gain Map）或 `CALayer + colorspace`（HLG）
- **影片**：Metal CAMetalLayer colorspace 切換（HLG/PQ/sRGB）+ decode mode
- **EDR 啟用**：CAMetalLayer EDR headroom 管理

### 效能

- **推斷子資料夾**：從 DB 路徑推導，無 I/O → 即時顯示
- **FolderListCache**：JSON 持久化，啟動時載入，避免重複掃描
- **pendingPaths**：磁碟列舉後立即顯示佔位符，DB 入庫後消失
- **CVDisplayLink**：幀計時不阻塞主執行緒
- **輪詢限制（4 Hz）**：避免 @Observable 更新 flooding

### 安全

- **書籤生命週期**：start → 操作 → stop（defer）
- **跨作用域 paste**：copy + remove 替代 rename（跨 scope 可能失敗）
- **stale 書籤**：resolveBookmark 自動嘗試刷新

---

## 18. Tauri 改寫注意事項

### 資料模型

- SwiftData → **SQLite**（via `rusqlite` / `sqlx` / Tauri 的 `tauri-plugin-sql`）
- Photo 表的所有欄位直接對映
- ScannedFolder 表需保存書籤等效資料

### 沙盒與檔案存取

- macOS 安全作用域書籤 → Tauri `dialog` plugin 取得路徑；非沙盒模式下可直接讀寫
- 若需沙盒：需實作 bookmark 等效機制或使用 Tauri 的 `fs` plugin scope

### 縮圖

- `CGImageSourceCreateThumbnailAtIndex` → Rust `image` crate + `libheif` / `turbojpeg`
- SVG → `resvg`
- 影片 → `ffmpeg` CLI 或 `ffmpeg-next` crate
- 磁碟快取：SHA256 hash → `.webp` / `.avif`

### EXIF

- `CGImageSource` → Rust `kamadak-exif` / `rexif` / `exif` crate
- GPS 座標需手動處理 N/S E/W

### HDR 影像

- **最大挑戰**：Gain Map 渲染在 Tauri（WebView）中無原生支援
- HLG：需要 WebGPU/WebGL2 + HDR 傳輸函數
- 建議：wgpu 或 native NSView bridge

### 影片播放

- 目前使用 AVFoundation + Metal，Tauri 需要 native plugin 處理影片渲染
- **建議**：Tauri sidecar / native plugin + wgpu 處理影片窗口

### Gyroflow

- 已有 Rust 原生的 `gyroflow-core`，直接整合
- 矩陣計算可直接在 Rust 端完成

### 前端框架

- SwiftUI → **任選**：React / Svelte / Vue / Solid
- `NavigationSplitView` → 自訂三欄佈局
- `LazyVGrid` → 虛擬化網格（如 `react-window` / 自訂虛擬滾動）
- `@Observable` / `@AppStorage` → Tauri store / Zustand / Svelte stores

### 選單與快捷鍵

- Tauri `menu` module → 定義原生選單
- 快捷鍵：Tauri `global-shortcut` 或前端鍵盤事件

### 網路磁碟

- 掛載偵測：`std::path::Path::exists()`
- SMB 觸發掛載：`open` command（macOS）

### 建議優先順序

1. **基礎**：SQLite schema + 資料夾掃描 + 縮圖生成
2. **瀏覽**：側邊欄 + 網格 + 時間軸
3. **詳情**：圖片查看器（含縮放）
4. **影片**：影片播放（AVFoundation + Metal / wgpu）
5. **HDR**：圖片 Gain Map / HLG（需研究 WebView HDR 支援）
6. **Gyro**：gyroflow-core 直接整合
7. **進階**：資料夾管理、網路磁碟、Per-type player 等
