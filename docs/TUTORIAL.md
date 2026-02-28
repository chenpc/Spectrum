# Spectrum 開發教學手冊

一份從零開始理解 Spectrum 每一行程式碼的教學文件。

---

## 目錄

1. [專案總覽](#1-專案總覽)
2. [App 入口點：SpectrumApp](#2-app-入口點spectrumapp)
3. [資料模型 (SwiftData)](#3-資料模型-swiftdata)
4. [書籤與安全權限](#4-書籤與安全權限)
5. [資料夾掃描：FolderScanner](#5-資料夾掃描folderscanner)
6. [視圖架構總覽](#6-視圖架構總覽)
7. [ContentView：三欄佈局的中樞](#7-contentview三欄佈局的中樞)
8. [SidebarView：側邊欄與資料夾管理](#8-sidebarview側邊欄與資料夾管理)
9. [PhotoGridView：時間線網格](#9-photogridview時間線網格)
10. [PhotoThumbnailView：縮圖顯示](#10-photothumbnailview縮圖顯示)
11. [ThumbnailService：縮圖快取系統](#11-thumbnailservice縮圖快取系統)
12. [PhotoDetailView：全尺寸檢視](#12-photodetailview全尺寸檢視)
13. [HDR 渲染管線](#13-hdr-渲染管線)
14. [HLG HDR 渲染：HLGHDRSpec](#14-hlg-hdr-渲染hlghdrspec)
15. [Apple Gain Map HDR：GainMapHDRSpec](#15-apple-gain-map-hdrgainmaphdrspec)
16. [ImagePreloadCache：預載快取](#16-imagepreloadcache預載快取)
17. [影片支援](#17-影片支援)
18. [EXIF 與影片中繼資料](#18-exif-與影片中繼資料)
19. [PhotoInfoPanel：EXIF 面板](#19-photoinfopanelexif-面板)
20. [鍵盤導航系統](#20-鍵盤導航系統)
21. [全螢幕模式](#21-全螢幕模式)
22. [標籤系統](#22-標籤系統)
23. [設定畫面](#23-設定畫面)
24. [Extension 工具](#24-extension-工具)
25. [完整架構圖](#25-完整架構圖)

---

## 1. 專案總覽

Spectrum 是一個原生 macOS 照片瀏覽器，專門解決 Apple Photos 無法正確顯示 Sony HLG HDR 照片的問題。

### 核心設計原則

- **不複製、不匯入**：直接掃描使用者指定的資料夾，照片保持在原地
- **HDR 優先**：內建 HDR 渲染管線，支援 HLG 和 Apple Gain Map
- **沙盒安全**：使用 macOS security-scoped bookmark 取得永久存取權

### 技術棧

| 技術 | 用途 |
|------|------|
| SwiftUI | 使用者介面 |
| SwiftData | 資料儲存（照片、資料夾、標籤） |
| Core Image | HDR 影像渲染 |
| AVFoundation | 影片播放、HDR 偵測 |
| ImageIO (CGImageSource) | EXIF 讀取、縮圖產生 |
| Security-Scoped Bookmarks | 沙盒存取權限 |

### 目錄結構

```
Spectrum/
├── SpectrumApp.swift          # App 入口點、選單命令
├── ThumbnailCacheState.swift  # 縮圖快取更新通知
├── Models/                    # SwiftData 資料模型
│   ├── Photo.swift
│   ├── ScannedFolder.swift
│   └── Tag.swift
├── ViewModels/
│   └── LibraryViewModel.swift # 時間線分組、照片導航
├── Views/
│   ├── ContentView.swift      # 三欄佈局中樞
│   ├── SettingsView.swift     # 偏好設定
│   ├── Sidebar/
│   │   └── SidebarView.swift  # 側邊欄
│   ├── Grid/
│   │   ├── PhotoGridView.swift
│   │   ├── PhotoThumbnailView.swift
│   │   └── TimelineSectionHeader.swift
│   └── Detail/
│       ├── PhotoDetailView.swift  # 全尺寸、HDR、影片
│       └── PhotoInfoPanel.swift   # EXIF 面板
├── Services/
│   ├── BookmarkService.swift      # 安全權限書籤
│   ├── FolderScanner.swift        # 檔案系統掃描
│   ├── ThumbnailService.swift     # 縮圖產生與快取
│   ├── ImagePreloadCache.swift    # 前後照片預載
│   ├── EXIFService.swift          # EXIF 讀取
│   ├── VideoMetadataService.swift # 影片中繼資料
│   ├── HDRRenderSpec.swift        # HDR 協定 + 共用管線
│   ├── HLGHDRSpec.swift           # Sony HLG 渲染
│   └── GainMapHDRSpec.swift       # Apple Gain Map 渲染
├── Extensions/
│   ├── Date+Formatting.swift      # 日期格式化
│   └── URL+ImageTypes.swift       # 檔案類型判斷
└── Resources/
    └── AppIcon.svg                # 圖示原始檔
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
        Window("Spectrum", id: "main") {
            ContentView()
        }
        .modelContainer(for: [Photo.self, Tag.self, ScannedFolder.self])
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.automatic)

        Settings {
            SettingsView()
        }
    }
}
```

**重點學習**：
- `@main`：標記程式進入點
- `Window("Spectrum", id: "main")`：建立主視窗
- `.modelContainer(for:)`：初始化 SwiftData 容器，告訴系統要管理哪些 Model
- `Settings { SettingsView() }`：macOS 的「偏好設定...」視窗

### 自訂選單命令

```swift
.commands {
    FileCommands(addFolderAction: addFolderAction)
    PhotoNavigationCommands(navigation: navigation)
}
```

Spectrum 定義了兩組選單：

#### FileCommands — 檔案選單

```swift
struct FileCommands: Commands {
    let addFolderAction: (() -> Void)?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder...") {
                addFolderAction?()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}
```

在「File」選單中加入「Add Folder...」（⌘⇧O）。按下後會呼叫 SidebarView 裡的 `addFolder()` 函式。

#### PhotoNavigationCommands — 導航選單

```swift
struct PhotoNavigationCommands: Commands {
    let navigation: PhotoNavigationAction?

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Left")  { navigation?.navigateLeft() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Right") { navigation?.navigateRight() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            // ... ↑ ↓ Return
        }
    }
}
```

這裡的重點是**方向鍵導航不是用 `.onKeyPress`**，而是透過 macOS 選單命令系統。原因是 SwiftUI 的 `.onKeyPress` 在 NavigationSplitView 裡會被其他元件攔截，而選單命令 (Menu Commands) 有最高優先級。

### FocusedValue 橋接

選單命令需要知道「目前哪個 View 在處理導航」，透過 `@FocusedValue` 機制：

```
SpectrumApp 的選單命令
    ↑ 讀取 @FocusedValue(\.photoNavigation)
    |
ContentView / PhotoGridView
    ↓ 設定 .focusedSceneValue(\.photoNavigation, action)
```

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

    // EXIF 快取 — 掃描時一次寫入，避免每次開啟都重讀
    var cameraMake: String?       // "SONY"
    var cameraModel: String?      // "ILCE-7M4"
    var lensModel: String?        // "FE 24-70mm F2.8 GM II"
    var focalLength: Double?      // 35.0
    var aperture: Double?         // 2.8
    var shutterSpeed: String?     // "1/1000"
    var iso: Int?                 // 400
    var latitude: Double?         // 25.0330
    var longitude: Double?        // 121.5654

    // 影片欄位
    var isVideo: Bool = false
    var duration: Double?         // 秒數
    var videoCodec: String?       // "avc1"
    var audioCodec: String?       // "mp4a"

    // 關係
    var folder: ScannedFolder?                              // 所屬資料夾
    @Relationship(inverse: \Tag.photos) var tags: [Tag] = [] // 標籤（多對多）
}
```

**重點學習**：
- `@Model`：SwiftData 巨集，自動讓 class 可以持久化到 SQLite
- `@Attribute(.unique)`：主鍵，用 filePath 確保同一張照片不會重複
- `@Relationship(inverse:)`：SwiftData 的雙向關係，Photo 和 Tag 之間的多對多關係

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
    var dateAdded: Date
    var sortOrder: Int            // 側欄排序

    @Relationship(deleteRule: .cascade)
    var photos: [Photo] = []      // 刪除資料夾時，連帶刪除所有照片
}
```

**重點學習**：
- `.cascade` 刪除規則：當使用者移除一個資料夾時，該資料夾下所有的 Photo 記錄也會自動被刪除
- `sortOrder`：讓使用者可以拖拉重排側邊欄的資料夾順序

### Tag — 標籤

**檔案**：`Models/Tag.swift`

```swift
@Model
final class Tag {
    @Attribute(.unique) var name: String
    var photos: [Photo] = []
}
```

Photo 和 Tag 是多對多關係。一張照片可以有多個標籤，一個標籤可以對應多張照片。

---

## 4. 書籤與安全權限

**檔案**：`Services/BookmarkService.swift`

### 為什麼需要書籤？

macOS 沙盒 App 預設無法存取使用者的檔案系統。當使用者透過 `NSOpenPanel` 選擇資料夾後，App 獲得一次性存取權限，但這個權限會在 App 重啟後失效。

**Security-Scoped Bookmark** 可以把這個權限序列化成 `Data`，儲存在 SwiftData 裡，下次啟動時還原。

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

在使用者選擇資料夾時呼叫，將存取權序列化。

- `.withSecurityScope`：產生可跨程序重啟使用的書籤
- `.securityScopeAllowOnlyReadAccess`：只需要讀取權限

#### 2. resolveBookmark — 還原書籤

```swift
static func resolveBookmark(_ data: Data) throws -> URL {
    var isStale = false
    let url = try URL(resolvingBookmarkData: data,
                      options: .withSecurityScope,
                      relativeTo: nil,
                      bookmarkDataIsStale: &isStale)
    if isStale {
        // 書籤過期了（例如檔案被移動），重新產生
        let newData = try url.bookmarkData(options: [.withSecurityScope, ...])
        // 更新儲存的 bookmarkData...
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
| ImagePreloadCache | 預載相鄰照片 |

---

## 5. 資料夾掃描：FolderScanner

**檔案**：`Services/FolderScanner.swift`

### @ModelActor 架構

```swift
@ModelActor
actor FolderScanner {
    // 自動獲得 modelContainer 和 modelContext
}
```

**重點學習**：
- `actor`：Swift 並發類型，確保同一時間只有一個操作在執行
- `@ModelActor`：自動在背景執行緒建立 SwiftData 的 ModelContext
- 參數接受 `PersistentIdentifier`（而不是 Model 物件），因為 Model 物件不能跨 actor 傳遞

### scanFolder — 掃描一層資料夾

```swift
func scanFolder(id: PersistentIdentifier, subPath: String? = nil, clearAll: Bool = false) async throws
```

**流程**：

```
1. 從 PersistentIdentifier 取得 ScannedFolder
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
9. modelContext.save()
```

**為什麼只掃描一層？**

使用者可能有很深的資料夾結構（例如 `2024/01/旅行/Day1/`）。一次掃全部會很慢。Spectrum 採用「按需掃描」：只有使用者點開某一層資料夾時，才掃描那一層。

### listSubfolders — 列出子資料夾

```swift
func listSubfolders(id: PersistentIdentifier, path: String? = nil)
    -> [(name: String, path: String, coverPath: String?)]
```

回傳子資料夾清單，每個附帶一張「封面照片」的路徑，用來在側邊欄顯示縮圖。

---

## 6. 視圖架構總覽

```
SpectrumApp
  └── Window
        └── ContentView
              ├── NavigationSplitView
              │     ├── sidebar: SidebarView
              │     │     ├── 資料夾列表 (ForEach folders)
              │     │     │     └── SubfolderSidebarRow（遞迴）
              │     │     └── 標籤列表 (ForEach tags)
              │     │
              │     └── detail:
              │           ├── PhotoDetailView（詳情模式）
              │           │     ├── HDRImageView（圖片）
              │           │     └── HDRVideoPlayerView（影片）
              │           │
              │           └── PhotoGridView（網格模式）
              │                 ├── SubfolderTileView（子資料夾磁磚）
              │                 └── PhotoThumbnailView × N
              │
              └── .inspector: PhotoInfoPanel（EXIF 面板）
```

### 兩種模式切換

```
detailPhoto == nil  →  顯示 PhotoGridView（網格）
detailPhoto != nil  →  顯示 PhotoDetailView（詳情）
```

進入詳情：雙擊照片或按 Return
退出詳情：按 Escape 或點擊返回按鈕

---

## 7. ContentView：三欄佈局的中樞

**檔案**：`Views/ContentView.swift`

### SidebarItem 列舉

```swift
enum SidebarItem: Hashable {
    case folder(ScannedFolder)           // 根資料夾
    case subfolder(ScannedFolder, String) // 子資料夾（根資料夾 + 子路徑）
    case tag(Tag)                         // 標籤
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
@State private var viewModel = LibraryViewModel()     // 時間線邏輯
@State private var preloadCache = ImagePreloadCache() // 預載快取
```

### 共用 PhotoDetailView 建構

```swift
private func photoDetail(_ photo: Photo, showInspector: Binding<Bool>) -> some View {
    PhotoDetailView(
        photo: photo,
        showInspector: showInspector,
        isHDR: $isPhotoHDR,
        viewModel: viewModel,
        preloadCache: preloadCache
    )
    .focusedSceneValue(\.photoNavigation, detailNavigation)
}
```

全螢幕和一般模式都用同一個方法建構 PhotoDetailView，差別只在 `showInspector` 的 binding（全螢幕時用 `.constant(false)` 隱藏）。

### 啟動掃描

```swift
.task {
    let scanner = FolderScanner(modelContainer: modelContext.container)
    for folder in allFolders {
        try? await scanner.scanFolder(id: folder.persistentModelID, clearAll: true)
    }
}
```

每次 App 啟動時，清除所有舊的 Photo 紀錄，重新掃描。這確保檔案系統的變動（新增、刪除、移動）能被反映。

---

## 8. SidebarView：側邊欄與資料夾管理

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
    @State private var children: [(name: String, path: String, coverPath: String?)] = []
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

```swift
.contextMenu {
    Button("Rescan") { Task { await rescanFolder(folder) } }
    Button("Show in Finder") {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }
    Divider()
    Button("Remove", role: .destructive) { ... }
}
```

### 拖放新增資料夾

```swift
.onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
    handleDrop(providers)
    return true
}
```

使用者可以直接從 Finder 拖曳資料夾到側邊欄。`dropTargeted` 控制視覺反饋（藍色邊框）。

---

## 9. PhotoGridView：時間線網格

**檔案**：`Views/Grid/PhotoGridView.swift`

### 照片篩選

```swift
private var directPhotos: [Photo] {
    // 取得當前路徑下的「一級」照片
    // 排除子資料夾裡的照片
    photos.filter { photo in
        let photoDir = URL(fileURLWithPath: photo.filePath)
            .deletingLastPathComponent().path
        return photoDir == currentPath
    }
}
```

如果使用者在 `/Photos/2024/` 資料夾，只顯示這一層的照片，不顯示 `/Photos/2024/Trip/` 裡的。

### 時間線分組

```swift
// LibraryViewModel.swift
func timelineSections(from photos: [Photo]) -> [TimelineSection] {
    let grouped = Dictionary(grouping: photos) { $0.dateTaken.monthYearKey }
    return grouped.map { key, photos in
        TimelineSection(
            id: key,                              // "2024-01"
            label: photos.first!.dateTaken.timelineLabel, // "January 2024"
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

### 子資料夾磚

子資料夾在照片上方顯示為磁磚，點擊可導航進入：

```swift
ForEach(subfolders, id: \.path) { sub in
    SubfolderTileView(name: sub.name, coverPath: sub.coverPath, ...)
        .onTapGesture { onNavigateToSubfolder?(sub.path) }
}
```

---

## 10. PhotoThumbnailView：縮圖顯示

**檔案**：`Views/Grid/PhotoThumbnailView.swift`

### Aspect Fill 顯示

為什麼不用 SwiftUI 的 `.scaledToFill()`？因為它跟 `.clipped()` 搭配時，點擊判定 (hit-testing) 會超出裁切範圍。

解法是用 `NSView` 子類別手動計算 Aspect Fill：

```swift
private class AspectFillImageView: NSView {
    override func layout() {
        // 手動計算填滿裁切的 frame
        let scale = max(bounds.width / image.size.width,
                        bounds.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        imageView.frame = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w, height: h
        )
    }
}
```

### HDR 縮圖

```swift
iv.preferredImageDynamicRange = .high
```

NSImageView 設定 `.high` 可以讓縮圖也呈現 HDR 效果（如果螢幕支援）。

### 快取重新載入

```swift
.task(id: photo.filePath + "\(cacheState.generation)") {
    thumbnail = nil
    thumbnail = await ThumbnailService.shared.thumbnail(...)
}
```

`cacheState.generation` 是一個計數器。當使用者在設定中清除快取時，計數器 +1，觸發所有縮圖重新載入。

---

## 11. ThumbnailService：縮圖快取系統

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
    kCGImageSourceCreateThumbnailWithTransform: true  // ← 自動套用 EXIF 旋轉
]
let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
```

`kCGImageSourceCreateThumbnailWithTransform: true` 是關鍵：它會自動套用 EXIF 方向標記。這就是為什麼縮圖的方向總是正確的。

**影片**：
```swift
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true  // ← 套用影片旋轉
let (image, _) = try await generator.image(at: .zero)
```

### LRU 快取淘汰

```swift
func evictIfNeeded() {
    // 按存取日期排序（最舊的先淘汰）
    let sorted = files.sorted {
        $0.accessDate < $1.accessDate
    }
    while totalSize > maxSize {
        FileManager.default.removeItem(at: sorted[i].url)
        totalSize -= sorted[i].size
    }
}
```

使用者可以在設定中調整快取大小限制（100 MB ~ 2 GB 或無限制）。

---

## 12. PhotoDetailView：全尺寸檢視

**檔案**：`Views/Detail/PhotoDetailView.swift`

### NSViewRepresentable 包裝

SwiftUI 原生的 `Image` 不支援 HDR 顯示。必須用 `NSImageView` 搭配 `preferredImageDynamicRange`。

```swift
struct HDRImageView: NSViewRepresentable {
    let image: NSImage
    let dynamicRange: NSImage.DynamicRange  // .standard 或 .high

    func makeNSView(context: Context) -> NSImageView {
        let view = FlexibleImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = image
        nsView.preferredImageDynamicRange = dynamicRange
    }
}
```

`FlexibleImageView` 是一個覆寫了 `intrinsicContentSize` 的 NSImageView，讓它不會對外部佈局施加固有尺寸限制。

### 縮放功能

```swift
let fitScale = min(
    geometry.size.width / imageSize.width,
    geometry.size.height / imageSize.height
)
let displayWidth = imageSize.width * fitScale * zoomLevel
let displayHeight = imageSize.height * fitScale * zoomLevel
```

- `zoomLevel = 1.0`：Fit to Window（預設）
- `zoomLevel = 1.0 / fitScale`：Actual Size（1:1 像素）
- 工具列按鈕：Fit、1x、+、−

### HDR 徽章

```swift
if isHDR {
    Button {
        showHDR.toggle()
        if activeSpec?.needsPrerenderedSDR == true, sdrImage != nil {
            self.image = showHDR ? hdrImage : sdrImage
        }
    } label: {
        hdrBadge
    }
}
```

按下 HDR 徽章切換 HDR/SDR 顯示。不同的 spec 有不同的切換方式：
- **HLG**：需要替換整張影像（`hdrImage` ↔ `sdrImage`），並切換 `dynamicRange`
- **Gain Map**：也需要替換影像，因為 HDR 和 SDR 是分開渲染的

---

## 13. HDR 渲染管線

**檔案**：`Services/HDRRenderSpec.swift`

### HDRRenderSpec 協定

```swift
protocol HDRRenderSpec {
    var badgeLabel: String { get }               // "HLG" 或 "HDR"
    var needsPrerenderedSDR: Bool { get }        // 是否需要預先渲染 SDR 版本
    func detect(source: CGImageSource, url: URL) -> Bool
    func render(url: URL, filePath: String, screenHeadroom: Float) -> (hdr: NSImage?, sdr: NSImage?)
    func dynamicRange(showHDR: Bool) -> NSImage.DynamicRange
}
```

### 偵測順序

```swift
let hdrRenderSpecs: [any HDRRenderSpec] = [
    HLGHDRSpec(),      // 先偵測 HLG
    GainMapHDRSpec()   // 再偵測 Gain Map
]
```

順序很重要！HLG 檢測用的是色彩空間的傳輸函數 (Transfer Function)，Gain Map 檢測用的是輔助資料。如果一張照片同時符合兩者，以先匹配的為準。

### 共用渲染函式

```swift
func renderHDRCIImage(
    _ ciImage: CIImage,
    screenHeadroom: Float,
    saturationBoost: Float = 1.12,
    clipToSDR: Bool
) -> NSImage?
```

所有 HDR spec 共用的 Core Image 管線：

```
原始 CIImage（場景參考 HDR）
  ↓
CIToneMapHeadroom
  targetHeadroom = clipToSDR ? 1.0 : screenHeadroom
  ↓
CIColorControls（飽和度增強 1.12x）
  ↓
CIContext.createCGImage
  clipToSDR → displayP3 + RGBA8（8-bit SDR）
  !clipToSDR → extendedDisplayP3 + RGBAh（16-bit 半精度浮點 HDR）
  ↓
NSImage
```

**關鍵概念**：
- **screenHeadroom**：螢幕能顯示的 EDR 倍數（例如 MacBook Pro XDR 可以到 ~1.8x 日常，~8x 峰值）
- **extendedDisplayP3**：可以容納超過 1.0 的色彩值，用於 HDR
- **RGBAh**：16-bit 半精度浮點格式，精度足夠表示 HDR 亮度
- **CIToneMapHeadroom**：Apple 提供的 HDR → 顯示器色調映射

---

## 14. HLG HDR 渲染：HLGHDRSpec

**檔案**：`Services/HLGHDRSpec.swift`

### 什麼是 HLG？

Hybrid Log-Gamma 是 Sony 相機使用的 HDR 格式。照片的色彩空間是 BT.2020，傳輸函數是 ITU-R BT.2100 HLG。

Apple Photos **不能正確顯示** Sony HLG 照片，因為它沒有正確做色調映射和色域轉換。這是 Spectrum 存在的主要原因。

### 偵測

```swift
func detect(source: CGImageSource, url: URL) -> Bool {
    guard let ciImage = CIImage(contentsOf: url),
          let colorSpace = ciImage.colorSpace else { return false }
    return CGColorSpaceUsesITUR_2100TF(colorSpace)
}
```

檢查影像的色彩空間是否使用 ITU-R 2100 傳輸函數。

### 渲染

```swift
func render(url: URL, filePath: String, screenHeadroom: Float) -> (hdr: NSImage?, sdr: NSImage?) {
    guard var ciImage = CIImage(contentsOf: url) else { return (nil, nil) }

    // 1. 套用 EXIF 旋轉
    if let orientationValue = ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32,
       let orientation = CGImagePropertyOrientation(rawValue: orientationValue) {
        ciImage = ciImage.oriented(orientation)
    }

    // 2. 渲染 HDR 版本（保留高光）
    let hdr = renderHDRCIImage(ciImage, screenHeadroom: screenHeadroom,
                                saturationBoost: 1.12, clipToSDR: false)

    // 3. 渲染 SDR 版本（裁切到標準範圍）
    let sdr = renderHDRCIImage(ciImage, screenHeadroom: screenHeadroom,
                                saturationBoost: 1.12, clipToSDR: true)

    return (hdr, sdr)
}
```

**為什麼飽和度要提高 1.12 倍？**

BT.2020 色域比 Display P3 更大。色域轉換時，某些顏色的飽和度會「縮水」。加 12% 補償這個損失。

### EXIF 旋轉的坑

`CIImage(contentsOf:)` 會讀取 EXIF 方向資訊，但**不會自動套用**。必須手動呼叫：

```swift
ciImage = ciImage.oriented(orientation)
```

而 ThumbnailService 使用的 `CGImageSourceCreateThumbnailAtIndex` 有 `kCGImageSourceCreateThumbnailWithTransform: true` 選項，會自動套用。所以縮圖方向正確但全尺寸影像旋轉，就是這個差異造成的。

---

## 15. Apple Gain Map HDR：GainMapHDRSpec

**檔案**：`Services/GainMapHDRSpec.swift`

### 什麼是 Gain Map？

iPhone 拍攝的 HDR 照片使用 Apple Gain Map 格式。檔案中包含：
1. **SDR 基礎影像**：普通曝光的 8-bit 照片
2. **Gain Map（輔助資料）**：灰度圖，記錄每個像素需要多少「額外亮度」

顯示 HDR 時，公式是：
```
HDR = SDR × (1 + GainMap × (headroom - 1))
```

### 偵測

```swift
func detect(source: CGImageSource, url: URL) -> Bool {
    // 方法 1：檢查是否有 HDR Gain Map 輔助資料
    if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0,
        kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
        return true
    }
    // 方法 2：檢查 EXIF CustomRendered == 3（Apple 標記）
    if let props = ...,
       let customRendered = exif[kCGImagePropertyExifCustomRendered as String] as? Int,
       customRendered == 3 {
        return true
    }
    return false
}
```

### 渲染流程

這是整個 codebase 中最複雜的部分：

```
HEIC 檔案
  ↓
1. 讀取整個檔案到 Data（避免懶 I/O 問題）
  ↓
2. CGImageSource → SDR 基礎影像 (CGImage)
  ↓
3. 轉成 CIImage（SDR base）
  ↓
4. 讀取 EXIF 方向
  ↓
5. 提取 Gain Map 輔助資料
   ├── kCGImageAuxiliaryDataInfoData → 原始灰度像素資料
   ├── kCGImageAuxiliaryDataInfoDataDescription → 寬、高、bytesPerRow
   └── 建構 CIImage (8-bit 灰度)
  ↓
6. 讀取 headroom（耳機音量）
   ├── MakerApple 標籤 33 → 如果存在，用它
   └── fallback → 用螢幕 headroom
  ↓
7. Gain Map 調整大小（可能跟 SDR 不同解析度）
  ↓
8. HDR 合成：
   gainMap × (headroom - 1)                    // 縮放增益
   SDR × scaledGainMap → boost                 // 乘法合成
   SDR + boost → HDR                           // 加法合成
  ↓
9. 套用 EXIF 方向
  ↓
10. 渲染：
    HDR → extendedDisplayP3 + RGBAh（16-bit）
    SDR → displayP3 + RGBA8（8-bit）
```

### 為什麼要先讀整個檔案？

```swift
guard let fileData = try? Data(contentsOf: url) else { return (nil, nil) }
let provider = CGDataProvider(data: fileData as CFData)!
let source = CGImageSourceCreateWithDataProvider(provider, nil)!
```

如果用 `CGImageSourceCreateWithURL`，CGImageSource 會做懶 I/O（需要時才讀取）。但在安全權限書籤的範圍內，離開 `withSecurityScope` 後就失去讀取權限。所以必須一次把整個檔案讀入記憶體。

---

## 16. ImagePreloadCache：預載快取

**檔案**：`Services/ImagePreloadCache.swift`

### 設計目標

使用者按左右鍵瀏覽照片時，如果每次都從磁碟載入 + HDR 渲染，會有明顯延遲。預載快取讓前後各一張照片提前載入。

### 架構

```swift
@Observable
@MainActor
final class ImagePreloadCache {
    private var imageCache: [String: CachedImageEntry] = [:]  // 照片快取
    private var videoCache: [String: CachedVideoEntry] = [:]  // 影片快取
    private var loading: Set<String> = []                      // 防止重複載入
}
```

- `@Observable`：SwiftUI 可以觀察變化
- `@MainActor`：確保在主執行緒上操作（因為 UI 狀態）

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

### 靜態載入方法

```swift
nonisolated static func loadImageEntry(
    path: String, bookmarkData: Data?, screenHeadroom: Float
) async -> CachedImageEntry
```

標記為 `nonisolated` 和 `static`，讓它可以在背景執行緒上運行，不被 `@MainActor` 限制。這是從 `PhotoDetailView.loadFullImage()` 提取出來的共用邏輯，預載和顯示都用同一段程式碼。

---

## 17. 影片支援

### HDR 影片偵測

```swift
// ImagePreloadCache.loadVideoEntry()
if let descriptions = try? await track.load(.formatDescriptions) {
    for desc in descriptions {
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String]
        if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ  // HDR10
           || transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG  // HLG
        {
            isHDR = true
        }
    }
}
```

檢查影片軌道的格式描述中的傳輸函數 (Transfer Function)。PQ 和 HLG 都是 HDR。

### SDR 影片合成

如果影片是 HDR，建立一個 SDR 版本的 `AVVideoComposition`：

```swift
let composition = AVMutableVideoComposition()
composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2      // Rec. 709
composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
```

使用者按下 HDR 徽章時，在 HDR（原始）和 SDR（Rec. 709 轉換）之間切換：

```swift
func applyVideoDynamicRange() {
    if showHDR {
        playerItem.videoComposition = nil         // 原始 HDR
    } else {
        playerItem.videoComposition = sdrComposition  // 強制 Rec. 709
    }
}
```

---

## 18. EXIF 與影片中繼資料

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
│   └── ISOSpeedRatings: [400]
└── {GPS}
    ├── Latitude: 25.033
    ├── LatitudeRef: "N"
    ├── Longitude: 121.565
    └── LongitudeRef: "E"
```

GPS 注意：南半球和西半球的座標需要取負值。

### VideoMetadataService

**檔案**：`Services/VideoMetadataService.swift`

使用 AVFoundation 讀取影片資訊：

```swift
let asset = AVURLAsset(url: url)
let duration = try await asset.load(.duration)
let tracks = try await asset.loadTracks(withMediaType: .video)
let size = try await track.load(.naturalSize)
let transform = try await track.load(.preferredTransform)
```

影片的 `naturalSize` 不一定是最終尺寸——手機直拍的影片需要套用 `preferredTransform`（90° 旋轉）才是正確尺寸。

---

## 19. PhotoInfoPanel：EXIF 面板

**檔案**：`Views/Detail/PhotoInfoPanel.swift`

### 自訂 FlowLayout

標籤使用自訂的換行佈局：

```swift
struct FlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 逐個排列子視圖，超出寬度就換行
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 實際放置每個子視圖的位置
    }
}
```

SwiftUI 內建沒有 Flow Layout，所以必須自己實作 `Layout` 協定。

### 新增標籤

```swift
TextField("Add tag...", text: $newTagName)
    .onSubmit {
        let tag = Tag(name: newTagName)
        modelContext.insert(tag)
        photo.tags.append(tag)
    }
```

如果同名標籤已存在，會重複使用現有的。

---

## 20. 鍵盤導航系統

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

## 21. 全螢幕模式

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

```swift
if isFullScreen, let photo = detailPhoto {
    // 沒有 NavigationSplitView，純粹的照片
    photoDetail(photo, showInspector: .constant(false))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

全螢幕模式下：
- 不顯示 NavigationSplitView（沒有側欄）
- 不顯示 Inspector
- 不顯示工具列
- 只有照片 + HDR 徽章

### 退出全螢幕

兩種退出方式：
1. 按 Escape（`onExitCommand`）
2. macOS 視窗的綠色按鈕（`willExitFullScreenNotification`）

```swift
.onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
    isFullScreen = false
    columnVisibility = savedColumnVisibility  // 恢復側欄
    window.toolbar?.isVisible = true
}
```

---

## 22. 標籤系統

### 資料模型

Photo 和 Tag 之間是多對多關係：

```swift
// Photo.swift
@Relationship(inverse: \Tag.photos) var tags: [Tag] = []

// Tag.swift
var photos: [Photo] = []
```

SwiftData 自動處理中間表。

### 在 PhotoInfoPanel 中管理

```swift
// 新增標籤
photo.tags.append(tag)

// 刪除標籤
photo.tags.removeAll { $0.persistentModelID == tag.persistentModelID }
```

### 在側邊欄中按標籤瀏覽

```swift
case .tag(let tag):
    PhotoGridView(
        viewModel: viewModel,
        selectedPhoto: $selectedPhoto,
        onDoubleClick: { detailPhoto = $0 },
        tagFilter: tag  // 只顯示有此標籤的照片
    )
```

---

## 23. 設定畫面

**檔案**：`Views/SettingsView.swift`

```
⚙️ Settings
├── Thumbnail Cache Size: [Slider 100MB ~ 2GB | Unlimited]
├── Current Usage: "245.3 MB"
└── [Clear Cache] 按鈕
```

### 快取大小控制

```swift
Slider(value: $cacheSize, in: 100...2048, step: 100)
```

拖拉到最右邊時自動切換為 "Unlimited"。

### 清除快取

```swift
Button("Clear Cache") {
    Task {
        await ThumbnailService.shared.clearCache()
        thumbnailCacheState.invalidate()  // generation += 1，觸發所有縮圖重載
    }
}
```

---

## 24. Extension 工具

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

## 25. 完整架構圖

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
  ↓
Photo × N ──────────────────→ 儲存到 SQLite
  ↓
PhotoGridView ←──────────────── @Query 自動更新
  ↓
ThumbnailService ←────────────────────────────────────→ 讀取圖片，產生 HEIC 快取
  ↓
PhotoThumbnailView（顯示縮圖）
```

### HDR 渲染管線

```
使用者雙擊照片
  ↓
PhotoDetailView.loadFullImage()
  ↓
ImagePreloadCache.loadImageEntry()
  ↓
┌──────────────────────────────────────────────────────┐
│ CGImageSourceCreateWithURL(url)                       │
│   ↓                                                   │
│ for spec in hdrRenderSpecs:                          │
│   ├── HLGHDRSpec.detect() → 檢查 ITU-R 2100 TF     │
│   │   └── ✓ → CIImage → oriented → renderHDRCIImage │
│   │         ├── HDR: extendedDisplayP3 + RGBAh       │
│   │         └── SDR: displayP3 + RGBA8               │
│   │                                                   │
│   └── GainMapHDRSpec.detect() → 檢查輔助資料         │
│       └── ✓ → SDR base + GainMap → HDR 合成          │
│             ├── HDR: SDR + GainMap × (headroom-1)    │
│             └── SDR: 原始 SDR base                    │
│                                                       │
│ fallback: NSImage(contentsOfFile:)                    │
└──────────────────────────────────────────────────────┘
  ↓
CachedImageEntry { image, spec, hdrImage, sdrImage }
  ↓
HDRImageView (NSImageView + preferredImageDynamicRange)
  ↓
螢幕顯示（EDR 高動態範圍）
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

### Q: 為什麼某些照片的全尺寸影像旋轉了，但縮圖正常？

**A**: 縮圖使用 `CGImageSourceCreateThumbnailAtIndex` 搭配 `kCGImageSourceCreateThumbnailWithTransform: true`，它會自動套用 EXIF 方向。但全尺寸影像使用 `CIImage(contentsOf:)` 載入，它不會自動套用方向，需要手動呼叫 `ciImage.oriented(orientation)`。

### Q: 為什麼 photo.folder?.bookmarkData 有時候會是 nil？

**A**: SwiftData 使用 lazy loading。`photo.folder` 的關聯物件可能還沒被載入記憶體。解法是在 View 中用 `@Query` 另外查詢所有 `ScannedFolder`，用路徑前綴比對作為 fallback。這個邏輯封裝在 `Photo.resolveBookmarkData(from:)` 中。

### Q: 為什麼鍵盤導航不用 .onKeyPress？

**A**: SwiftUI 的 `.onKeyPress` 在複雜佈局（NavigationSplitView + List + ScrollView）中常被其他元件攔截。改用 macOS Menu Commands 搭配 `@FocusedValue` 橋接，因為選單命令有最高優先權。

### Q: FolderScanner 為什麼要用 PersistentIdentifier 而不是直接傳 Model？

**A**: `FolderScanner` 是一個 `actor`，在背景執行緒上運行。SwiftData 的 Model 物件（如 `ScannedFolder`）綁定在特定的 `ModelContext` 上，不能跨執行緒傳遞。`PersistentIdentifier` 是一個可跨執行緒的值型別，actor 收到後可以用自己的 `ModelContext` 重新 fetch。

### Q: 為什麼 GainMapHDRSpec 要先把整個檔案讀入 Data？

**A**: 如果用 `CGImageSourceCreateWithURL`，CGImageSource 做懶 I/O。但這段程式碼在 `BookmarkService.withSecurityScope` 內執行，離開 scope 後就失去讀取權限。先讀完整個檔案到記憶體，就不受權限 scope 影響。

### Q: 為什麼 HDR 要產生兩張影像（hdr + sdr）？

**A**: 使用者可以按下 HDR 徽章切換檢視。HLG 的 HDR 和 SDR 需要不同的色調映射 (tone mapping)，不能只靠切換 `dynamicRange` 屬性。所以在載入時就預先渲染好兩個版本。
