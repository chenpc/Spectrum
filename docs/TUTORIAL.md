# Spectrum 開發教學手冊

一份從零開始理解 Spectrum 每一行程式碼的教學文件。

---

## 目錄

1. [專案總覽](#1-專案總覽)
2. [App 入口點：SpectrumApp](#2-app-入口點spectrumapp)
3. [資料模型 (SwiftData)](#3-資料模型-swiftdata)
4. [書籤與安全權限](#4-書籤與安全權限)
5. [資料夾掃描：FolderScanner](#5-資料夾掃描folderscanner)
6. [資料夾快取與監視](#6-資料夾快取與監視)
7. [網路磁碟區支援](#7-網路磁碟區支援)
8. [視圖架構總覽](#8-視圖架構總覽)
9. [ContentView：三欄佈局的中樞](#9-contentview三欄佈局的中樞)
10. [SidebarView：側邊欄與資料夾管理](#10-sidebarview側邊欄與資料夾管理)
11. [PhotoGridView：時間線網格](#11-photogridview時間線網格)
12. [PhotoThumbnailView：縮圖顯示](#12-photothumbnailview縮圖顯示)
13. [ThumbnailService：縮圖快取系統](#13-thumbnailservice縮圖快取系統)
14. [PhotoDetailView：全尺寸檢視](#14-photodetailview全尺寸檢視)
15. [HDR 渲染](#15-hdr-渲染)
16. [ImagePreloadCache：預載快取](#16-imagepreloadcache預載快取)
17. [影片播放：AVF Metal 管線](#17-影片播放avf-metal-管線)
18. [Gyroflow 防手震整合](#18-gyroflow-防手震整合)
19. [非破壞性編輯系統](#19-非破壞性編輯系統)
20. [匯入面板](#20-匯入面板)
21. [搜尋功能](#21-搜尋功能)
22. [狀態列](#22-狀態列)
23. [EXIF 與影片中繼資料](#23-exif-與影片中繼資料)
24. [PhotoInfoPanel：EXIF 面板](#24-photoinfopanelexif-面板)
25. [鍵盤導航系統](#25-鍵盤導航系統)
26. [全螢幕模式](#26-全螢幕模式)
27. [日誌系統](#27-日誌系統)
28. [設定畫面](#28-設定畫面)
29. [Extension 工具](#29-extension-工具)
30. [完整架構圖](#30-完整架構圖)

---

## 1. 專案總覽

Spectrum 是一個原生 macOS 照片瀏覽器，專門解決 Apple Photos 無法正確顯示 Sony HLG HDR 照片的問題。

### 核心設計原則

- **不複製、不匯入**：直接掃描使用者指定的資料夾，照片保持在原地
- **HDR 優先**：內建 HDR 渲染，支援 HLG（Sony）和 Apple Gain Map（iPhone）
- **沙盒安全**：使用 macOS security-scoped bookmark 取得永久存取權
- **影片防手震**：整合 Gyroflow C API，支援即時 Metal GPU 穩定化

### 技術棧

| 技術 | 用途 |
|------|------|
| SwiftUI | 使用者介面 |
| SwiftData | 資料儲存（照片、資料夾） |
| Metal | 影片渲染、Gyro 防手震 warp shader |
| AVFoundation | 影片播放、HDR 偵測 |
| CVDisplayLink | 影片幀同步 |
| ImageIO (CGImageSource) | EXIF 讀取、縮圖產生 |
| FSEvents | 資料夾變動監視 |
| Security-Scoped Bookmarks | 沙盒存取權限 |
| os.Logger | 結構化日誌 |

### 目錄結構

```
Spectrum/
├── SpectrumApp.swift             # App 入口點、選單命令
├── ThumbnailCacheState.swift     # 縮圖快取更新通知
├── Models/
│   ├── Photo.swift               # 照片資料模型
│   ├── ScannedFolder.swift       # 資料夾資料模型
│   ├── EditOp.swift              # 編輯操作 enum (crop/rotate/flipH)
│   └── CropRect.swift            # 裁剪矩形工具
├── ViewModels/
│   └── LibraryViewModel.swift    # 時間線分組、照片導航
├── Views/
│   ├── ContentView.swift         # 三欄佈局中樞
│   ├── SearchResultsView.swift   # 搜尋結果
│   ├── SettingsView.swift        # 偏好設定
│   ├── Sidebar/
│   │   ├── SidebarView.swift     # 側邊欄
│   │   └── CacheSidebarFooter.swift  # 快取統計頁尾
│   ├── Grid/
│   │   ├── PhotoGridView.swift       # 時間線網格 + 子資料夾
│   │   ├── PhotoThumbnailView.swift  # 單張縮圖
│   │   └── TimelineSectionHeader.swift
│   ├── Detail/
│   │   ├── PhotoDetailView.swift     # 全尺寸、HDR、影片、編輯
│   │   ├── HDRImageViews.swift       # HDR 影像檢視元件
│   │   ├── LivePhotoPlayerView.swift # Live Photo 播放器
│   │   ├── CropOverlayView.swift     # 裁剪 UI
│   │   ├── AVFMetalView.swift        # Metal 渲染引擎
│   │   ├── MetalShaders.swift        # Metal 著色器
│   │   ├── VideoPlayerNSView.swift   # NSView 橋接器
│   │   ├── VideoController.swift     # 播放狀態管理
│   │   ├── VideoControlBar.swift     # 浮動控制條
│   │   └── PhotoInfoPanel.swift      # EXIF 面板
│   └── Import/
│       └── ImportPanelView.swift     # 匯入面板 + ImportPanelModel
├── Services/
│   ├── BookmarkService.swift         # 安全權限書籤
│   ├── FolderScanner.swift           # @ModelActor 檔案掃描
│   ├── FolderListCache.swift         # 子資料夾列表快取 (JSON 持久化)
│   ├── FolderMonitor.swift           # FSEvents 監視
│   ├── FolderClipboard.swift         # 資料夾剪貼板 (複製/剪切/貼上)
│   ├── NetworkVolumeService.swift    # 網路磁碟區掛載
│   ├── ThumbnailService.swift        # @actor 縮圖產生與快取
│   ├── ImagePreloadCache.swift       # 預載快取 + HDRFormat enum
│   ├── EXIFService.swift             # EXIF 讀取
│   ├── VideoMetadataService.swift    # 影片中繼資料
│   ├── XMPSidecarService.swift       # XMP 邊車檔案 (gyro 設定)
│   ├── StatusBarModel.swift          # 全域狀態列
│   ├── CGImageRotation.swift         # CGImage 旋轉工具
│   ├── GyroConfig.swift              # 陀螺儀參數配置
│   ├── GyroCore.swift                # gyrocore_* C API 封裝
│   ├── GyroFlowCore.swift            # gyroflow_* C API 封裝
│   └── Log.swift                     # os.Logger 統一日誌
├── Extensions/
│   ├── Date+Formatting.swift         # 日期格式化
│   └── URL+ImageTypes.swift          # 檔案類型判斷
└── Resources/
    └── AppIcon.svg                   # 圖示原始檔
```

---

## 2. App 入口點：SpectrumApp

**檔案**：`SpectrumApp.swift`

這是整個應用程式的起點。

### `@main` 與 App 協定

```swift
@main
struct SpectrumApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Photo.self, ScannedFolder.self])
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            FileCommands()
            PhotoNavigationCommands()
            FolderEditCommands()
            DeleteCommands()
            MpvPlaybackCommands()
        }

        Settings {
            SettingsView()
        }
    }
}
```

**重點學習**：
- `@main`：標記程式進入點
- `WindowGroup`：建立主視窗
- `.modelContainer(for:)`：初始化 SwiftData 容器，管理 `Photo` 和 `ScannedFolder` 兩個模型
- `.commands { ... }`：註冊五組選單命令
- `Settings { SettingsView() }`：macOS 的「偏好設定...」視窗

### 五組選單命令

| 命令 | 功能 | 快捷鍵 |
|------|------|--------|
| FileCommands | 新增資料夾 | Cmd+Shift+O |
| PhotoNavigationCommands | 方向鍵導航、Return 進入詳情 | 方向鍵 |
| FolderEditCommands | 資料夾剪貼板（複製/剪切/貼上） | Cmd+C/X/V |
| DeleteCommands | 刪除照片/子資料夾 | Delete/Backspace |
| MpvPlaybackCommands | 影片播放/暫停 | Space |

### FocusedValue 橋接

選單命令需要知道「目前哪個 View 在處理操作」，透過 `@FocusedValue` 機制：

```
SpectrumApp 的選單命令
    ^ 讀取 @FocusedValue(\.photoNavigation)
    |
ContentView / PhotoGridView
    v 設定 .focusedSceneValue(\.photoNavigation, action)
```

ContentView 定義了多個 FocusedValue 鍵：`photoNavigation`、`addFolderAction`、`folderEditAction`、`deletePhotoAction`、`gyroConfigBinding`、`videoController` 等。

---

## 3. 資料模型 (SwiftData)

### Photo — 照片模型

**檔案**：`Models/Photo.swift`

```swift
@Model
final class Photo {
    @Attribute(.unique) var filePath: String   // 唯一鍵：完整路徑
    var fileName: String                        // 檔案名稱
    var dateTaken: Date                         // 拍攝日期（EXIF 或檔案修改日期）
    var dateAdded: Date                         // 加入資料庫的時間
    var fileSize: Int64                         // 檔案大小（bytes）
    var pixelWidth: Int                         // 像素寬
    var pixelHeight: Int                        // 像素高

    // EXIF 快取 — 掃描時一次寫入
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var aperture: Double?
    var shutterSpeed: String?
    var iso: Int?
    var latitude: Double?
    var longitude: Double?
    var exposureBias: Double?
    var meteringMode: Int?
    var flash: Int?
    var whiteBalance: Int?
    var headroom: Double?
    var profileName: String?
    var colorDepth: Int?
    var orientation: Int?

    // 影片欄位
    var isVideo: Bool = false
    var duration: Double?
    var videoCodec: String?
    var audioCodec: String?

    // Live Photo
    var livePhotoVideoPath: String?

    // 編輯操作
    var editOpsJson: String?       // [EditOp] 序列化 JSON
    var cropRectJson: String?      // 舊版向後相容

    // 關係
    var folder: ScannedFolder?
}
```

**重點學習**：
- `@Model`：SwiftData 巨集，自動讓 class 可以持久化到 SQLite
- `@Attribute(.unique)`：主鍵，用 `filePath` 確保同一張照片不會重複
- `editOpsJson`：非破壞性編輯的操作列表，以 JSON 儲存

#### resolveBookmarkData — 解決書籤資料

```swift
func resolveBookmarkData(from folders: [ScannedFolder]) -> Data? {
    if let data = folder?.bookmarkData { return data }
    return folders.first { filePath.hasPrefix($0.path) }?.bookmarkData
}
```

**為什麼需要兩層查詢？**

SwiftData 使用 lazy loading（懶載入）。當你存取 `photo.folder` 時，SwiftData 可能還沒把關聯的 ScannedFolder 載入記憶體，導致 `photo.folder?.bookmarkData` 回傳 `nil`。解法是用 `@Query` 另外查詢所有 `ScannedFolder`，用路徑前綴比對作為 fallback。

### ScannedFolder — 掃描資料夾

**檔案**：`Models/ScannedFolder.swift`

```swift
@Model
final class ScannedFolder {
    var path: String              // "/Users/xxx/Photos/2024"
    var bookmarkData: Data?       // 安全權限書籤
    var remountURL: String?       // 網路磁碟區掛載 URL (e.g. "smb://server/share")
    var dateAdded: Date
    var sortOrder: Int = 0

    @Relationship(deleteRule: .cascade)
    var photos: [Photo] = []      // 刪除資料夾時，連帶刪除所有照片
}
```

**重點學習**：
- `.cascade` 刪除規則：移除資料夾時自動刪除所有 Photo 記錄
- `sortOrder`：讓使用者可以拖拉重排側邊欄的資料夾順序
- `remountURL`：網路磁碟區（SMB/NFS）的掛載 URL，離線時可嘗試重新掛載

---

## 4. 書籤與安全權限

**檔案**：`Services/BookmarkService.swift`

### 為什麼需要書籤？

macOS 沙盒 App 預設無法存取使用者的檔案系統。當使用者透過 `NSOpenPanel` 選擇資料夾後，App 獲得一次性存取權限，但權限會在 App 重啟後失效。

**Security-Scoped Bookmark** 可以把權限序列化成 `Data`，儲存在 SwiftData 裡，下次啟動時還原。

### 三個關鍵函式

#### 1. createBookmark — 建立書籤

```swift
static func createBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
}
```

#### 2. resolveBookmark — 還原書籤

```swift
static func resolveBookmark(_ data: Data) throws -> URL {
    var isStale = false
    let url = try URL(resolvingBookmarkData: data,
                      options: .withSecurityScope,
                      relativeTo: nil,
                      bookmarkDataIsStale: &isStale)
    if isStale {
        // 書籤過期，重新產生
    }
    return url
}
```

#### 3. withSecurityScope — 安全存取包裝

```swift
static func withSecurityScope<T>(_ url: URL, body: () throws -> T) rethrows -> T {
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
    return try body()
}
```

使用模式：啟用 → 做事 → 一定會結束。`defer` 確保無論成功或失敗都會釋放資源。

### 在哪裡使用？

| 地點 | 用途 |
|------|------|
| FolderScanner | 掃描檔案列表 |
| ThumbnailService | 讀取照片產生縮圖 |
| PhotoDetailView | 載入全尺寸影像 |
| PhotoThumbnailView | 顯示縮圖 |
| ImagePreloadCache | 預載相鄰照片 |

---

## 5. 資料夾掃描：FolderScanner

**檔案**：`Services/FolderScanner.swift`

### @ModelActor 架構

```swift
@ModelActor
actor FolderScanner {
    private let batchSize = 100

    /// 安全地 fetch ScannedFolder，避免 model(for:) 對已刪除物件的 assertion failure
    private func fetchFolder(_ id: PersistentIdentifier) -> ScannedFolder? {
        guard let folders = try? modelContext.fetch(FetchDescriptor<ScannedFolder>()) else { return nil }
        return folders.first { $0.persistentModelID == id }
    }
}
```

**重點學習**：
- `actor`：Swift 並發類型，確保同一時間只有一個操作在執行
- `@ModelActor`：自動在背景執行緒建立 SwiftData 的 `ModelContext`
- 參數接受 `PersistentIdentifier`（而不是 Model 物件），因為 Model 物件不能跨 actor 傳遞
- 使用 `fetchFolder()` 而非 `modelContext.model(for:)`，因為後者對已刪除的物件存取屬性時會 crash

### scanFolder — 掃描一層資料夾

```swift
func scanFolder(id: PersistentIdentifier, subPath: String? = nil, clearAll: Bool = false) async throws
```

**流程**：

```
1. fetchFolder(id) 安全取得 ScannedFolder
2. 還原書籤 → 取得資料夾 URL
3. 啟用安全權限
4. 如果 clearAll = true，刪除所有舊 Photo 記錄
5. FileManager.contentsOfDirectory() — 只列舉一級檔案
6. 跳過隱藏檔案（以 . 開頭的）
7. 過濾出圖片和影片檔案（用 UTType 判斷）
8. 每 100 個檔案一批處理：
   ├── 影片 → VideoMetadataService.readMetadata()
   └── 圖片 → EXIFService.readEXIF()
   → 建立 Photo 物件，設定所有 EXIF 欄位
   → modelContext.insert()
9. 配對 Live Photo（找到同名 .MOV 配對）
10. modelContext.save()
```

### listSubfolders — 列出子資料夾

```swift
func listSubfolders(id: PersistentIdentifier, path: String? = nil)
    -> [(name: String, path: String, coverPath: String?, coverDate: Date?)]
```

回傳子資料夾清單，每個附帶一張「封面照片」的路徑和日期。利用 `FolderListCache` 做快取，session 內已掃過的路徑直接回傳快取結果。

### prefetchFolderTree — 預載整個資料夾樹

```swift
func prefetchFolderTree(id: PersistentIdentifier, onProgress: @Sendable @escaping (String) -> Void)
```

啟動時在背景遞迴掃描所有子資料夾結構，填充 `FolderListCache`。掃描進度透過 `StatusBarModel` 顯示在狀態列。

---

## 6. 資料夾快取與監視

### FolderListCache — 子資料夾列表快取

**檔案**：`Services/FolderListCache.swift`

```swift
final class FolderListCache: @unchecked Sendable {
    static let shared = FolderListCache()

    private var memory: [String: [FolderListEntry]] = [:]   // 父路徑 → 子資料夾列表
    private var scannedThisSession: Set<String> = []         // session 內已掃描的路徑
}
```

**雙層架構**：
- **JSON 持久化**：儲存到 `~/Library/Caches/Spectrum/FolderList.json`，跨 session 保留
- **Session 去重**：`scannedThisSession` 追蹤本次 session 已掃描的路徑，避免重複 I/O

**為什麼不用時間戳過期？** 因為 `FolderMonitor` 會監視檔案系統變動。有變動時呼叫 `invalidate(parentPath:)` 清除快取，所以不需要基於時間的失效機制。

### FolderMonitor — FSEvents 監視

**檔案**：`Services/FolderMonitor.swift`

```swift
final class FolderMonitor {
    static let shared = FolderMonitor()
    func startMonitoring(path: String)
}
```

使用 macOS FSEvents API 監視資料夾變動。當偵測到變動時：

```
FSEvents 通知
  → 發送 Notification.Name("FolderMonitorDidChange")
  → PhotoGridView 收到通知
  → FolderListCache.invalidate(parentPath:) 清除快取
  → 觸發重新掃描
```

---

## 7. 網路磁碟區支援

**檔案**：`Services/NetworkVolumeService.swift`

處理 SMB/NFS 等網路磁碟區的特殊需求。

### 核心功能

| 方法 | 用途 |
|------|------|
| `volumeRoot(for:)` | 提取磁碟區根路徑 `/Volumes/xxx` |
| `isVolumeMounted(path:)` | 檢查磁碟區是否已掛載 |
| `ensureMounted(folder:)` | 使用 `remountURL` 嘗試掛載離線磁碟區 |

### 刪除的特殊處理

網路磁碟區可能沒有 Trash 功能。`PhotoGridView` 的刪除邏輯會：
1. 先嘗試 `FileManager.trashItem()` 移到垃圾桶
2. 如果失敗（`NSFeatureUnsupportedError`），改用 `FileManager.removeItem()` 直接刪除

---

## 8. 視圖架構總覽

```
SpectrumApp
  └── WindowGroup
        └── ContentView
              ├── NavigationSplitView
              │     ├── sidebar: SidebarView
              │     │     └── SubfolderSidebarRow（遞迴展開）
              │     │
              │     └── detail:
              │           ├── SearchResultsView（搜尋模式）
              │           │
              │           ├── PhotoDetailView（詳情模式）
              │           │     ├── HDRImageView（圖片）
              │           │     ├── LivePhotoPlayerView（Live Photo）
              │           │     ├── CropOverlayView（裁剪模式）
              │           │     └── VideoPlayerNSView（影片）
              │           │           └── AVFMetalView (Metal 渲染)
              │           │
              │           └── PhotoGridView（網格模式）
              │                 ├── SubfolderTileView（子資料夾磁磚）
              │                 └── PhotoThumbnailView x N
              │
              ├── .inspector: PhotoInfoPanel（EXIF 面板）
              ├── ImportPanelView（匯入面板，浮動）
              └── StatusBar（底部狀態列）
```

### 三種 detail 模式

```
searchText 非空     →  SearchResultsView（搜尋結果）
detailPhoto != nil  →  PhotoDetailView（詳情模式）
detailPhoto == nil  →  PhotoGridView（網格模式）
```

進入詳情：雙擊照片或按 Return
退出詳情：按 Escape 或點擊返回按鈕

---

## 9. ContentView：三欄佈局的中樞

**檔案**：`Views/ContentView.swift`

### SidebarItem 列舉

```swift
enum SidebarItem: Hashable {
    case folder(ScannedFolder)           // 根資料夾
    case subfolder(ScannedFolder, String) // 子資料夾（根資料夾 + 子路徑）
}
```

為什麼 `subfolder` 要帶 `ScannedFolder`？因為需要它的 `bookmarkData` 來存取檔案。子資料夾沒有自己的書籤，共用根資料夾的。

### 狀態管理

```swift
@State private var selectedSidebarItem: SidebarItem?  // 側欄選了什麼
@State private var selectedPhoto: Photo?              // 網格中選了哪張
@State private var detailPhoto: Photo?                // 進入詳情的照片
@State private var showInspector = false              // EXIF 面板
@State private var isPhotoHDR = false                 // 當前照片是否 HDR
@State private var isFullScreen = false               // 全螢幕
@State private var searchText = ""                    // 搜尋文字
@State private var viewModel = LibraryViewModel()     // 時間線邏輯
@State private var preloadCache = ImagePreloadCache() // 預載快取
```

### 搜尋欄

```swift
.searchable(text: $searchText, placement: .toolbar, prompt: "Search photos & folders")
```

當 `searchText` 非空時，detail 區域顯示 `SearchResultsView` 取代正常的網格/詳情。

### 啟動流程

```swift
.task {
    let scanner = FolderScanner(modelContainer: modelContext.container)

    // 1. Delta 掃描所有資料夾
    for folder in allFolders {
        try? await scanner.scanFolder(id: folder.persistentModelID, clearAll: false)
    }

    // 2. 背景預載資料夾樹結構
    let folderIDs = allFolders.map(\.persistentModelID)
    let container = modelContext.container
    Task.detached(priority: .utility) {
        await MainActor.run { StatusBarModel.shared.setGlobal("Indexing folders…") }
        let bgScanner = FolderScanner(modelContainer: container)
        for id in folderIDs {
            await bgScanner.prefetchFolderTree(id: id) { name in
                Task { @MainActor in
                    StatusBarModel.shared.setGlobal("Indexing \(name)…")
                }
            }
        }
        await MainActor.run { StatusBarModel.shared.finishGlobal("Folders indexed") }
    }

    // 3. 啟動 FSEvents 監視
    for folder in allFolders {
        FolderMonitor.shared.startMonitoring(path: folder.path)
    }

    // 4. 恢復上次瀏覽位置
    if selectedSidebarItem == nil, !lastFolderPath.isEmpty { ... }
}
```

---

## 10. SidebarView：側邊欄與資料夾管理

**檔案**：`Views/Sidebar/SidebarView.swift`

### 資料夾列表

```swift
List(selection: $selection) {
    Section("Folders") {
        ForEach(folders) { folder in
            folderRow(folder)
        }
        .onMove(perform: moveFolder)  // 拖拉排序
    }
}
```

`.onMove` 讓使用者可以拖拉重排資料夾順序，`moveFolder` 更新每個 folder 的 `sortOrder`。

### 子資料夾懶載入

```swift
private struct SubfolderSidebarRow: View {
    @State private var children: [(name: String, path: String, ...)] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                label.task { await loadChildren() }  // 首次顯示時載入
            } else if children.isEmpty {
                label                                 // 沒子資料夾
            } else {
                DisclosureGroup {                     // 有子資料夾：可展開
                    ForEach(children, id: \.path) { child in
                        SubfolderSidebarRow(...)       // 遞迴！
                    }
                } label: { label }
            }
        }
    }
}
```

**重點學習**：
- 每個 `SubfolderSidebarRow` 自己負責載入自己的子資料夾
- 使用 `DisclosureGroup` 提供原生的三角箭頭展開/收合
- 遞迴結構：SubfolderSidebarRow 裡面放 SubfolderSidebarRow

### 右鍵選單

包含：Rescan、Show in Finder、Add to Import（匯入面板）、Remove 等。子資料夾的右鍵選單有「Add to Import」選項，可以把該資料夾加入匯入面板。

### 拖放新增資料夾

使用者可以直接從 Finder 拖曳資料夾到側邊欄。`onDrop(of: [.fileURL])` 處理拖放事件。

---

## 11. PhotoGridView：時間線網格

**檔案**：`Views/Grid/PhotoGridView.swift`

### 照片篩選

```swift
private var directPhotos: [Photo] {
    photos.filter { photo in
        let photoDir = URL(fileURLWithPath: photo.filePath)
            .deletingLastPathComponent().path
        return photoDir == currentPath
    }
}
```

只顯示當前路徑下的「一級」照片，排除子資料夾裡的照片。

### 時間線分組

```swift
// LibraryViewModel.swift
func timelineSections(from photos: [Photo]) -> [TimelineSection] {
    let grouped = Dictionary(grouping: photos) { $0.dateTaken.monthYearKey }
    return grouped.map { key, photos in
        TimelineSection(
            id: key,
            label: photos.first!.dateTaken.timelineLabel,
            photos: photos.sorted { $0.dateTaken > $1.dateTaken }
        )
    }
    .sorted { $0.id > $1.id }  // 最新的月份在上面
}
```

### 網格佈局

```swift
LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 2)], spacing: 2) {
    ForEach(section.photos) { photo in
        PhotoThumbnailView(photo: photo, ...)
    }
}
```

- `GridItem(.adaptive(minimum: 150))`：每個格子最小 150pt，自動計算每行幾個
- `spacing: 2`：格子間距 2pt

### 子資料夾磁磚

子資料夾在照片上方顯示為磁磚，顯示封面照片和名稱。點擊可導航進入。

### 刪除操作

```swift
// 先嘗試移到垃圾桶
try FileManager.default.trashItem(at: url, resultingItemURL: nil)
// 如果失敗（如網路磁碟區），直接刪除
catch let e as NSError where e.code == NSFeatureUnsupportedError {
    try FileManager.default.removeItem(at: url)
}
```

### 狀態列動畫

狀態列出現/消失有 0.3 秒的 easeInOut 動畫。

---

## 12. PhotoThumbnailView：縮圖顯示

**檔案**：`Views/Grid/PhotoThumbnailView.swift`

### Aspect Fill 顯示

使用 `.resizable().scaledToFill()` 搭配 `.clipped()` 和 `.contentShape(Rectangle())` 來實現 Aspect Fill。`.contentShape()` 是關鍵——沒有它，`.clipped()` 裁切後的區域仍然會接受點擊事件。

### HDR 縮圖

```swift
iv.preferredImageDynamicRange = .high
```

NSImageView 設定 `.high` 可以讓縮圖也呈現 HDR 效果（如果螢幕支援）。

### 徽章

- `HDR` / `HLG`：HDR 照片
- 影片時長（如 `1:30`）
- Live Photo 標記
- `livephoto` 徽章

### 快取重新載入

```swift
.task(id: photo.filePath + "\(cacheState.generation)") {
    thumbnail = nil
    thumbnail = await ThumbnailService.shared.thumbnail(...)
}
```

`cacheState.generation` 是一個計數器。清除快取時計數器 +1，觸發所有縮圖重新載入。

---

## 13. ThumbnailService：縮圖快取系統

**檔案**：`Services/ThumbnailService.swift`

### 雙層快取架構

```
請求縮圖
  ↓
記憶體快取 (NSCache, 最多 500 個)
  ↓ miss
磁碟快取 (~/Library/Caches/Spectrum/Thumbnails/{SHA256}.heic)
  ↓ miss
產生新縮圖 (CGImageSource / AVAssetImageGenerator)
  ↓
存入磁碟快取 → 存入記憶體快取 → 回傳
```

### 縮圖產生

**圖片**：
```swift
let options: [CFString: Any] = [
    kCGImageSourceThumbnailMaxPixelSize: 300,
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true  // 自動套用 EXIF 旋轉
]
let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
```

**影片**：
```swift
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true  // 套用影片旋轉
let (image, _) = try await generator.image(at: .zero)
```

### LRU 快取淘汰

使用者可以在設定中調整快取大小限制（100 MB ~ 2 GB 或無限制）。超過上限時，按存取日期淘汰最舊的條目。

---

## 14. PhotoDetailView：全尺寸檢視

**檔案**：`Views/Detail/PhotoDetailView.swift`

### 顯示模式

根據檔案類型切換不同的檢視元件：

| 類型 | 元件 | 渲染方式 |
|------|------|----------|
| 普通照片 | HDRImageView | NSImageView |
| HLG 照片 | HDRImageView (CALayer) | CALayer + CGImage 直接渲染 |
| Gain Map 照片 | HDRImageView | NSImageView + .high dynamic range |
| Live Photo | LivePhotoPlayerView | AVPlayer |
| 影片 | VideoPlayerNSView → AVFMetalView | Metal + AVPlayer |

### 縮放功能

```swift
let fitScale = min(
    geometry.size.width / imageSize.width,
    geometry.size.height / imageSize.height
)
let displayWidth = imageSize.width * fitScale * zoomLevel
```

- `zoomLevel = 1.0`：Fit to Window（預設）
- `zoomLevel = 1.0 / fitScale`：Actual Size（1:1 像素）
- 工具列按鈕：Fit、1x、+、-

### HDR 徽章

按下 HDR/HLG 徽章切換 HDR/SDR 顯示。

### 編輯 UI

進入編輯模式後，顯示旋轉按鈕和裁剪框（`CropOverlayView`）。

---

## 15. HDR 渲染

**檔案**：`Services/ImagePreloadCache.swift`

### 簡化的 HDRFormat

```swift
enum HDRFormat: Equatable {
    case gainMap    // badgeLabel: "HDR"
    case hlg        // badgeLabel: "HLG"
}
```

不再使用舊的 protocol-based 架構（`HDRRenderSpec` / `HLGHDRSpec` / `GainMapHDRSpec` 已刪除）。偵測和渲染邏輯整合在 `ImagePreloadCache.loadImageEntry()` 中。

### 偵測方式

| 格式 | 偵測方法 |
|------|----------|
| HLG | `CGColorSpaceUsesITUR_2100TF(colorSpace)` — 檢查色彩空間傳輸函數 |
| Gain Map | `CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)` |

### HLG 渲染

HLG 照片使用 `CALayer` 直接渲染原始 `CGImage`，搭配 `CGColorSpace.itur_2100_HLG` 色彩空間，讓系統硬體做色調映射。不需要 Core Image 管線。

### Gain Map 渲染

Gain Map 照片使用 `NSImageView` 搭配 `preferredImageDynamicRange = .high`，系統自動從 HEIC 輔助資料中提取 Gain Map 並合成 HDR。

### 影片 HDR 類型

```swift
enum VideoHDRType: String, CaseIterable {
    case dolbyVision = "Dolby Vision"
    case hlg = "HLG"
    case hdr10 = "HDR10"
    case slog2 = "S-Log2"
    case slog3 = "S-Log3"
}
```

影片 HDR 偵測在 `ImagePreloadCache.loadVideoEntry()` 中，檢查影片軌道的傳輸函數和 Dolby Vision configuration record。

---

## 16. ImagePreloadCache：預載快取

**檔案**：`Services/ImagePreloadCache.swift`

### 設計目標

使用者按左右鍵瀏覽照片時，預載前後各一張照片，避免每次都從磁碟載入的延遲。

### 架構

```swift
@Observable
@MainActor
final class ImagePreloadCache {
    private var imageCache: [String: CachedImageEntry] = [:]
    private var videoCache: [String: CachedVideoEntry] = [:]
    private var loading: Set<String> = []   // 防止重複載入
}
```

### 預載流程

```
使用者正在看第 5 張照片
  ↓
PhotoDetailView.loadFullImage()
  ├── 檢查 preloadCache.get("photo5") → 有就直接用
  └── 沒有 → 從磁碟載入 → 存入快取
  ↓
preloadAdjacent()
  ├── 取得第 4 張 (prev) 和第 6 張 (next)
  ├── evict：只保留 4, 5, 6，淘汰其他
  ├── 背景載入第 4 張（如果不在快取中）
  └── 背景載入第 6 張（如果不在快取中）
```

### CachedImageEntry

```swift
struct CachedImageEntry: @unchecked Sendable {
    let image: NSImage?
    let hlgCGImage: CGImage?   // HLG 原始 CGImage，給 CALayer 直接渲染
}
```

### 靜態載入方法

```swift
nonisolated static func loadImageEntry(
    path: String, bookmarkData: Data?, screenHeadroom: Float
) async -> CachedImageEntry
```

標記為 `nonisolated` 和 `static`，讓它可以在背景執行緒上運行，不被 `@MainActor` 限制。

---

## 17. 影片播放：AVF Metal 管線

Spectrum 使用 AVFoundation + Metal 自研的影片渲染管線，支援 HDR 色彩管理和 Gyroflow 防手震。

### 架構元件

| 檔案 | 角色 |
|------|------|
| `AVFMetalView.swift` | 核心 Metal 渲染引擎 |
| `MetalShaders.swift` | Metal 著色器（YCbCr→RGB、warp 穩定化） |
| `VideoPlayerNSView.swift` | NSView 橋接器（SwiftUI → NSView） |
| `VideoController.swift` | @Observable 播放狀態 |
| `VideoControlBar.swift` | 浮動播放控制條 |

### AVFMetalView — 渲染引擎

```swift
struct WarpUniforms {
    var videoSize: SIMD2<Float>
    var matCount: Float
    var fIn: SIMD2<Float>       // 焦距
    var cIn: SIMD2<Float>       // 光心
    var distK: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)  // 畸變係數
    var distModel: Int32        // 0/1/3/4/7
    var rLimit: Float
    var frameFov: Float
    var lensCorr: Float
}
```

### 兩階段 Metal 渲染管線

```
CVPixelBuffer (YCbCr 420/422/444)
  ↓ Pass 1: YCbCr → RGBA16Float
  ↓ Metal Fragment Shader (biplanar/triplanar decode)
  ↓
中間紋理 (RGBA16Float)
  ↓ Pass 2: Warp (gyro 穩定化)
  ↓ Metal Fragment Shader (distortion + matrix transform)
  ↓
CAMetalLayer Drawable → 螢幕
```

### CVDisplayLink 同步

```swift
// CVDisplayLink callback dispatches to renderQueue (not real-time thread)
CVDisplayLinkSetOutputCallback(dl, { (_, _, _, _, _, userInfo) -> CVReturn in
    let view = Unmanaged<AVFMetalView>.fromOpaque(userInfo!).takeUnretainedValue()
    view.renderQueue.async { view.renderFrame() }
    return kCVReturnSuccess
}, selfPtr)
```

**重要**：`renderFrame()` 在 `renderQueue` (QoS: `.userInteractive`) 上執行，而非 CVDisplayLink 的 real-time thread。這避免了與 CoreAudio real-time thread 的優先級競爭，防止音效爆音。

### HDR 色彩管理

`CAMetalLayer` 的 `colorspace` 根據影片內容設定：

| 影片類型 | CAMetalLayer colorspace |
|----------|------------------------|
| HLG | `CGColorSpace.itur_2100_HLG` |
| HDR10/PQ | `CGColorSpace.itur_2100_PQ` |
| Dolby Vision P8.4 | 自動偵測，使用 HLG 或 PQ |
| SDR | `CGColorSpace.sRGB` |

### VideoController — 播放狀態

```swift
@Observable
final class VideoController: @unchecked Sendable {
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var renderFPS: Double = 0       // 實測渲染 FPS
    var renderCV: Double = 0        // 幀間隔變異係數
    var renderStability: Double = 1 // 0=抖動, 1=完美穩定
}
```

### pendingPause 延遲狀態

`setPause()` 可能在 AVPlayer 尚未建立時被呼叫（因為 SwiftUI view 建立和 AVPlayer 建立都是非同步的）。透過 `pendingPause` 機制延遲到 player 建立後套用：

```swift
func setPause(_ pause: Bool) {
    guard let player else {
        pendingPause = pause  // 延遲套用
        return
    }
    // ...
}

// load() 完成後
if let pending = self.pendingPause {
    self.pendingPause = nil
    if !pending { newPlayer.play() }
}
```

---

## 18. Gyroflow 防手震整合

Spectrum 整合 Gyroflow 的 C API，在 Metal GPU 上做即時影片穩定化。

### 兩套 C API

| API | 類別 | 特點 |
|-----|------|------|
| `gyrocore_*` | `GyroCore` | 一次計算所有幀（~300ms），適合初始載入 |
| `gyroflow_*` | `GyroFlowCore` | 增量計算（~50ms 重算），適合參數調整 |

### GyroCoreProvider 協定

```swift
protocol GyroCoreProvider {
    func computeMatrices() throws -> [simd_float4x4]
    func recompute(smoothness: Double, fov: Double, ...) throws -> [simd_float4x4]
}
```

`GyroCore` 和 `GyroFlowCore` 都實作這個協定。

### Metal GPU Warp

穩定化矩陣透過 Metal 紋理傳遞給 GPU：

```
gyro matrices (simd_float4x4 陣列)
  ↓ 編碼成 MTLTexture (width=4, RGBA32Float)
  ↓ 傳入 Pass 2 warp shader
  ↓ shader 對每個像素做 distortion + matrix warp
  ↓ 穩定化後的畫面
```

### 支援的鏡頭畸變模型

| distModel | 名稱 |
|-----------|------|
| 0 | OpenCV Standard (k1-k6, p1-p2) |
| 1 | OpenCV Fisheye (k1-k4) |
| 3 | GoPro Superview |
| 4 | Poly3 |
| 7 | Poly5 |

### XMP Sidecar

gyro 參數（smoothness、FOV、lens correction 等）儲存在 XMP 邊車檔案（`.xmp`）中，與影片檔案同目錄。由 `XMPSidecarService` 讀寫。

---

## 19. 非破壞性編輯系統

### EditOp — 編輯操作

**檔案**：`Models/EditOp.swift`

```swift
enum EditOp: Codable, Equatable {
    case crop(CropRect)   // 裁剪
    case rotate(Int)      // 旋轉 (90 或 -90)
    case flipH            // 水平翻轉
}
```

操作以有序列表儲存在 `Photo.editOpsJson` 中，保留完整編輯歷史。

### CompositeEdit — 平面化結果

```swift
struct CompositeEdit {
    let rotation: Int      // 0, 90, 180, 270
    let flipH: Bool
    let crop: CropRect?    // 在旋轉空間中的裁剪

    static func from(_ ops: [EditOp]) -> CompositeEdit
}
```

多次旋轉、翻轉、裁剪的操作列表被平面化成最終的單一變換。裁剪座標會隨旋轉自動轉換（`CropRect.rotated(by:)`）。

### CropRect

**檔案**：`Models/CropRect.swift`

```swift
struct CropRect: Codable, Equatable {
    let x, y, w, h: Double   // 正規化座標 (0.0 ~ 1.0)

    func rotated(by degrees: Int) -> CropRect  // 旋轉時座標轉換
    func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect
}
```

### 渲染管線

編輯效果在兩個地方套用：
1. **PhotoDetailView**：`.rotationEffect()` + frame 調整實現即時預覽
2. **ThumbnailService**：`rotateCGImage()` 在 `CGImageRotation.swift` 中旋轉縮圖

---

## 20. 匯入面板

**檔案**：`Views/Import/ImportPanelView.swift`

### ImportPanelModel

```swift
@Observable @MainActor
final class ImportPanelModel {
    static let shared = ImportPanelModel()
    var sourceURL: URL?            // 來源資料夾
    var items: [ImportItem] = []   // 掃描到的檔案
    var isScanning = false
}
```

### 功能

- 掃描外部資料夾，依 EXIF 日期分組
- 顯示為按日期分組的預覽清單
- 支援拖放到網格（複製/剪切到目標資料夾）
- 子資料夾右鍵選單「Add to Import」自動開啟面板
- 使用 `Task.detached` 非同步掃描，不阻塞 UI

### ImportItem 與 ImportDateGroup

```swift
struct ImportItem: Identifiable {
    let url: URL
    let fileName: String
    let dateTaken: Date
    let isVideo: Bool
}

struct ImportDateGroup: Identifiable {
    let date: String           // "Jan 1, 2025"
    let folderName: String     // "20250101"
    let items: [ImportItem]
}
```

---

## 21. 搜尋功能

**檔案**：`Views/SearchResultsView.swift`

### 功能

- 在 SwiftUI `.searchable()` 工具列搜尋框中輸入文字
- 搜尋 SwiftData 中的 `Photo.fileName`
- 搜尋 `FolderListCache` 中的資料夾名稱（遞迴）
- 最少 2 個字元才開始搜尋
- 照片結果限制 200 筆
- 結果分兩個 section：資料夾和照片

### 導航

- 點擊搜尋結果中的照片 → 導航到該資料夾並開啟 DetailView
- 點擊搜尋結果中的資料夾 → 導航到該資料夾

---

## 22. 狀態列

**檔案**：`Services/StatusBarModel.swift`

### API

```swift
@Observable @MainActor
final class StatusBarModel {
    static let shared = StatusBarModel()

    // 任務進度（確定/不確定）
    func begin(_ label: String)                    // 不確定進度（spinner）
    func begin(_ label: String, total: Int)         // 確定進度（進度條）
    func update(done: Int, label: String?)          // 更新進度
    func finish(_ message: String?)                 // 完成 + 10 秒自動消失

    // 全域背景狀態
    func setGlobal(_ label: String?)                // 設定全域標籤
    func finishGlobal(_ message: String?)           // 完成 + 10 秒自動消失
}
```

### 自動消失

`finish()` 和 `finishGlobal()` 完成後會顯示訊息 10 秒，然後自動消失。內部使用 `Task.sleep(for: .seconds(10))` 實現計時。

### 使用場景

| 場景 | 模式 |
|------|------|
| 資料夾掃描 | 確定進度（N/M 檔案） |
| 複製/貼上/匯入 | 確定進度 |
| 資料夾樹索引 | 不確定進度（全域） |
| 完成訊息 | 顯示 10 秒後消失 |

---

## 23. EXIF 與影片中繼資料

### EXIFService

**檔案**：`Services/EXIFService.swift`

使用 ImageIO 框架讀取 EXIF：

```swift
let source = CGImageSourceCreateWithURL(url as CFURL, nil)
let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
```

回傳的字典結構：
```
props
├── {TIFF}
│   ├── Make: "SONY"
│   └── Model: "ILCE-7M4"
├── {Exif}
│   ├── DateTimeOriginal: "2024:01:15 14:30:00"
│   ├── LensModel: "FE 24-70mm F2.8 GM II"
│   ├── FNumber: 2.8
│   ├── ExposureTime: 0.001  (→ "1/1000")
│   ├── FocalLength: 35.0
│   ├── ISOSpeedRatings: [400]
│   ├── ExposureBiasValue, MeteringMode, Flash, WhiteBalance, ...
│   └── BrightnessValue
└── {GPS}
    ├── Latitude / LatitudeRef
    └── Longitude / LongitudeRef
```

### VideoMetadataService

**檔案**：`Services/VideoMetadataService.swift`

```swift
let asset = AVURLAsset(url: url)
let duration = try await asset.load(.duration)
let tracks = try await asset.loadTracks(withMediaType: .video)
let size = try await track.load(.naturalSize)
let transform = try await track.load(.preferredTransform)
```

影片的 `naturalSize` 不一定是最終尺寸——手機直拍的影片需要套用 `preferredTransform`（90° 旋轉）才是正確尺寸。

---

## 24. PhotoInfoPanel：EXIF 面板

**檔案**：`Views/Detail/PhotoInfoPanel.swift`

在右側 Inspector 中顯示照片的完整 EXIF 資訊，包含：

| 區塊 | 內容 |
|------|------|
| 基本資訊 | 檔名、尺寸、檔案大小 |
| 相機 | 機身、鏡頭、焦距 |
| 曝光 | 光圈、快門、ISO、測光、閃燈 |
| 色彩 | Profile、色深、HDR headroom |
| GPS | 座標、地圖預覽 |
| 影片 | 編碼、解析度、FPS |

---

## 25. 鍵盤導航系統

### 為什麼不用 `.onKeyPress`？

SwiftUI 的 `.onKeyPress` 在 NavigationSplitView 裡常被其他元件（如 List、ScrollView）攔截。macOS 的選單命令 (Menu Commands) 有全域優先權，不受焦點影響。

### 導航流程

```
使用者按下 → 鍵
  ↓
macOS 菜單系統捕獲 keyboardShortcut(.rightArrow)
  ↓
PhotoNavigationCommands.navigateRight()
  ↓
@FocusedValue(\.photoNavigation) 找到當前回應者
  ↓
網格模式：PhotoGridView 移動 selectedPhoto
詳情模式：ContentView 移動 detailPhoto
```

### 網格中的導航計算

```swift
// 計算每行幾個格子
let columnCount = Int((geometry.size.width + 2) / 152)  // 150 + 2 spacing

// ← →：偏移 1
let newIndex = currentIndex + direction

// ↑ ↓：偏移 columnCount（整行跳）
let newIndex = currentIndex + (direction * columnCount)
```

---

## 26. 全螢幕模式

### 進入全螢幕

```swift
private func enterFullScreen() {
    guard let window = NSApp.keyWindow else { return }
    savedColumnVisibility = columnVisibility  // 記住側欄狀態
    isFullScreen = true
    window.toolbar?.isVisible = false         // 隱藏工具列
    window.toggleFullScreen(nil)              // 觸發 macOS 全螢幕動畫
}
```

### 全螢幕佈局

全螢幕模式下：
- 不顯示 NavigationSplitView（沒有側欄）
- 不顯示 Inspector
- 不顯示工具列
- 只有照片 + HDR 徽章

### 退出全螢幕

兩種退出方式：
1. 按 Escape（`onExitCommand`）
2. macOS 視窗的綠色按鈕（`willExitFullScreenNotification`）

---

## 27. 日誌系統

**檔案**：`Services/Log.swift`

使用 Apple 的 `os.Logger` 取代 `print()` 除錯輸出。

```swift
enum Log {
    static let general   = Logger(subsystem: "com.spectrum.app", category: "general")
    static let scanner   = Logger(subsystem: "com.spectrum.app", category: "scanner")
    static let thumbnail = Logger(subsystem: "com.spectrum.app", category: "thumbnail")
    static let bookmark  = Logger(subsystem: "com.spectrum.app", category: "bookmark")
    static let video     = Logger(subsystem: "com.spectrum.app", category: "video")
    static let gyro      = Logger(subsystem: "com.spectrum.app", category: "gyro")
    static let player    = Logger(subsystem: "com.spectrum.app", category: "player")
}
```

### 使用方式

```swift
Log.scanner.info("Scanning folder: \(path, privacy: .public)")
Log.bookmark.warning("Failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
```

### 優點

- 可以在 Console.app 中按 category 過濾
- `privacy: .public` 控制敏感資料的可見性
- 比 `print()` 效能更好（系統級實作）
- Release build 中 `.debug` 級別的訊息不會被記錄

---

## 28. 設定畫面

**檔案**：`Views/SettingsView.swift`

```
Settings
├── Thumbnail Cache Size: [Slider 100MB ~ 2GB | Unlimited]
├── Current Usage: "245.3 MB"
├── [Clear Cache] 按鈕
└── Gyro Method: spectrum / gyroflow
```

### 快取大小控制

拖拉到最右邊時自動切換為 "Unlimited"。

### 清除快取

清除快取後 `ThumbnailCacheState.generation` += 1，觸發所有縮圖重新載入。

---

## 29. Extension 工具

### Date+Formatting

```swift
extension Date {
    var timelineLabel: String   // "January 2024"（用於時間線標題）
    var monthYearKey: String    // "2024-01"（用於分組 key）
    var shortDate: String       // "Jan 15, 2024 2:30 PM"
}

func formatDuration(_ seconds: Double) -> String
// 45    → "0:45"
// 90    → "1:30"
// 3661  → "1:01:01"
```

### URL+ImageTypes

```swift
extension URL {
    var isImageFile: Bool  // UTType conforms to .image
    var isVideoFile: Bool  // UTType conforms to .movie
    var isMediaFile: Bool  // 兩者之一
}
```

使用 `UTType`（Uniform Type Identifier）判斷，比檢查副檔名更可靠。

---

## 30. 完整架構圖

### 資料流

```
使用者操作                    SwiftData                    檔案系統
─────────                    ─────────                    ─────────
Add Folder (NSOpenPanel)
  ↓
BookmarkService.createBookmark()
  ↓
ScannedFolder ──────────────→ 儲存到 SQLite
  ↓
FolderScanner.scanFolder()  ←─────────────────────────→ FileManager 列舉
  ↓                                                       ↑
Photo x N ──────────────────→ 儲存到 SQLite          FolderMonitor
  ↓                                                    (FSEvents 監視)
PhotoGridView ←──────────────── @Query 自動更新
  ↓
ThumbnailService ←────────────────────────────────────→ 讀取圖片，產生 HEIC 快取
  ↓
PhotoThumbnailView（顯示縮圖）
```

### 影片渲染管線

```
AVPlayer
  ↓ copyPixelBuffer(forItemTime:) — 精確 PTS
  ↓
CVPixelBuffer (YCbCr)
  ↓ CVMetalTextureCache
  ↓
Metal Pass 1: YCbCr → RGBA16Float (Fragment Shader)
  ↓
中間紋理
  ↓
[Gyro] → gyrocore/gyroflow C API → simd_float4x4 陣列
  ↓ matTex (MTLTexture, RGBA32Float, width=4)
  ↓
Metal Pass 2: Warp (distortion model + matrix transform)
  ↓
CAMetalLayer Drawable (HLG/PQ/sRGB colorspace)
  ↓
螢幕顯示 (EDR HDR)
```

### 預載時序

```
時間軸 ──────────────────────────────────────────→

照片 3    照片 4    照片 5    照片 6    照片 7
                   [正在看]

Step 1: 載入照片 5（從磁碟或快取）
Step 2: 背景預載照片 4 和照片 6
Step 3: 淘汰照片 3 和照片 7 的快取

使用者按 →

照片 4    照片 5    照片 6    照片 7    照片 8
                   [正在看]

Step 1: 照片 6 已在快取中 → 立即顯示！
Step 2: 背景預載照片 5（已有）和照片 7
Step 3: 淘汰照片 4 的快取
```

---

## 附錄：常見問題

### Q: 為什麼 photo.folder?.bookmarkData 有時候會是 nil？

**A**: SwiftData 使用 lazy loading。`photo.folder` 的關聯物件可能還沒被載入記憶體。解法是在 View 中用 `@Query` 另外查詢所有 `ScannedFolder`，用路徑前綴比對作為 fallback。這個邏輯封裝在 `Photo.resolveBookmarkData(from:)` 中。

### Q: 為什麼鍵盤導航不用 .onKeyPress？

**A**: SwiftUI 的 `.onKeyPress` 在複雜佈局（NavigationSplitView + List + ScrollView）中常被其他元件攔截。改用 macOS Menu Commands 搭配 `@FocusedValue` 橋接，因為選單命令有最高優先權。

### Q: FolderScanner 為什麼要用 PersistentIdentifier 而不是直接傳 Model？

**A**: `FolderScanner` 是一個 `actor`，在背景執行緒上運行。SwiftData 的 Model 物件綁定在特定的 `ModelContext` 上，不能跨執行緒傳遞。`PersistentIdentifier` 是一個可跨執行緒的值型別，actor 收到後可以用自己的 `ModelContext` 重新 fetch。

### Q: 為什麼 FolderScanner 用 fetch 而不是 model(for:) 取得 ScannedFolder？

**A**: `modelContext.model(for: id)` 回傳 non-optional。如果物件已被刪除（例如使用者在背景 prefetch 期間移除了資料夾），存取屬性時會觸發 SwiftData 底層的 assertion failure，導致 app crash。改用 `FetchDescriptor` 的 `fetch()` 方法，物件不存在時回傳空陣列，安全地回傳 `nil`。

### Q: 為什麼影片渲染不在 CVDisplayLink 的 real-time thread 上執行？

**A**: CVDisplayLink callback 預設在 real-time priority thread 上執行。如果 Metal 渲染（含 gyro FFI 計算）也在這個 thread 上，會與 CoreAudio 的 real-time thread 競爭，導致其他應用程式的音效爆音。解法是把 `renderFrame()` dispatch 到 `renderQueue`（QoS: `.userInteractive`），足夠高優先級保證流暢，但不會搶佔 CoreAudio。

### Q: 為什麼影片播放有時需要按兩次 Space？

**A**: SwiftUI view 建立是非同步的，AVPlayer 建立也在 `Task` 中。`togglePlayPause()` → `setPause(false)` 時，`AVPlayer` 可能還沒建立完成。透過 `pendingPause` 機制，延遲到 player 建立後自動套用。
