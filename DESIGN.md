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
9. [MPV 整合](#9-mpv-整合)
10. [AVPlayer 整合](#10-avplayer-整合)
11. [Gyroflow 陀螺儀穩定](#11-gyroflow-陀螺儀穩定)
12. [鍵盤快捷鍵與選單命令](#12-鍵盤快捷鍵與選單命令)
13. [安全作用域書籤（Sandbox）](#13-安全作用域書籤sandbox)
14. [設定系統](#14-設定系統)
15. [網路磁碟支援](#15-網路磁碟支援)
16. [資料夾剪貼簿](#16-資料夾剪貼簿)
17. [Entitlements 與沙盒](#17-entitlements-與沙盒)
18. [關鍵設計模式](#18-關鍵設計模式)
19. [Tauri 改寫注意事項](#19-tauri-改寫注意事項)

---

## 1. 專案概覽

**Spectrum** 是一款 **macOS 原生相簿瀏覽器**（非匯入制）。核心理念：

- **掃描既有資料夾**，不複製/搬移檔案
- **無「全部照片」視圖**；側邊欄直接列出資料夾
- **時間軸網格**：照片按月份分組、降序排列
- **子資料夾瓷磚**：在網格中顯示為可導航的封面磁貼
- **影片播放**：支援 libmpv（進階，HDR/Gyro）與 AVPlayer（系統級）
- **HDR**：圖片（Gain Map、HLG）與影片（HLG、HDR10、Dolby Vision）
- **Gyroflow 穩定**：即時透過 gyroflow-core 矩陣套用於 mpv 渲染
- **資料夾管理**：複製/剪下/貼上/重新命名子資料夾
- **網路磁碟**：SMB 自動重新掛載

**技術堆疊**：Swift 6 + SwiftUI + SwiftData + AVFoundation + OpenGL（mpv）

**視窗結構**：單一 `WindowGroup`，`NavigationSplitView`（側邊欄 + 內容），加上 `Settings` 視窗。

---

## 2. 檔案清單與職責

### App 進入點
| 檔案 | 職責 |
|------|------|
| `SpectrumApp.swift` | `@main`；初始化 LibMPV 單例；WindowGroup + Settings；定義 4 組選單命令 |

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
| `Services/MPVLib.swift` | 單例：dlopen libmpv.dylib，所有 C 函式指標 |
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
| `Views/Grid/PhotoGridView.swift` | LazyVGrid 主網格；子資料夾/照片；剪貼簿；掃描進度 |
| `Views/Grid/PhotoThumbnailView.swift` | 單張照片磁貼（HDR 縮圖 + 影片徽章） |
| `Views/Grid/TimelineSectionHeader.swift` | 時間軸月份 sticky header |

### 視圖 — 詳情
| 檔案 | 職責 |
|------|------|
| `Views/Detail/PhotoDetailView.swift` | 圖片/影片查看器；HDR 切換；mpv vs AVPlayer 選擇；Gyro 整合 |
| `Views/Detail/HDRImageViews.swift` | HDRImageView、HLGImageView、HDRVideoPlayerView |
| `Views/Detail/MPVPlayerView.swift` | MPVOpenGLLayer（CAOpenGLLayer）；Gyro 著色器；CVDisplayLink |
| `Views/Detail/MPVController.swift` | `@Observable` mpv 播放狀態；背景輪詢；Gyro 生命週期 |
| `Views/Detail/MPVControlBar.swift` | mpv 浮動控制列 |
| `Views/Detail/AVPlayerControlBar.swift` | AVPlayerController + AVPlayer 浮動控制列 |
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

### 4.8 LibMPV（單例）

**dlopen 搜尋**：
1. `Bundle.main.resourcePath/lib/libmpv.dylib`（沙盒安全）
2. `/Applications/IINA.app/Contents/Frameworks/libmpv{,.2}.dylib`
3. `/opt/homebrew/lib/libmpv.dylib`
4. `/usr/local/lib/libmpv.dylib`

**C 函式指標**：
```
create   → mpv_create
initialize → mpv_initialize
setStr   → mpv_set_option_string (初始化前)
setProp  → mpv_set_property_string (執行時)
getStr   → mpv_get_property_string
command  → mpv_command
waitEvent → mpv_wait_event
destroy  → mpv_terminate_destroy
free     → mpv_free
rcCreate → mpv_render_context_create
rcSetCb  → mpv_render_context_set_update_callback
rcRender → mpv_render_context_render
rcSwap   → mpv_render_context_report_swap
rcFree   → mpv_render_context_free
```

**輔助結構體**（記憶體佈局必須與 mpv C struct 完全匹配）：
- `MPVRenderParam`（16 bytes: int32 type + 4B pad + ptr data）
- `MPVOpenGLFBO`（fbo, w, h, internal_format — 全 int32）
- `MPVOpenGLInitParams`（get_proc_address + ctx）
- `MPVEvent`（event_id, error, reply_userdata, data）

### 4.9 NetworkVolumeService（靜態）

```
volumeRoot(for: path) → String?       // "/Volumes/MyNAS"
isVolumeMounted(path:) → Bool
ensureMounted(folder:) async → Bool   // @MainActor
  1. 若已掛載 → true
  2. 若有 remountURL → NSWorkspace.open(smb://...)
  3. 否則 → NSWorkspace.open(/Volumes/name)
  4. 輪詢 15s（30 × 0.5s）等待出現
```

### 4.10 FolderClipboard（@Observable @MainActor 單例）

```
content: ClipboardFolder?
hasContent: Bool
copy(path:, bookmarkData:)
cut(path:, bookmarkData:)
clear()
```

### 4.11 FolderListCache（單例，NSLock 線程安全）

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

### 5.2 MPVController（@Observable, @unchecked Sendable）

**狀態屬性**（主執行緒可觀測）：
```
isPlaying, currentTime, duration: Double
renderFPS, renderCV, renderStability, videoFPS: Double
droppedFrames, decoderDroppedFrames: Int
hwdecInfo: String
gyroComputeMs: Double
gyroStabEnabled, gyroAvailable: Bool
diagnosticsEnabled: Bool  // 控制輪詢開銷
```

**方法**：
```
reset()                                    // 新影片載入前清除
startPolling(view: MPVPlayerNSView)        // 開始 4Hz 背景輪詢
stopPolling()
togglePlayPause()                          // 含 EOF 重播、deferredPlay（等 Gyro）
seek(to: seconds)
startGyroStab(videoPath:, fps:, config:, lensPath:)
stopGyroStab()
```

**輪詢架構**：
- `pollQueue`（background serial）每 0.25s 讀取 mpv API（執行緒安全）
- 只在 main queue 做輕量 @Observable 屬性賦值
- 若 `diagnosticsEnabled == false`，跳過所有診斷讀取

### 5.3 AVPlayerController（@Observable, @unchecked Sendable）

```
isPlaying, currentTime, duration: Double
codecInfo: String
videoFPS, renderFPS, renderCV: Double

attach(player:)   // 建立 time observer + CVDisplayLink + video output
detach()
togglePlayPause()  // 含 EOF 重播
seek(to:)
```

**CVDisplayLink 幀計時**：
- `AVPlayerItemVideoOutput.hasNewPixelBuffer` + `copyPixelBuffer` 偵測新幀
- 用 `presentationTime` 去重複（120Hz 螢幕偵測 60fps 影片時避免雙倍計數）
- `frameIntervals`（最近 60 幀）→ 計算 mean → FPS、variance → CV
- 每 0.25s dispatch 到 main（避免 flooding）

### 5.4 ThumbnailCacheState（@Observable @MainActor 單例）

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
│       │       │       ├── useMPV: MPVPlayerView + MPVControlBar + mpvDiagBadge
│       │       │       └── !useMPV: HDRVideoPlayerView + AVPlayerControlBar + avDiagBadge
│       │       ├── 有 subfolder 選擇 → PhotoGridView + Back 按鈕
│       │       └── 有 folder 選擇 → PhotoGridView
│       └── .inspector { PhotoInfoPanel }
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
- **排序**: subfoldersAreInOrder — 最新 coverDate 優先，相同日期時字母序
- **剪貼簿 UI**: context menu Copy/Cut/Paste + Cmd+C/X/V
- **重命名**: alert TextField → FileManager.moveItem

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
  2. `resolvedPlayer(for:)` 查 per-type AppStorage → fallback 全域
  3. mpv → set useMPV=true（SwiftUI 切換視圖）
  4. AVPlayer → loadVideoEntry → attach + composition
- **HDR 切換**: showHDR toggle → AVPlayer: swap composition；mpv: colorspace + target-trc
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

**HLG（mpv 風格直接渲染）**：
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

### Per-Type Player Selection

每種 HDR 類型有獨立 `@AppStorage`：
```
playerForSDR           = "default"
playerForHLG           = "default"
playerForHDR10         = "default"
playerForDolbyVision   = "default"
playerForSLog2         = "default"
playerForSLog3         = "default"
```

`"default"` fallback 到全域 `videoPlayer`（`"libmpv"` 或 `"avplayer"`）。

**流程**：
1. `detectVideoHDRType()` → 輕量偵測（~50ms）
2. 查 per-type 設定 → `"default"` → 全域
3. mpv: 立即設 `useMPV=true`（SwiftUI 渲染）
4. AVPlayer: loadVideoEntry → 建立 player + composition

### 診斷 Badge

**mpv Badge**（右上角）：
- HDR/SDR 切換 pill + GYRO 切換 pill
- hwdec info（"videotoolbox"）
- renderFPS / videoFPS + CV dot（green/yellow/red）
- dropped frames（vo + dec）
- gyro compute time

**AVPlayer Badge**（右上角）：
- HDR/SDR 狀態 + codec
- renderFPS / videoFPS + CV dot

**CV 門檻**：green < 0.05、yellow < 0.15、red ≥ 0.15

---

## 9. MPV 整合

### MPVOpenGLLayer（CAOpenGLLayer, @unchecked Sendable）

**`isAsynchronous = true`**：專用渲染執行緒，非主執行緒。

**初始化**：
```
copyCGLPixelFormatForDisplayMask:
  嘗試 Float16 pixel format (kCGLPFAColorFloat)
  Fallback: 標準 pixel format
  → 設定 isFloat

open(in: CGLContextObj):
  mpv_create → 設定選項 → mpv_initialize
  mpv_render_context_create（OpenGL render API）
  set update callback → display()
```

**mpv 設定**：
```
vo = libmpv
hwdec = <AppStorage mpvHwdec，預設 auto>
keep-open = yes
pause = yes（初始暫停）
video-sync = display-resample（若 mpvAVSync）或 audio
framedrop = vo（若 mpvFrameDrop）或 no
target-trc = auto（初始）
```

**HDR colorspace 切換**：
```
HLG:   layer.colorspace = itur_2100_HLG; target-trc = auto
HDR10: layer.colorspace = itur_2100_PQ;  target-trc = auto
SDR toggle: layer.colorspace = sRGB; target-trc = bt.709
DV → 由 AVPlayer 處理（VideoToolbox 解碼 DV 為 HLG）
```

**Gyro 著色器整合**：
```
draw(in: CGLContextObj, pixelFormat, forLayerTime, displayTime):
  1. 若 waitingForGyro → 跳過渲染
  2. 若 gyroCore != nil:
     frameIdx = round(layerTime * fps)
     (matBuf, changed) = gyroCore.computeMatrix(frameIdx)
     若 changed: upload matTex (glTexSubImage2D, RGBA32F, width=4, height=vH)
  3. mpv_render_context_render(fbo)
  4. 若 gyro: bind matTex + 設定 uniforms → 執行 warp shader
  5. report_swap + 幀計時

Warp Shader (GLSL):
  vec2 pt = f * (fragCoord / viewport - 0.5)
  從 matTex 讀取該行的 mat3×3 + IBIS(sx,sy,ra) + OIS(ox,oy)
  pt = rotate(-ra) * pt + vec2(-sx, -sy)    // IBIS
  pt = pt + vec2(ox, oy)                    // OIS
  pt = pt / f + c                           // 反投影
  gl_FragColor = texture(videoTex, pt)
```

**CVDisplayLink 幀計時**（用於 renderFPS/CV）：
- 在 `draw()` 中記錄 `CACurrentMediaTime()`
- `frameIntervals`（最近 60 幀）→ mean → FPS、stddev/mean → CV

### MPVPlayerNSView（NSView wrapper）

```
load(url:, bookmarkData:):
  解析書籤 → 啟動作用域（deinit/stop 時停止）
  建立 MPVOpenGLLayer → 加入 layer hierarchy
  mpv loadfile command

setPause(Bool), seek(to:)
loadGyroCore(GyroCore?)  // 設定或清除 layer 的 gyroCore
setWaitingForGyro(Bool)  // 抑制渲染直到 gyro ready
```

---

## 10. AVPlayer 整合

**HDRVideoPlayerView** → `EDRPlayerView : AVPlayerView`（controlsStyle = .none）

**EDR 啟用**：
```
viewDidMoveToWindow(), layout():
  enableEDR() → 遍歷整個 layer tree
  macOS 26+: preferredDynamicRange = .high
  舊版: wantsExtendedDynamicRangeContent = true
```

**AVPlayerControlBar**：與 MPVControlBar 視覺風格完全相同。

---

## 11. Gyroflow 陀螺儀穩定

### 啟動流程

```
PhotoDetailView.startPlayback()
  → MPVController.startGyroStab(videoPath, fps, config, lensPath)
    → GyroCore().start(...)
      → ioQueue（背景）: dylib 載入 + gyrocore_load（~0.3s）
      → onReady（main queue）:
        mpvController.gyroStabEnabled = true
        nsView.loadGyroCore(core)  // 清除 waitingForGyro
        若 deferredPlay → nsView.setPause(false)
```

### 每幀矩陣計算

```
MPVOpenGLLayer.draw():
  frameIdx = round(layerTime * gyroFps)
  (matBuf, changed) = gyroCore.computeMatrix(frameIdx)
  若 changed:
    glBindTexture(matTex)
    glTexSubImage2D(matBuf, RGBA32F, width=4, height=videoHeight)
  繪製 warp shader
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

## 12. 鍵盤快捷鍵與選單命令

### 選單命令（全域）

| 選單 | 項目 | 快捷鍵 | FocusedValue |
|------|------|--------|--------------|
| File | Add Folder... | ⌘⇧O | `\.addFolderAction` |
| Edit | Cut | ⌘X | `\.folderEditAction.cut` |
| Edit | Copy | ⌘C | `\.folderEditAction.copy` |
| Edit | Paste | ⌘V | `\.folderEditAction.paste` |
| Navigate | Left/Right/Up/Down | ←→↑↓ | `\.photoNavigation` |
| Navigate | Open | ↩ | `\.photoNavigation.enter` |
| Playback | Play / Pause | 無 | `\.mpvPlayPause` |

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

\.mpvPlayPause: (() -> Void)?
  // 由 PhotoDetailView 設定（useMPV 時為 mpvController.togglePlayPause）
```

### 詳情頁自訂鍵監控（NSEvent.addLocalMonitorForEvents）

| 按鍵 | 行為 |
|------|------|
| Space | Play/Pause；首次按下時啟動 Gyro |
| F | toggleFullScreen |
| S | Toggle Gyro（mpv only） |
| I | Toggle Inspector |

### Escape 鍵（ContentView.EscapeKeyMonitor）

```
keyCode 53:
  全螢幕 → 退出
  詳情頁 → 返回網格
  子資料夾 → 返回上層
```

---

## 13. 安全作用域書籤（Sandbox）

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
| MPVPlayerNSView.load | resolveBookmark → folderURL | start in load, stop in deinit |
| PhotoGridView.scanCurrentLevel | resolveBookmark → rootURL | rootURL |
| PhotoGridView.performPaste | resolveBookmark × 2（src/dst） | srcRoot + dstRoot |
| PhotoGridView.performRename | resolveBookmark → rootURL | withSecurityScope |

### 重要模式

- `Photo.resolveBookmarkData(from:)` — 優先關係 fallback 路徑匹配
- 書籤 stale 時自動嘗試刷新
- 跨作用域操作（不同書籤根）：copy + remove 替代 moveItem

---

## 14. 設定系統

### CacheSettingsTab

| 控制項 | AppStorage Key | 預設值 |
|--------|----------------|--------|
| Disk Usage + Clear | — | — |
| Size Limit Picker | `thumbnailCacheLimitMB` | 500 |

### PlaybackSettingsTab

| 控制項 | AppStorage Key | 預設值 |
|--------|----------------|--------|
| Decoder（segmented） | `videoPlayer` | `"libmpv"` |
| Per-Type: SDR | `playerForSDR` | `"default"` |
| Per-Type: HLG | `playerForHLG` | `"default"` |
| Per-Type: HDR10 | `playerForHDR10` | `"default"` |
| Per-Type: Dolby Vision | `playerForDolbyVision` | `"default"` |
| Per-Type: S-Log2 | `playerForSLog2` | `"default"` |
| Per-Type: S-Log3 | `playerForSLog3` | `"default"` |
| hwdec Picker | `mpvHwdec` | `"auto"` |
| Video/Audio Sync | `mpvAVSync` | true |
| Frame Drop | `mpvFrameDrop` | true |
| Show diagnostics badge | `showMPVDiagBadge` | true |

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

## 15. 網路磁碟支援

1. **加入資料夾時**：`BookmarkService.remountURL(for:)` 擷取 SMB URL
2. **瀏覽時**：`NetworkVolumeService.isVolumeMounted()` 檢查
3. **未掛載**：`ensureMounted()` → `NSWorkspace.open(smb://...)` → 輪詢 15s
4. **UI**：`isMounting` 狀態 → "Connecting…" ProgressView

---

## 16. 資料夾剪貼簿

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

## 17. Entitlements 與沙盒

```xml
com.apple.security.cs.disable-library-validation = true   // dlopen libmpv/gyrocore
com.apple.security.files.bookmarks.app-scope = true       // 安全作用域書籤
com.apple.security.files.user-selected.read-write = true  // NSOpenPanel 使用者選擇
```

**注意**：**未啟用** `com.apple.security.app-sandbox`。App 有沙盒風格的書籤管理但實際上並非嚴格沙盒。`disable-library-validation` 允許載入未簽章的 dylib。

---

## 18. 關鍵設計模式

### 資料存取

- **SwiftData @Model + @Query**：Photo 與 ScannedFolder 自動同步 UI
- **@ModelActor（FolderScanner）**：背景插入不阻塞 UI
- **PersistentIdentifier 傳遞**：跨 actor 安全
- **批次 save（100 筆）**：減少 @Query 更新頻率

### 並行安全

- **ThumbnailService**：Swift Actor
- **FolderListCache**：NSLock
- **GyroCore**：readyLock + coreLock（NSLock）
- **MPVController**：pollQueue（Serial DispatchQueue）
- **AVPlayerController**：CVDisplayLink（背景執行緒）+ isAttached guard
- **@Observable 更新**：只在 main queue 做輕量賦值

### HDR 渲染

- **圖片**：`NSImageView.preferredImageDynamicRange`（Gain Map）或 `CALayer + colorspace`（HLG）
- **影片 AVPlayer**：`AVVideoComposition` 切換（HDR ↔ SDR）
- **影片 mpv**：`CAOpenGLLayer.colorspace` + `target-trc` 切換
- **EDR 啟用**：遍歷整個 layer 樹（上至 window、下至所有子 layer）

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

## 19. Tauri 改寫注意事項

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

- **mpv**：可直接用 `libmpv` C FFI（Rust `mpv` crate）
- **AVPlayer**：需 Objective-C/Swift bridge（`objc2` crate）或 native plugin
- **建議**：Tauri sidecar / native plugin 處理影片窗口

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
4. **影片**：mpv 整合（最重要的 native 部分）
5. **HDR**：圖片 Gain Map / HLG（需研究 WebView HDR 支援）
6. **Gyro**：gyroflow-core 直接整合
7. **進階**：資料夾管理、網路磁碟、Per-type player 等
