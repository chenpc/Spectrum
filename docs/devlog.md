# Spectrum 開發日誌

## 2026-06-26 — 大幅提升測試覆蓋率（13.8% → 77.95%）

**類型：** Test

**問題：** app target 的程式碼覆蓋率僅 13.8%，多數 service / model / view 缺乏測試。

**根因／做法：** 三條測試路線並行擴充，新增約 130+ 個測試：
- **Unit（service/model）：** 為 FolderScanner、EXIFService、VideoMetadataService、CGImageRotation、XMPSidecarService、ThumbnailService/Scheduler、StatusBarModel、FolderClipboard、FolderReader、PhotoItem、BookmarkService、FolderMonitor、SpectrumLibrary 等補齊測試（多數達 90%+）。
- **View-render（關鍵手法）：** 用 `NSHostingView` 在快速 unit target 中直接 render SwiftUI view 強制 body 評估，覆蓋 UI 難觸發的條件分支——PhotoInfoPanel（餵入完整 EXIF 的 PhotoItem）、TimelineSectionHeader、HDRImageViews、LivePhotoPlayerView、VideoControlBar、SettingsView、PhotoGridView。
- **E2E/UI：** 深化 Settings、Import、Crop、Search、Inspector、Grid（多選/context menu/Rename/Trash，用 fixtures temp-copy 隔離破壞性操作）、Sidebar（子資料夾 disclosure + Rescan/Remove）、Gyro tab（video → inspector → Gyro → Custom Gyro Config，覆蓋 GyroConfigSection）。
- 為編輯工具列按鈕（crop/rotate/flip/zoom）補上 `accessibilityIdentifier` 以利 XCUITest 定位。

**結果：** app target line coverage 13.8% → **77.95%**（11088/14225）。剩餘缺口集中在測試環境本質上難觸及的程式：GyroCore（需 gyroflow dylib + 真實 gyro 影像資料）、AVFMetalView（Metal GPU 分支）、PhotoGridView 的 drag-drop、NetworkVolumeService（網路磁碟）。

**修改的檔案：** `SpectrumTests/*`（多個新測試檔）、`SpectrumUITests/*`（多個新/強化測試檔 + E2EFixtures/richexif.jpg）、`Spectrum/AccessibilityID.swift`、`Spectrum/Views/Detail/PhotoDetailView.swift`、`Spectrum.xcodeproj/project.pbxproj`

## 2026-06-21 — 加速開啟資料夾（平行讀取 EXIF）

**類型：** Refactor

**問題：** 開啟含大量照片（尤其 HEIC）的資料夾時明顯卡頓。Instruments time profile 顯示 `FolderReader.readExifDate` 佔總取樣 8.3%，遠超其他項目，是單一最大熱點。

**根因／做法：** `readLevel` 用單執行緒序列對每張圖呼叫 `readExifDate`（為了依拍攝日期排序）。HEIC 的 `CGImageSourceCopyPropertiesAtIndex` 會觸發 ColorSync 對 ICC profile 做 MD5（`md5_compress`），單張即昂貴，序列累加導致整個資料夾要等全部讀完才顯示。改用 `DispatchQueue.concurrentPerform` 把 per-file 的 `makeItem`（EXIF + XMP sidecar + 檔案屬性 I/O）平行化，寫入預先配置、以 index 定位的陣列避免共享變數競爭；Live Photo 配對改在併發後從結果收集 companion mov 路徑。`makeItem` 相依的元件（ImageIO、Foundation XMLDocument、DateFormatter 解析）皆併發安全。

**修改的檔案：** `Spectrum/Services/FolderReader.swift`

## 2026-06-21 — Sidebar 子資料夾不顯示 + 多餘 "?" 圖示

**類型：** Bug Fix

**問題：** 新增的資料夾在 sidebar 不展開子資料夾，且資料夾旁出現問號圖示。

**根因／做法：** (1) `loadAllFolderChildren()` 只在 `.task` 執行一次，`Add Folder` 後不會重新查詢新資料夾的子目錄，`folderChildren` 永遠為空使 DisclosureGroup 不出現 → 加 `.onChange(of: folders.map(\.path))` 觸發重新載入。(2) bookmark 解析失敗即標記 `isMissing`（問號圖示），缺少 fallback → 改為 bookmark 失敗時改用 `FileManager.fileExists(atPath:)` 直接檢查路徑，只有路徑也不存在才標 missing。

**修改的檔案：** `Spectrum/Views/Sidebar/SidebarView.swift`

## 2026-06-20 — UI 測試隔離與全套測試修復

**類型：** Feature / Bug Fix

**問題：** UI 測試共用 app 狀態（database + UserDefaults），導致測試間相互污染；多個測試套件因 macOS 15+ API 差異而失敗。

**根因／做法：**
- 新增 `--userdir PATH` 啟動參數（`AppLaunchArgs.swift`），app 將 SpectrumLibrary 和 UserDefaults 全部重導向到 mktemp 建立的隔離目錄，確保每次測試都是完全乾淨的環境。
- `SpectrumUITestBase` 在每個 test 的 `setUp` 用 `UUID` 建立新的 userDir 並傳入 `--userdir`。
- macOS 15+ 相容性修正：SwiftUI `Toggle` 在 Form 中的 accessibility type 從 `.checkBox` 改為 `.switch`；Settings TabView 的 tab 按鈕從 `.radioButton` 改為 `.button`；`Settings` window 不再可靠地命名為 "Settings"，改用 `windows.element(boundBy: 1)` 偵測；`app.windows["Settings"]` 查找改為 window index 法；`openSettings()` 改用 Cmd+, 快捷鍵。
- Import 工具列按鈕改用 accessibility identifier `"toolbar.import"` 查找（button 無文字 label）。
- `testAddFolderViaMenu` 修正：menu item 為 ASCII `...` 而非 Unicode `…`，且需用 `menuBarItems["File"].menuItems[...]` 路徑。

**修改的檔案：** `Spectrum/Services/AppLaunchArgs.swift`, `Spectrum/SpectrumApp.swift`, `SpectrumUITests/SpectrumUITestBase.swift`, `SpectrumUITests/E2EUsabilityTests.swift`, `SpectrumUITests/SettingsUITests.swift`, `SpectrumUITests/AppLaunchTests.swift`, `SpectrumUITests/ImportPanelUITests.swift`, `SpectrumUITests/NavigationUITests.swift`, `SpectrumUITests/SidebarUITests.swift`

**專案：** Spectrum — macOS 原生相片/影片瀏覽器
**技術棧：** SwiftUI + SwiftData + Metal + AVFoundation + Rust (gyroflow-core)
**目標：** 為 Sony 相機設計，正確渲染 HLG HDR，提供即時陀螺儀穩定化，掃描現有資料夾（不複製）

---

## 2026-04-23 — PhotoDetailView Binding 崩潰修復

**類型：** Bug Fix

**問題：** 使用者在 detail view 的 async image load 尚未完成時退出 detail view，app 直接 `EXC_BREAKPOINT` 崩潰。崩潰堆疊：`PhotoDetailView.prefetchAdjacentImages()` ← `Binding.readValue()` ← closure in `ContentView.photoDetail()`。

**根因：** `ContentView.photoDetail()` 的 Binding get 寫成 `detailPhoto!` force-unwrap。使用者退出 detail view 後 `detailPhoto` 變成 nil，但 `loadFullImage()` 內部的 async Task 還在執行，之後呼叫 `prefetchAdjacentImages()` 透過 Binding 讀 `photo.filePath`，force-unwrap nil 直接崩。

**做法：** 新增 `lastDetailPhoto: PhotoItem?` @State 保留最後一次有效 photo，Binding get 改成 `detailPhoto ?? lastDetailPhoto!`；Binding set 同時更新兩者；`.onChange(of: detailPhoto?.filePath)` 同步 lastDetailPhoto。因 `PhotoItem` 是 struct 不符合 `Equatable`，onChange 監聽 `filePath` String 而非 struct 本身。

**修改的檔案：** `Spectrum/Views/ContentView.swift`

---

## 2026-04-23 — Loading Gyro badge 誤顯示修復

**類型：** Bug Fix

**問題：** 播放沒有 gyro data 的影片時，仍會短暫閃現 "Loading Gyro" badge。

**根因：** gyroflow-core Rust 端 `LOAD_PROGRESS` 初始值是 0.0，`gyrocore_load()` 進入時也會 `set_load_progress(0.0)`，所以只要 gyro 載入一啟動 progress 立刻是 0.0。Swift 端若用 `progress >= 0` 判斷會立即為 true，即使影片完全沒有 gyro data 也會顯示 badge（直到解析失敗）。

**做法：** VideoController 新增 `gyroShowLoadingUI` 屬性，polling loop 改成 `if p > 0 { gyroShowLoadingUI = true }`。只有當 gyroflow-core 的 `load_gyro_data()` progress callback 真的被呼叫（代表偵測到 telemetry 正在解析）才會進入 UI 顯示狀態。PhotoDetailView 的 badge 改用 `gyroShowLoadingUI` 而非 `gyroIsLoading`。

**修改的檔案：** `Spectrum/Views/Detail/VideoController.swift`、`Spectrum/Views/Detail/PhotoDetailView.swift`

---

## 2026-04-23 — 相機輔助目錄 skip list

**類型：** Feature

**問題：** Sony XAVC 卡有一堆輔助目錄（`THMBNL`、`SUB`、`TAKE`、`GENERAL`、`DATABASE`、`AVF_INFO`）裡面裝縮圖、代理檔、metadata，scanner 會把這些也當成媒體檔列入，造成 grid 充滿重複低解析縮圖。

**做法：** `URL+ImageTypes.swift` 新增 `isSkippedCameraDirectory` 判斷；`FolderScanner`、`FolderReader`、`ImportPanelModel` enumerator 遇到這些目錄呼叫 `skipDescendants()` 整支跳過。

**修改的檔案：** `Spectrum/Extensions/URL+ImageTypes.swift`、`Spectrum/Services/FolderScanner.swift`、`Spectrum/Services/FolderReader.swift`、`Spectrum/Views/Import/ImportPanelView.swift`

---

## 2026-04-23 — Select All (Cmd+A) 全選支援

**類型：** Feature

**做法：** 新增 `SelectAllActionKey` FocusedValueKey。`PhotoGridView` 的 `selectAll(flatItems:)` 一次把全部 item id 灌進 `selectedItemIds`，並用 `.focusedSceneValue(\.selectAllAction, …)` 暴露。Edit menu 透過 `@FocusedValue` 綁定 `Cmd+A`。

**修改的檔案：** `Spectrum/Views/ContentView.swift`、`Spectrum/Views/Grid/PhotoGridView.swift`、`Spectrum/SpectrumApp.swift`

---

## 2026-04-23 — UI test infrastructure

**類型：** Feature

**做法：** 新增 `SpectrumUITests` target 與 `AccessibilityID.swift` 集中管理 UI element identifier。各關鍵 SwiftUI 元件（sidebar、grid empty state、video control bar、settings tabs、import/full screen buttons）補上 `.accessibilityIdentifier()`。`test.sh` 加上 `-u|--ui` flag 切換 `SpectrumTests` ↔ `SpectrumUITests`。

**修改的檔案：** `Spectrum/AccessibilityID.swift`（新增）、`SpectrumUITests/`（新增）、`Spectrum/Views/ContentView.swift`、`Spectrum/Views/Sidebar/SidebarView.swift`、`Spectrum/Views/Detail/VideoControlBar.swift`、`Spectrum/Views/SettingsView.swift`、`test.sh`、`Spectrum.xcodeproj/project.pbxproj`

---

## 2026-03-27 — Library Folder Exclusive Lock（防止多個 app instance 同時開啟 DB）

**類型：** Feature

**問題：** 兩個 app instance 同時執行時，都會讀寫同一個 SwiftData DB，造成資料損毀風險。

**做法：** 在 `SpectrumLibrary.acquireOrTerminate()` 中，對 `default.store.lock` 呼叫 `flock(fd, LOCK_EX | LOCK_NB)`。若另一個 instance 已持有 lock，顯示 `NSAlert` 後 `NSApp.terminate(nil)`。lock file 的 fd 保存在靜態變數中，確保 process 存活期間持續持有（process 結束時 OS 自動釋放）。

**修改的檔案：** `SpectrumLibrary.swift`、`SpectrumApp.swift`

---

## 2026-03-26 — 記憶體暴增真正根因修復：SwiftData O(n²) inverse array

**類型：** Bug Fix

**問題：** Add folder 時記憶體從正常的數百 MB 暴增至數 GB（才藝課 3575 張 → ~50GB，2014 資料夾 8318 張 → ~13GB），導致系統 swap 暴漲、app 幾乎無法使用。

**根因：** `ScannedFolder` 有一個 inverse relationship array：

```swift
@Relationship(deleteRule: .cascade) var photos: [Photo] = []
```

SwiftData 維護此 inverse array 的方式是：每次執行 `photo.folder = folder`（掃描插入 Photo 時），就對 `folder.photos` 進行**線性搜尋**，確認 Photo 是否已在陣列內。對 N 張照片的資料夾，這是 **O(n²)** 操作。

Profiler 確認 hot path：
```
Photo.folder.setter
  → SwiftData internal
    → Sequence.contains(where:)
      → _NSCoreManagedObjectID.URIRepresentation   ← 每次比對都建立 CFString
```

每次比對建立一個 `_NSCoreManagedObjectID` URIRepresentation CFString，N=8000 張 = 8000×8000/2 ≈ 3200 萬次建立，完全無法被 ARC 及時回收。

**修法：** 移除 `ScannedFolder.photos: [Photo]` inverse array。SwiftData 仍維護 FK（`photo.folder`），但不再需要在 folder 端維護反向陣列。刪除資料夾改由 `FolderScanner.removePhotos(forFolder:)` 手動查詢刪除（原本已實作）。

**結果：**
- 才藝課 3575 張：peak **127 MB**（原本 ~50 GB）
- 2014 資料夾 8318 張：peak **202 MB**（原本 ~13 GB）

**事後檢討：** 在找到真正根因之前，調查過程中引入了多個不必要的複雜度（QLThumbnailGenerator、sips subprocess、CIRAWFilter 路徑等），均已在後續清理還原為最簡單的 `CGImageSourceCreateThumbnailAtIndex` 做法。

**修改的檔案：** `Spectrum/Models/ScannedFolder.swift`（移除 `photos` property）

---

## 2026-03-26 — 縮圖生成改回純 ImageIO（移除 QL / sips / CIRAWFilter）

**類型：** Refactor

**問題：** QLThumbnailGenerator 是調查記憶體問題過程的臨時方案，應改回最直接的 Apple native 做法。

**根因／做法：**
- 移除 `generateViaQL`、`generateViaSips`、`tryEmbeddedRAWThumbnail`、`generateCIRAWThumbnail`、`decodeImageThumbnail`、`decodeEmbeddedRAWThumbnail`、`decodeEXIFOnlyFromURL`
- 改用單一 `generateImageThumbnail`：`CGImageSourceCreateWithURL` + `CGImageSourceCreateThumbnailAtIndex`（`kCGImageSourceCreateThumbnailFromImageIfAbsent: true`）
- 有內嵌縮圖（JPEG / RAW / HEIF 均有）直接取用，不解碼完整像素；無內嵌縮圖才 fallback decode
- 移除 `QuickLookThumbnailing` import 及 `rawSemaphore`；`videoSemaphore` 保留

**修改的檔案：** ThumbnailService.swift

## 2026-03-26 — 縮圖生成改為 CPU/2 並行 workers，進度條即時顯示 0/N

**類型：** Feature / Refactor

**問題：** 縮圖生成為 debug 用途改成 single worker；進度條要從 add folder 開始就顯示 0/0，分母隨掃描即時增長。

**根因／做法：**
- `ThumbnailProgress.addTotal()` 新增：掃描發現檔案時呼叫，讓 `thumbTotal`（分母）即時增長
- `markRunning(total:)` 改為「只增不減」：若 scan 已設分母，scheduler 不縮小它
- `runPass()` 改用 `withTaskGroup` 以 `workerCount = CPU/2` 並行生成縮圖；每張完成即呼叫 `addDone(1)`
- `FolderScanner.scanFolderDeep()` 發現媒體檔後同時呼叫 `addTotal(N)`
- `SidebarProgressBar` 移除 `thumbTotal > 0` 的前置條件，掃描開始就顯示「0 / 0」

**修改的檔案：** ThumbnailScheduler.swift, FolderScanner.swift, SidebarView.swift

## 2026-03-25 — 縮圖生成改用 QLThumbnailGenerator，解決 ImageIO cache 累積

**類型：** Bug Fix

**問題：** Add folder 後台縮圖生成過程中記憶體持續累積至 1-2GB。先前的修復（HEIC→JPEG、helper function）已將 per-photo 持久增長從 13MB 降至 6MB，但生成 200 張仍累積 1.2GB。結束後記憶體會釋放，代表是暫時性峰值。

**根因：** ImageIO per-file metadata cache（ICC profile、JPEG decoder state）在 process 生命週期內累積，每張照片約 6MB，200 張 = 1.2GB。無公開 API 可清除；直到 process idle 後 OS 才會壓縮或回收。

**做法：** 以 `QLThumbnailGenerator`（QuickLookThumbnailing framework）取代原本 `CGImageSourceCreateThumbnailAtIndex` 作為主要路徑：
- 圖片解碼在 `quicklookd` daemon process 執行，ImageIO cache 累積在系統 process 而非本 app。
- 本 process 只收到最終 400px CGImage（IOSurface ~640KB），JPEG encode 後立即釋放，per-photo 記憶體峰值從 20MB 降至 < 1MB。
- Swift 6 Sendable 限制：在 QL callback 內提取 `cgImage`，不跨 actor boundary 傳遞 non-Sendable 的 `QLThumbnailRepresentation`。
- EXIF 改用 `decodeEXIFOnlyFromURL`（只讀 metadata，不觸發 decode pipeline），footprint 遠小於原本的 thumbnail decode。
- QL 失敗（格式不支援、回傳 icon）時 fallback 至原 CGImageSource 路徑（RAW pass1/pass2、non-RAW Task.detached）。
- `debug-test.sh` 新增 `[thumb-ql]` 統計區段。

**修改的檔案：**
- `Spectrum/Services/ThumbnailService.swift`：新增 `generateViaQL`、`decodeEXIFOnlyFromURL`；import `QuickLookThumbnailing`；`generateAndCacheThumbnail` 改以 QL 為主路徑
- `debug-test.sh`：新增 QL 路徑統計分析

---

## 2026-03-25 — 後台縮圖生成記憶體持續成長修復（第二輪）

**類型：** Bug Fix

**問題：** 上一輪修復（跳過 memoryCache）後記憶體仍線性成長，1953 張照片從 137MB 漲至 2500MB（~1.25MB/張），且每批次 flush 後最低值也持續上升，代表持久性保留而非暫時峰值。

**根因（三項）：**
1. **OS page cache 累積**（主因）：`CGImageSourceCreateWithURL` 讀取 NAS 上的原始 JPEG/CR2 時，OS 把檔案內容填入 page cache 並計入 `phys_footprint`。就算設了 `kCGImageSourceShouldCache: false`（控制的是 ImageIO 內部 decode cache，不是 OS page cache），1953 張 × 平均 ~1-2MB 仍持續累積。
2. **後台路徑多餘地讀回 NSImage**：寫完 HEIC 後還用 `NSImage(contentsOf: diskURL)` 讀回，在 `cacheInMemory=false` 時完全無用，額外觸發 OS 對縮圖 HEIC 的 page cache。
3. **無 autoreleasepool**：`Task.detached` 沒有 autoreleasepool，AppKit/ImageIO 的 ObjC 中間物件累積在 thread pool 的 autorelease pool，等到不確定時機才釋放。

**做法：**
- 非 RAW 路徑改用 `Data(contentsOf: url, options: [.uncached])` + `CGImageSourceCreateWithData`，繞開 OS page cache，讀完後 Data 隨即釋放。
- RAW 路徑保留 `CGImageSourceCreateWithURL`（讓 ImageIO 可 seek 只讀 20MB+ CR2 內嵌縮圖的少數 KB，不全檔讀入）。
- 所有生成函數加 `autoreleasepool {}`。
- `cacheInMemory=false` 時，三條生成路徑（非 RAW / 嵌 RAW / CIRAWFilter）均跳過最後的 `NSImage(contentsOf:)` 載回，直接回傳 `(nil, exif, nil)`。
- `generateAndCacheThumbnail` 回傳型別改為 `(NSImage?, EXIFData?, VideoMetadata?)?`（NSImage 變 Optional）。

**修改的檔案：** `Services/ThumbnailService.swift`

---

## 2026-03-25 — 後台縮圖生成記憶體暴增修復

**類型：** Bug Fix

**問題：** Add folder 後台生成縮圖時，記憶體從 68MB 線性成長至 3,900MB+（1924 張 × ~2MB/張）。

**根因：** `ThumbnailScheduler` 呼叫 `ThumbnailService.thumbnail()` 後，每張縮圖都放入 `memoryCache`。這些照片沒有任何一張是 UI 正在瀏覽的，memory cache 完全無用；加上 `imageCost()` 對 lazily-decoded HEIC NSImage 可能回傳 near-zero cost（`cgImage` 為 nil → fallback `size` 未解碼時為 0 → cost=1），導致 `NSCache` 的 `totalCostLimit=150MB` 軟性上限形同虛設，幾乎從不淘汰。

**做法：** 在 `thumbnail()` 加入 `cacheInMemory: Bool = true` 參數。`ThumbnailScheduler` 傳 `false`，後台生成只寫 disk cache，完全不碰 memory cache。UI 主動請求（預設 `true`）行為不變。disk hit 路徑同樣只在 `cacheInMemory` 為 `true` 時才載入 NSImage 並存入 cache。

**修改的檔案：** `Services/ThumbnailService.swift`, `Services/ThumbnailScheduler.swift`

---

## 2026-03-25 — RAW 縮圖 IOSurface 記憶體膨脹修復（最終版）

**類型：** Bug Fix

**問題：** 縮圖生成期間記憶體持續膨脹，主要來源為 IOSurface（Instruments VM Tracker 可見），Add folder 完成後才一次釋放。

**根因／做法：**

透過 Instruments call stack 確認來源：`CGImageSourceCreateThumbnailAtIndex` → `RawCamera` → `CIContext::recursive_render` → `CI::MetalTextureManager::CreateCachedSurface` → `IOSurfaceCreate`。

根本問題：任何呼叫 **CoreImage RawCamera pipeline** 的路徑，都會在 `MetalTextureManager` pool 裡累積 IOSurface 中間層，pool 不釋放就持續增長。`clearCaches()` 也無法真正清空它；只有 **CIContext 物件本身被 ARC 釋放**時，pool 才會一併清空。

**歷程（每次都以為解決但未解決）：**
- `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailFromImageAlways: true`：觸發 RawCamera 全解碼（24MP），16+ 層 recursive_render，IOSurface 大量累積。
- 換 `CIRAWFilter.isDraftModeEnabled = true` + shared context + `clearCaches()`：`clearCaches()` 並不釋放 `MetalTextureManager` pool，問題仍在。
- per-decode `CIContext` + `CIImage(contentsOf:)`：全解析度解碼讓每層 IOSurface 更大，反而更糟。

**正確根因**：不是 context 不釋放，而是根本不需要走 CoreImage pipeline。RAW 檔案內部就有廠商嵌入的 JPEG 預覽縮圖，直接取用即可，完全繞開 RawCamera。

**最終解法：使用 RAW 內嵌 JPEG 預覽**

`kCGImageSourceCreateThumbnailFromImageAlways: false` + `kCGImageSourceCreateThumbnailFromImageIfAbsent: false`：讓 ImageIO 直接解壓 RAW 檔內嵌的 JPEG 預覽，不觸發 RawCamera / CoreImage pipeline，**零 IOSurface 中間層**。

現代相機（Sony ARW、Nikon NEF、Canon CR2/CR3 等）均在 RAW 檔內嵌高品質 JPEG 預覽，400px 縮圖需求完全足夠。

極少數無內嵌縮圖的格式，fallback 到 `CIRAWFilter.isDraftModeEnabled = true` + **per-decode CIContext**（`cacheIntermediates: false`）。per-decode context 在函數結束時由 ARC 釋放，IOSurface pool 隨之清空，不跨 decode 累積。`rawSemaphore(count: 1)` 確保同時只有 1 個 fallback context 存在。

**修改的檔案：**
- `Spectrum/Services/ThumbnailService.swift`：新增 `tryEmbeddedRAWThumbnail`（主路徑）及 `generateCIRAWThumbnail`（fallback），移除 shared `rawCIContext`

---

## 2026-03-25 — 縮圖排程記憶體洩漏：coroutine frame 殘留修復

**類型：** Bug Fix

**問題：** 縮圖生成期間記憶體持續膨脹，直到 add folder 全部結束才釋放。

**根因／做法：**
Swift async 函數的 coroutine frame 會保留所有 `let` local variables 直到函數本身返回（debug build 尤其如此）。`ThumbnailScheduler.run()` 內的 `repeat...while` 迴圈，每一輪產生的大型物件（`scanner`、`writer`、`moreScanner`、`uncached: [UncachedPhotoInfo]`、各 worker 的 `chunk` 陣列）全部殘留在 `run()` 的 coroutine frame 直到整個迴圈結束，無法被 ARC 提早回收。
修法：迴圈 body 抽成獨立 `async func runPass()`，migration 抽成 `runMigration()`。子函數 return 時 coroutine frame 立即銷毀，所有 heavy locals 在每一 pass 結束後即釋放。

**修改的檔案：**
- `Spectrum/Services/ThumbnailScheduler.swift`

---

## 2026-03-25 — 縮圖生成效能優化：影片 semaphore + SubfolderTile 重繪抑制

**類型：** Feature / Bug Fix

**問題：** 縮圖生成時記憶體峰值過高（6 workers 同時跑 AVAssetImageGenerator），加上每批 20 張完成就讓 60+ 個 SubfolderTileView 全部重啟 `.task`。

**根因／做法：**
- 影片縮圖：`ThumbnailService` 新增 `AsyncSemaphore(count: 2)`，限制同時進入 `AVAssetImageGenerator` 的數量，讓其他 worker 等待而非競搶 CoreMedia buffer，減少記憶體峰值（約 ~600MB vs ~1.8GB）。
- SubfolderTileView：`.task(id: "\(coverPath)_\(thumbDone)")` 改為 `.task(id: coverPath)` + `.onChange(of: thumbProgress.thumbDone)` 只對 `coverImage == nil` 的 tile 執行重試，避免封面已載入的 tile 在每批縮圖完成時都重啟 task。移除不再需要的 `lastCheckedCoverPath` 狀態。

**修改的檔案：**
- `Spectrum/Services/ThumbnailService.swift` — AsyncSemaphore 限制影片並行數
- `Spectrum/Views/Grid/PhotoGridView.swift` — SubfolderTileView task id 拆分

---

## 2026-03-24 — 縮圖生成中斷後自動接續（needsThumbnails 旗標）

**類型：** Feature

**問題：** App 在縮圖生成途中被關閉，下次啟動不會自動接續未完成的縮圖生成。

**根因／做法：**
- `ScannedFolder` 新增 `var needsThumbnails: Bool = false`（SwiftData 輕量遷移自動處理）。
- `SidebarView.insertFolderURL` 及 `rescanFolder` 在建立掃描任務前設 `folder.needsThumbnails = true` 並 save。
- `SidebarView.task` 啟動時檢查是否有 `needsThumbnails && !isPendingDeletion` 的資料夾，若有則呼叫 `ThumbnailScheduler.shared.schedule(…, priority: .background)`。
- `FolderScanner.clearNeedsThumbnails()` 清除所有非刪除中資料夾的旗標，由 `ThumbnailScheduler.run()` 在所有 pass 完成且未被取消時呼叫。

**修改的檔案：**
- `Spectrum/Models/ScannedFolder.swift`
- `Spectrum/Views/Sidebar/SidebarView.swift`
- `Spectrum/Services/FolderScanner.swift`
- `Spectrum/Services/ThumbnailScheduler.swift`

---

## 2026-03-24 — 掃描效能改進：單次列舉 + EXIF 移至縮圖時讀取

**類型：** Refactor

**問題：** `scanFolderDeep` 對每個子目錄分別進行 DB 查詢並讀取 EXIF／影片元數據，I/O 操作分散且 Security Scope 反覆開關，掃描大型資料夾很慢。

**根因／做法：**
- `scanFolderDeep` 完全重寫：Security Scope 整個掃描只開一次；刪除舊 Photo 記錄一次完成；改用 `FileManager.enumerator` 遞迴一次性收集所有媒體 URL；插入 Photo 時只用 filesystem 屬性（無 EXIF、無影片元數據），`pixelWidth/Height` 先設 0。
- EXIF（圖片）與 VideoMetadata（影片）改在縮圖生成時讀取：`generateAndCacheThumbnail` 利用已建立的 `CGImageSource` 呼叫 `EXIFService.readEXIF(from:source)`；影片縮圖生成後呼叫 `VideoMetadataService.readMetadata`。
- `ThumbnailService.thumbnail(for:)` 回傳型別從 `NSImage?` 改為 `ThumbnailResult?`（含 `filePath`、`exif`、`videoMeta`）。
- `markThumbnailsReady` 簽名從 `filePaths: [String]` 改為 `items: [ThumbnailResult]`，寫回所有 EXIF／影片元數據欄位，並修正誤標記的 Live Photo（duration ≥ 5s 時取消 `isLivePhotoMov`）。
- `EXIFService` 新增 `readEXIF(from: CGImageSource)` 多載及 `parseProperties` private helper。
- `pairLivePhotos` 中 `duration == nil`（尚未讀取）視為可能的 Live Photo，與 `duration < 5` 並列配對條件。
- `scanFolder` 移除 `clearAll` 參數（深度掃描不再呼叫它）。

**修改的檔案：**
- `Spectrum/Services/EXIFService.swift`
- `Spectrum/Services/ThumbnailService.swift`
- `Spectrum/Services/ThumbnailScheduler.swift`
- `Spectrum/Services/FolderScanner.swift`

---

## 2026-03-24 — 縮圖 Cache 改為 per-folder 子目錄結構

**類型：** Refactor

**問題：** 縮圖 cache 為扁平目錄，移除資料夾時需逐一刪除每個縮圖檔案（O(n) I/O），且無法按資料夾隔離。

**根因／做法：** 將 cache 路徑從 `Thumbnails/<SHA256(filePath)>.heic` 改為 `Thumbnails/<SHA256(folderPath)>/<SHA256(filePath)>.heic`。移除資料夾時直接 `removeItem` 整個子目錄（instant）。新增 `clearCache(forFolderPath:)` 取代舊版 `clearCache(forPaths:)`。`UncachedPhotoInfo` 新增 `folderPath` 欄位，所有 `diskCacheURL`、`loadFromCache`、`hasDiskCache` API 加入 `folderPath` 參數。加入一次性 `migrateToThumbnailCacheV2()` 清除舊快取並重設 `hasThumbnail` flag，由 `ThumbnailScheduler.run()` 在啟動時呼叫。`ThumbnailProgress` 移除 `removingDone`/`removingTotal` 及相關方法，側邊欄進度條改為不確定式 spinner。

**修改的檔案：**
- `Spectrum/Services/ThumbnailService.swift`
- `Spectrum/Services/FolderScanner.swift`
- `Spectrum/Services/ThumbnailScheduler.swift`
- `Spectrum/Views/Sidebar/SidebarView.swift`
- `Spectrum/Views/Grid/PhotoThumbnailView.swift`
- `Spectrum/Views/Grid/PhotoGridView.swift`
- `Spectrum/Views/Detail/PhotoDetailView.swift`
- `Spectrum/Views/SearchResultsView.swift`

---

## 2026-03-24 — 刪除資料夾加速 + FolderListCache 移除 + 進度條修正

**類型：** Refactor / Bug Fix

**問題：** (1) 刪除資料夾速度很慢：`clearCache(forPaths:)` 是 actor 上的同步循序 I/O，數千張照片的縮圖要一個一個刪。(2) `FolderListCache` 是死碼（`setEntries` 從未被呼叫）。(3) 進度條偶爾閃滅：`finish()` 清掉 `isScanning`，且 `schedule()` 到 `markRunning()` 之間有空窗期。

**根因／做法：**
- `clearCache(forPaths:)` 改為 `async`，先在 actor 上清 memory cache，再 `Task.detached(.background)` + `withTaskGroup` 並行刪除所有磁碟縮圖。
- 完全刪除 `FolderListCache.swift`（含 Xcode project 四個 reference）。`listSubfolders()` 改為全 DB-based。
- `ThumbnailProgress` 重新設計為三旗標（`isScanning` / `isScheduled` / `isGenerating`）。`isScheduled` 橋接 `schedule()` 到 `markRunning()` 的空窗，`finish()` 只清 `isGenerating + isScheduled`，不動 `isScanning`。
- 新增 `refreshFolderChildren()` + `onChange(of: allPhotos.count)` 讓子目錄結構在掃描過程中即時更新。
- Batch save 改為 100 筆 OR 5 秒，避免大型資料夾長時間無 UI 更新。
- `generateAndCacheThumbnail` Task.detached priority 從 `.background` 改為 `.utility` 提升 thread pool 配額。

**修改的檔案：**
- `Services/ThumbnailService.swift`：`clearCache(forPaths:)` async + 並行刪除
- `Services/ThumbnailScheduler.swift`：三旗標 `ThumbnailProgress`；`schedule()` dispatch `markScheduled()`
- `Services/FolderScanner.swift`：移除 `onProgress` callback；batch save 加 5s 時間條件
- `Services/FolderListCache.swift`：**刪除**
- `Views/Sidebar/SidebarView.swift`：`SidebarProgressBar`；`refreshFolderChildren()`；`onChange(of: allPhotos.count)`
- `Views/Grid/PhotoGridView.swift`：移除 FolderListCache 引用；`folderChangeToken` 觸發刷新
- `Views/SearchResultsView.swift`：DB-based folder 搜尋取代 FolderListCache
- `Views/ContentView.swift`：`TaskProgressBar` 簡化，縮圖進度移至 sidebar

## 2026-03-23 — 縮圖生成進度顯示

**類型：** Feature

**問題：** ThumbnailScheduler 在背景靜默執行，使用者無法得知縮圖生成進度。

**根因／做法：**
- 新增 `ThumbnailProgress`（`@Observable @MainActor`）追蹤 `isRunning`、`completed`、`total`。
- `ThumbnailScheduler.run()` 在生成開始前呼叫 `start(total:)`，每張完成後呼叫 `increment()`，全部完成後呼叫 `finish()`。
- `SidebarView` 以 `.safeAreaInset(edge: .bottom)` 在 folder 列表底部插入進度條，僅在 `isRunning == true` 時顯示。
- 進度條格式：linear ProgressView + "X/Y" 計數，使用 `.monospacedDigit()` 避免文字跳動。

**修改的檔案：**
- `Services/ThumbnailScheduler.swift`：新增 `ThumbnailProgress` class；`run()` 更新進度
- `Views/Sidebar/SidebarView.swift`：加入 `thumbnailProgressFooter`

## 2026-03-23 — 縮圖生成系統重新設計（DB-first + ThumbnailScheduler）

**類型：** Feature / Refactor

**問題：** 舊的縮圖系統只在使用者「進入資料夾」時才對當前層觸發 prewarm，無法跨層持久化進度，且 app 重啟後不會繼續未完成的縮圖生成。

**根因／做法：**
- 新增 `ThumbnailScheduler`（`@unchecked Sendable` 單例）：每次排程時取消舊 Task，從 DB 查詢所有無 disk cache 的 `Photo`，以 `ProcessInfo.processorCount / 2` 個 worker 並行生成縮圖。
- DB-first 流程：先由 `FolderScanner.scanFolderDeep` 把所有子目錄檔案納入 SwiftData，再由 Scheduler 掃 DB 找出缺少縮圖的項目一次處理。
- 可恢復：只要 Photo 記錄存在而 disk cache 不存在，下次 app 啟動的 `.task` 就會自動繼續。
- 觸發點：(1) Add Folder → `scanFolderDeep` 完成後排程；(2) FSEvents → `scanCurrentLevel` 完成後排程；(3) Rescan 改為 `scanFolderDeep` + 排程；(4) App 啟動 ContentView `.task`。
- Remove bookmark：先同步收集所有 photo 路徑，刪除 folder 後異步清除 memory + disk 縮圖（`ThumbnailService.clearCache(forPaths:)`）。
- 移除舊的 `prewarmLevelThumbnails`、`prewarmThumbnailsCount`、`fetchUncachedCountForLevel` 方法。

**修改的檔案：**
- `Services/ThumbnailScheduler.swift`（新增）
- `Services/FolderScanner.swift`：新增 `allUncachedPhotos()`、`photoPathsForFolder(_:)` 及 `UncachedPhotoInfo` struct；移除廢棄方法
- `Services/ThumbnailService.swift`：新增 `clearCache(forPaths:)`
- `Views/Sidebar/SidebarView.swift`：Add Folder 觸發 deep scan + 排程；Remove 清除縮圖；Rescan 改為 deep scan
- `Views/Grid/PhotoGridView.swift`：`scanCurrentLevel` 末尾改為 `ThumbnailScheduler.shared.schedule`
- `Views/ContentView.swift`：`.task` 觸發 scheduler
- `Spectrum.xcodeproj/project.pbxproj`：加入新檔案

## 2026-03-23 — Gyro Load 進度條顯示

**類型：** Feature

**問題：** Gyro 資料載入耗時數秒，使用者無法知道進度。

**根因／做法：**
1. Rust：`load_gyro_data` 已有 `progress_cb: F` 回呼（每 100ms 回呼一次，值 0.0–1.0）。新增 `static LOAD_PROGRESS: AtomicU64` 儲存 f64 位元，progress callback 更新它；新增 `gyrocore_load_progress() -> f64` C API。-1.0 表示已完成或未在載入中。
2. Swift：`GyroCore.start()` 透過 dlsym 載入 `gyrocore_load_progress`；開始 StatusBar 多工任務（`beginTask`）；啟動 `DispatchSource` timer 每 150ms 呼叫一次 `fnLoadProgress?()`，更新進度條。load 完成（`onReady`/`onError`）或 `stop()` 時取消 timer 並 `finishTask`。所有 `StatusBarModel` 呼叫用 `MainActor.assumeIsolated` 包裝（`start()`/`stop()` 在 main thread）。

**修改的檔案：**
- `gyro-wrapper/src/lib.rs`：新增 `LOAD_PROGRESS: AtomicU64`、`set_load_progress()`、`gyrocore_load_progress()`；progress callback 接線
- `Spectrum/Services/GyroCore.swift`：新增 `FnLoadProgress` 型別、`fnLoadProgress`/`loadProgressTaskID`/`loadProgressTimer` 欄位、`stopProgressTracking()`；`start()`/`stop()` StatusBar 整合

## 2026-03-23 — Gyro Load 可中斷取消（ESC 不再凍結）

**類型：** Bug Fix + Feature

**問題：** 按下 ESC 退出影片時，如果 gyro 資料很大（load 耗時數秒），整個 App 會凍結，直到 Rust `gyrocore_load` 跑完才解除。

**根因／做法：**
1. `GyroCore.stop()` 原本用 `ioQueue.sync {}` 等 loadCore 結束，已改為 `ioQueue.async` 避免阻塞（上次修正）。
2. 但 `gyrocore_load` Rust 函式本身仍需跑完整個 telemetry parse 才真正釋放 ioQueue。
3. 根本解法：在 `gyro-wrapper/src/lib.rs` 中，把原本呼叫 `stab.load_video_file(...)` 改為手動複製該函式的步驟，並把最慢的 `stab.load_gyro_data(...)` 改為使用自訂的 `Arc<AtomicBool>` cancel flag。
4. 新增 `gyrocore_cancel_load()` C API（`LOAD_CANCEL_FLAG` 全域 Mutex）— Swift `stop()` 呼叫後立即送出取消訊號，gyroflow-core 在 telemetry parse 每個 chunk 間會檢查 flag 並提前返回 `Cancelled` 錯誤。
5. Swift `GyroCore.swift` 新增 `FnCancelLoad` 函式指標型別，`start()` 透過 dlsym 載入，`stop()` 先呼叫 `fnCancelLoad?()` 再排入 cleanup。

**修改的檔案：**
- `gyro-wrapper/src/lib.rs`：新增 `LOAD_CANCEL_FLAG`、`acquire_cancel_flag()`、`gyrocore_cancel_load()`；替換 `load_video_file` 為可取消版本
- `Spectrum/Services/GyroCore.swift`：新增 `FnCancelLoad` 型別、`fnCancelLoad` 欄位、dlsym 載入、`stop()` 呼叫

## 2026-03-22 — Status Bar 移至 Sidebar 欄底部

**類型：** Bug Fix / UX

**問題：** Status bar 放在主內容區（VStack 或 overlay）時，任務增減造成主畫面高度變化，影響使用體驗。

**根因／做法：** 將 `statusBarView` 移入 `NavigationSplitView` sidebar column 的 `VStack` 底部。Sidebar 欄寬度固定，高度變化被限制在 sidebar 欄內，完全不影響主內容區。

**修改的檔案：** `ContentView.swift`

---

## 2026-03-22 — Gyro Loading 指示器改善

**類型：** Feature

**問題：** 影片播放前期載入階段（Decode / Buffer / Gyro）只有一個共用小 spinner，Gyro 載入不夠明顯。

**根因／做法：** 將 `videoLoadingBadge` 改為 `VStack`，每個狀態各自一行、各自一個 `ProgressView`。Gyro 載入時使用較大的 `.small` spinner 搭配黃色文字「Loading Gyro」，視覺上明顯區別。

**修改的檔案：** `PhotoDetailView.swift`

---

## 2026-03-22 — Grid 縮圖顯示副檔名 Badge

**類型：** Feature

**問題：** Grid view 無法在縮圖上直接看到檔案格式。

**根因／做法：** 在 `PhotoThumbnailView` 的 ZStack 右下角加上副檔名標籤（9pt monospaced，黑色半透明圓角背景）。

**修改的檔案：** `PhotoThumbnailView.swift`

---

## 2026-03-22 — 影片預覽顯示時長

**類型：** Feature

**問題：** Detail view 的影片預覽縮圖沒有顯示時長。

**根因／做法：** 在預覽縮圖右下角加上時長標籤，讀取 `previewDuration ?? photo.duration`。

**修改的檔案：** `PhotoDetailView.swift`

---

## 2026-03-22 — 影片時長補填（fillMissingDurations）

**類型：** Bug Fix

**問題：** 在加入 `VideoMetadataService` 之前就被掃描的既有影片，`photo.duration` 為 nil，grid 縮圖和 detail view 預覽都無法顯示時長。FolderScanner 的 incremental scan 只處理新檔案，不會更新舊記錄。

**根因／做法：**
- `FolderScanner` 新增 `fillMissingDurations(id:)` 方法：找出 `isVideo && duration == nil` 的記錄，用 folder bookmark 開 security scope，對每支影片 `AVURLAsset.load(.duration)`，批次寫回 DB。
- `ContentView.task` 啟動後以 `.background` 優先級呼叫，不阻塞 UI。
- `PhotoDetailView` 也在 `loadVideo()` 中補填單一影片的 duration（作為 fallback），同時加入 `previewDuration: Double?` state 供即時顯示。

**修改的檔案：** `FolderScanner.swift`, `ContentView.swift`, `PhotoDetailView.swift`

---

## 一、影片引擎完整重寫：MPV → AVFoundation + Metal

### 問題背景

初始版本使用 MPV（開源影片播放器）透過 OpenGL 渲染。MPV 雖然功能強大，但：

- 與 macOS HDR pipeline（CAMetalLayer colorspace）整合困難
- gyroflow-core 的 warp shader 需要在 Metal 層操作，MPV 無法直接接入
- OpenGL 在 macOS 上已被 deprecated，長期維護風險高

### 解法

設計並實作全新的 two-pass Metal pipeline：

**Pass 1：** YCbCr → RGBA16Float
14 種 decode mode，覆蓋 BT.601 / BT.709 / BT.2020 × Video Range / Full Range 的所有組合。

**Pass 2：** Warp shader → CAMetalLayer drawable
支援 5 種鏡頭畸變模型（0/1/3/4/7），由 gyroflow-core 提供每幀變換矩陣。

**CVDisplayLink 排程：** dispatch 到 `.userInteractive` renderQueue，而非 real-time thread。避免 CoreAudio priority inversion 造成音訊卡頓。

**精準 PTS 對齊：** 使用 `copyPixelBuffer(forItemTime:itemTimeForDisplay:)` 取得精確 presentation timestamp，讓 gyro 矩陣與畫面對齊。

### 架構檔案

- `AVFMetalView.swift` — 核心 Metal 渲染引擎
- `MetalShaders.swift` — Metal shader 原始碼
- `VideoPlayerNSView.swift` — NSView wrapper，SwiftUI bridge
- `VideoController.swift` — @Observable 播放狀態 + gyro 生命週期

---

## 二、Gyroflow 陀螺儀穩定化整合

### 問題背景

gyroflow-core 是 Rust 寫的開源陀螺儀穩定化核心。要把它整合進 Swift macOS app，需要：

1. 將 Rust 編譯成 dylib
2. 設計 Swift ↔ Rust 的 C API 橋接層
3. 把每幀的 3×3 變換矩陣傳進 Metal warp shader

### 解法

**Rust wrapper：** `gyro-wrapper/src/lib.rs` 透過 `dlopen/dlsym` 橋接 gyroflow-core，輸出 `gyrocore_*` C API。

**matTex 格式：** width=4 的 RGBA32Float texture，height=videoHeight。每一 row 存放一幀的：3×3 旋轉矩陣 + IBIS + OIS 補償資料。直接上傳 GPU，warp shader 每幀讀取。

**Config 橋接：** `GyroConfig`（Swift）↔ `Config`（Rust）透過 snake_case JSON CodingKeys 序列化。

**非同步載入：** `gyrocore_load` 耗時約 300ms，在 background Task 執行，不阻塞 UI。載入期間抑制渲染（`waitingForGyro` flag），避免未穩定的第一幀閃現。

### GoPro Rolling Shutter Bug

**症狀：** GoPro 影片套用 gyro 後畫面扭曲。

**根因：** gyroflow-core 對所有影片套用 rolling shutter correction，但 GoPro 已在機內處理 RS，重複校正導致過度補償。

**修正：** gyro-wrapper 偵測 `detected_source.starts_with("GoPro")`，若為 GoPro 則清空 `frame_readout_time`，跳過 RS correction。

---

## 三、HDR 渲染架構

### 問題背景

Sony 相機產出多種 HDR 格式，每種渲染方式不同：

- **Gain Map HEIF**（iPhone 互通格式）— Apple 原生支援
- **HLG Still（.HIF）**— Sony PictureProfile=45，10-bit BT.2020
- **HLG 影片**— ARIB STD-B67 transfer function
- **Dolby Vision P8.4**— 特殊 HDR 容器

早期架構用 protocol-based 設計（`HDRRenderSpec`、`GainMapHDRSpec`、`HLGHDRSpec`、`AppleToneMapRender`），過於複雜。

### 解法

**簡化為 enum：** `HDRFormat` 只有 `.gainMap` 和 `.hlg` 兩種。

**圖片渲染：** `NSImageView.preferredImageDynamicRange = .high`，讓 AppKit 原生處理 Gain Map / HLG，不需手動 Core Image pipeline。

**偵測：** `CGImageSourceCopyAuxiliaryDataInfoAtIndex` 找 Gain Map；`CGColorSpaceUsesITUR_2100TF` 判斷 HLG。

**影片 HDR：** CAMetalLayer colorspace 動態切換（HLG/PQ/sRGB）。Dolby Vision P8.4 自動偵測，切換至 AVPlayerLayer 模式。

### Sony HLG HEIF 深度研究

分析 `.HIF` 格式：PictureProfile=45 代表 HLG Still Image 模式，headroom=4.93，10-bit 4:2:2 BT.2020。發現 Sony MakerNote 資料不被 `CGImageSource` 暴露，只有 `exiftool` 可讀取。

---

## 四、非破壞性編輯系統（旋轉 + 裁切）

### 設計目標

編輯不修改原始檔案，所有操作存入 XMP sidecar。旋轉後再裁切的座標系必須正確。

### 實作

**`EditOp` enum：** `.rotate(Int)` 和 `.crop(CropRect)`，以 JSON array 存入 `editOpsJson` 欄位。

**`CompositeEdit.from([EditOp])`：** 將 op list 壓平成最終的 `(rotation, crop?)` — crop 座標在旋轉後的空間中表示。

**`CropRect.rotated(by:)`：** 旋轉 90/180/270° 時正確轉換裁切矩形座標。

**縮圖套用：** `rotateCGImage()` + `flipCGImage()` 在 `PhotoThumbnailView` 的 `displayThumbnail` computed property 即時合成，不存快取（避免舊快取污染）。

**XMP 同步：** `FolderScanner` 掃描時讀取 XMP sidecar，同步回 `Photo.editOpsJson`。

---

## 五、Import Panel

### 功能

從外部磁碟（SD 卡等）將媒體匯入本機資料夾。支援：

- 掃描外部資料夾，按 EXIF 拍攝日期分群
- Drag / Copy / Cut 群組到 grid 中的目標資料夾
- Grid subfolder context menu 「Add to Import」自動開啟面板
- 非同步掃描（`Task.detached`）不阻塞 UI

### Security Scope Bug — 磁碟無法 Unmount

**症狀：** import 完成後，source 磁碟無法從 Finder unmount。

**根因：** `selectFolder()` 呼叫了 `url.startAccessingSecurityScopedResource()`，但整個 panel session 期間都沒有呼叫對應的 `stopAccessingSecurityScopedResource()`。macOS 持有 security scope 時，磁碟 unmount 會被阻擋。

**修正：** scope 在使用前 acquire，使用後立即 release。`scanFolder()` 中 scope 包住 `Task.detached` 的整個生命週期後立即釋放；`openFolder()` 和 `close()` 移除所有 scope 呼叫。

---

## 六、多任務 Status Bar

### 問題背景

原本 `StatusBarModel` 是 single-task 設計（一次只能顯示一個進度）。當同時進行 scan + copy 時，後啟動的任務會覆蓋前一個的進度顯示。

### 解法

重寫為 UUID-keyed multi-task 架構：

```swift
struct ActiveTask: Identifiable {
    let id: UUID
    var label: String
    var done: Int
    var total: Int
}
private(set) var activeTasks: [ActiveTask] = []
```

API：`beginTask(_:total:) -> UUID` / `updateTask(_:done:)` / `finishTask(_:message:)`

多個 scan 和 copy 任務可同時在 status bar 堆疊顯示，各自獨立進度條。

### Scan 任務卡住 Bug

**症狀：** 掃描完成後，status bar 的 scan 進度項目永遠不消失。

**偵錯過程：**
在 `scanCurrentLevel()` 的每個 return path 加上 `Log.debug`，觀察 task ID 的 begin/finish 配對。

**根因：** `scanCurrentLevel()` 有兩個 `guard !Task.isCancelled else { ...; return }` 路徑，沒有呼叫 `finishTask(taskId)`。舊的 single-task 版本用 `finish()` 覆蓋沒問題，但新的 multi-task 版本每個 `beginTask` 都產生獨立的 UUID — 漏掉的 `finishTask` 導致那筆 ActiveTask 永遠留在 array 中。

**修正：** 在每個 return path 補上 `statusBar.finishTask(taskId)`。

---

## 七、Status Bar 位置調整

### 問題

Status bar 顯示在主畫面底部時，高度變化（任務增減）會影響主內容區域的視覺穩定性，使用者感受不佳。

### 三輪迭代

**第一輪：VStack append**
將 status bar 加在 `PhotoGridView` 的 VStack 底部。問題：每次 task 出現/消失，整個視窗高度改變。

**第二輪：`.overlay(alignment: .bottom)`**
改用 overlay，理論上不影響 layout。用戶回饋：「還是會影響」。

**第三輪：放入 sidebar 欄內**
將 status bar 放入 `NavigationSplitView` sidebar column 底部的 VStack。sidebar 寬度固定，高度變化被限制在 sidebar 欄，完全不影響主內容區域。

### 結論

這個問題每輪都需要用戶用眼睛確認效果，無法由 AI 自動驗證。是典型的「GUI 評估阻礙循環」案例。

---

## 八、影片切換延遲分析與 Deferred Loading

### 問題

在 detail view 左右切換到影片時，畫面明顯卡頓。

### 分析

原始流程：切換 photo → `onChange(of: photo)` → 立即觸發：
1. `AVAssetImageGenerator` 擷取 poster frame（慢，需解碼影片）
2. gyro config 讀取
3. `startGyroStab()` 載入 gyroflow-core（~300ms）
4. HDR type 偵測

以上全部在用戶還沒按 play 前就執行，導致切換卡頓。

### 解法：Deferred Loading

`loadVideo()` 精簡為只做：
1. 重置狀態
2. 從 `ThumbnailService` 讀取已快取縮圖作為 placeholder（幾乎零延遲）
3. 安裝 key monitor

所有 heavy work（gyro 載入、HDR 偵測、AVPlayer 建立）延遲到用戶按下 play 後的 `startPlayback()` 才執行。

---

## 九、影片播放 Loading 進度指示

### 需求

播放影片的前期有多個載入階段，用戶不知道系統在做什麼，觀感不佳。

### 實作

在 detail view 左上角顯示 `videoLoadingBadge`：

- **Decode** — AVFMetalView 正在執行 `analyzeVideo()`（偵測 HDR 格式、decode mode）
- **Buffer** — AVPlayer 已建立但 `readyToPlay` 尚未觸發
- **Gyro** — gyroflow-core 正在背景載入

三個 flag 分別由 `AVFMetalView` 的 `isAnalyzing` / `isBuffering` 和 `VideoController` 的 `gyroIsLoading` 控制，透過 4Hz polling 更新到 UI。

---

## 十、FolderListCache 封面路徑失效 Bug

### 症狀

刪除資料夾後，舊的封面圖路徑殘留在 cache，導致 SubfolderTileView 顯示空白卡片或錯誤封面，且不會自動重新掃描。

### 根因

`FolderListCache` 的 early-return 條件過於寬鬆，只檢查 `isSessionScanned && cachedEntries != nil`，沒有驗證封面路徑是否仍然有效。

### 修正

Early-return 需三個條件同時滿足：
1. `isSessionScanned`
2. `cachedEntries != nil`
3. `allHaveCovers` — 用 `FileManager.fileExists` 驗證所有封面路徑

另外，`SubfolderTileView` 的 `.task(id: coverPath)` 確保 coverPath 變更時重新載入；新增 `onCoverFailed` 回呼，觸發 `FolderListCache.invalidate()` 重新掃描。

---

## 十一、SwiftData Lazy Relationship Bookmark 問題

### 症狀

`ThumbnailService`、`PhotoDetailView` 等需要 security-scoped bookmark 的地方，有時會拿到 nil，導致圖片無法載入。

### 根因

SwiftData lazy relationship：`photo.folder?.bookmarkData` 在部分情境下（跨 actor 存取、context 尚未 fault in）回傳 nil，即使資料實際存在。

### 解法

統一模式：`photo.resolveBookmarkData(from: folders)`，其中 `folders` 來自 `@Query`。如果 `photo.folder?.bookmarkData` 為 nil，則用 photo 的 `filePath` 做路徑前綴比對，從 `@Query` 結果中找到對應的 `ScannedFolder`，再讀取其 `bookmarkData`。

---

## 十二、鍵盤導航架構

### 問題

在 `NavigationSplitView` 中使用 `.onKeyPress` 無法正確攔截方向鍵，事件被 split view 自己消費。

### 解法

改用 `@FocusedValue` + menu commands 架構：

1. 定義 `PhotoNavigationKey: FocusedValueKey`
2. 在 `PhotoGridView` 用 `.focusedSceneValue(\.photoNavigation, action)` 發布導航 action
3. 在 `AppMenuCommands` 綁定 `KeyboardShortcut`，呼叫 `FocusedValue` 中的 closure

這個架構讓鍵盤事件走 menu command 路徑，不受 split view 攔截。

---

## 十三、Hit-testing 修正（`.contentShape()` + `.clipped()`）

### 症狀

`.scaledToFill()` 的圖片超出邊界被 `.clipped()` 截斷後，點擊超出原始 frame 的區域沒有回應。

### 根因

`.clipped()` 只做視覺裁切，不影響 hit-test 區域。SwiftUI 的 hit-test 仍用圖片的原始（未縮放）frame 計算。

### 修正

在 `.clipped()` 後加上 `.contentShape(RoundedRectangle(cornerRadius: 4))`，明確指定 hit-test 形狀為裁切後的外框。

---

## 十四、Log 系統設計

### 設計目標

提供分類、可動態切換等級的 log 系統，讓 debug 時有據可查，release build 自動靜默。

### 實作

**8 個 categories：** general, scanner, thumbnail, bookmark, video, gyro, player, network。

**`AppLogLevel` enum：** debug=0, info=1, error=2。預設：debug build 為 debug，release 為 error。

**`Log.debug()` / `Log.info()`：** 使用 `@autoclosure`，等級不足時連 string interpolation 都不執行，zero overhead。

**Settings 即時切換：** UserDefaults key `appLogLevel`，Settings → General → Developer section 可在不重啟 app 的情況下切換等級。

### 實際效用

Log 系統在後續多個 bug debug 中發揮關鍵作用（scan stuck、gyro 載入失敗、bookmark 解析等），是投資報酬率最高的基礎建設之一。

---

## 十五、SourceKit 誤報的處理方式

### 症狀

IDE（Xcode / SourceKit）顯示大量錯誤：「Cannot find type 'ScannedFolder' in scope」、「Cannot find 'StatusBarModel' in scope」等，有時多達 20+ 條。

### 問題

這些錯誤是 SourceKit 跨檔案 type resolution 的暫時性問題，不是真正的 compile error。但如果不分辨，很容易被這些假錯誤誤導，浪費時間修正不存在的問題。

### 解法

永遠用 `xcodebuild`（或 `./build.sh`）的輸出作為唯一可信的 build 評估依據。SourceKit 報錯 → 跑 build → `BUILD SUCCEEDED` → 判定為誤報，繼續工作。

### 啟示

這是「建立可信的自動評估工具」的典型案例。IDE 的視覺錯誤標示不是可靠的評估依據；build tool 的 exit code 才是。

---

## 十六、Grid 縮圖副檔名 Badge

### 需求

用戶希望在 grid view 的縮圖上直接看到檔案格式（JPEG、MP4、HIF、ARW 等），不需要點進 detail view。

### 實作

在 `PhotoThumbnailView` 的 ZStack 中，右下角加上副檔名標籤：

- 字體：9pt monospaced semibold
- 背景：`black.opacity(0.55)` + `RoundedRectangle(cornerRadius: 3)`
- 文字：`URL.pathExtension.uppercased()`

邏輯簡單，沒有 edge case，幾分鐘內完成。

---

## 十七、Sony Gamma Curve 研究

### 背景

Sony 相機有多種 Picture Profile（PP），每種對應不同的 gamma curve，macOS 不原生支援大部分格式。

### 調查結果

- **HLG（PP 32-35）：** `CGColorSpace.itur_2100_HLG` 可用，macOS 原生支援
- **S-Log3（PP 31）：** 無對應 `CGColorSpace`，需手動 EOTF via CIColorCube LUT
- **S-Log2（PP 28）：** 同上
- **容器 mislabel：** HLG/S-Log3 PP 的影片檔案被標記為 BT.709/sRGB（只有 HLG Still PP=45 標記正確）

這意味著單靠 container metadata 無法區分 HLG 和 S-Log3，需要讀取 Sony MakerNote。

---

## 總結

| 類別 | 項目數 |
|---|---|
| 架構重寫/設計 | 4（影片引擎、gyro、HDR、編輯系統）|
| Bug 修正（靠 log/靜態分析）| 5（scan stuck、unmount、FolderListCache、GoPro RS、SwiftData bookmark）|
| UX 改善 | 4（loading badge、副檔名、deferred loading、status bar 多任務）|
| 基礎建設 | 3（log 系統、import panel、status bar 架構）|
| Layout/互動修正 | 3（hit-testing、鍵盤導航、status bar 位置）|
| 研究/調查 | 2（Sony HLG HEIF、Sony Gamma Curve）|

---

*此日誌由開發過程中與 Claude Code 協作的記錄整理而成。*

## 2026-03-25 — 縮圖記憶體洩漏診斷與修復（HEIC→JPEG + helper function 架構）

**類型：** Bug Fix

**問題：** 初始縮圖生成時 phys_footprint 每張照片增加 13-20MB，1924 張照片預估 25GB+ 峰值，導致 OOM 風險。

**根因／做法：**

經過三輪自動化 debug 測試（`debug-test.sh` + `--log-stdout` + per-step 記憶體追蹤）確認兩個根因：

1. **HEIC VideoToolbox Metal resource pool 洩漏**：`CGImageDestinationFinalize` 搭配 `public.heic` 時，VideoToolbox 在 process-global Metal resource pool 累積 ~7-8MB，`autoreleasepool` 無法回收。改用 `public.jpeg`（CPU-based ImageIO encoder）完全消除此洩漏。

2. **Swift debug build closure 變數生命週期延長**：`autoreleasepool { }` closure 內的局部變數（`rawData` 5-10MB、`source` 5MB、`cgImage` decode temp 15MB）在 debug build 中生命週期延長到外層函式結束，而非 closure return 時立即釋放，導致每張照片 pool drain 後仍殘留 ~20MB。解法：將 CGImageSource 的建立和使用移至獨立 helper function（`decodeImageThumbnail`、`decodeEmbeddedRAWThumbnail`），利用函式 return 即為 stack frame 銷毀點，強制 ARC 立即釋放。

修復後：per-photo in-pool 工作記憶體從 20MB → 4.8MB（2.2x 改善）。

剩餘 ~4-5MB per photo 為 ImageIO process-global 每檔元資料快取（色彩空間、ICC profile、JPEG 解碼器狀態），無 public API 可清除。這是 **one-time 成本**：首次掃描後縮圖已存入 disk cache，後續啟動不再重新生成。

**修改的檔案：**
- `Spectrum/Services/ThumbnailService.swift`：新增 `decodeImageThumbnail` / `decodeEmbeddedRAWThumbnail` helper functions；所有 encode 路徑改為 `public.jpeg`；disk cache 副檔名改為 `.jpg`
- `Spectrum/Services/AppLaunchArgs.swift`（新增）：解析 `--spectrum-library`、`--add-folder`、`--log-stdout`
- `Spectrum/Services/Log.swift`：`--log-stdout` 支援
- `Spectrum/SpectrumApp.swift`：init 時套用 CLI 參數
- `Spectrum/Views/Sidebar/SidebarView.swift`：`--add-folder` 自動觸發
- `debug-test.sh`（新增）：自動化建置→啟動→等待→分析 log 的 debug 腳本

## 2026-07-02 — 垃圾桶 fallback 永久刪除修復 + 預載快取強化

**類型：** Bug Fix

**問題：** (1) 照片／資料夾「Move to Trash」在 `trashItem` 失敗時（常見於不支援垃圾桶的網路磁碟區）會靜默 fallback 到 `removeItem` 永久刪除，與確認對話框「移到垃圾桶」的承諾不符，資料夾情況更是遞迴刪除。(2) ImagePreloadCache 擴大到 13 張全解析度影像後，缺少記憶體壓力釋放與 in-flight 去重，快速翻頁時同一張圖會被重複解碼。

**根因／做法：**

1. **Trash fallback**：移除 `performTrash` / `performTrashSubfolder` 的靜默 `removeItem` fallback。`trashItem` 失敗的項目改為累積到 `permanentDeleteItems` / `permanentDeleteFolders`，跳出獨立的「Delete Permanently?」confirmationDialog，使用者明確確認後才由 `performPermanentDelete` 執行永久刪除（含 security scope 處理與錯誤回報）。多選刪除時失敗項目會累積成一次確認。

2. **ImagePreloadCache**：
   - 新增 `inFlight: [String: Task<CachedImageEntry, Never>]`——並發呼叫 `loadImageEntry` 同一路徑時，後到者 await 同一個 task，不重複解碼；`prefetch` 也檢查 in-flight。
   - 新增 `DispatchSourceMemoryPressure`（warning/critical）→ `clearCache()`。全解析度快取（61MP 檔最壞單張 ~240MB × 13）在記憶體受壓時全數釋放，與 ThumbnailService 行為一致。
   - `prefetchAdjacentImages` 的 ±5 預取順序改為由近到遠（1, -1, 2, -2, …），最近的鄰居優先取得解碼資源。

3. **測試**：`ImagePreloadCacheTests` 的 LRU 測試原本把上限寫死為 5，改為引用 `ImagePreloadCache.maxCacheSize`（現為 13）；新增 `testClearCache_removesAllEntries` 與 `testLoadImageEntry_concurrentCallsShareSingleLoad`（用 `async let` 驗證並發載入共享同一個 NSImage 實例）。

**修改的檔案：**
- `Spectrum/Views/Grid/PhotoGridView.swift`：trash fallback 改為確認制永久刪除；新增 `performPermanentDelete` / `removeItemFromLocalState` / `clearSubfolderSelection`
- `Spectrum/Services/ImagePreloadCache.swift`：in-flight 去重、memory pressure 釋放、`clearCache()`、`maxCacheSize` 改為 internal
- `Spectrum/Views/Detail/PhotoDetailView.swift`：預取順序由近到遠
- `SpectrumTests/ImagePreloadCacheTests.swift`：LRU 測試 size-agnostic + 2 個新測試

## 2026-07-13 — 返回 grid view 慢：移除 grid 路徑的逐檔 EXIF 讀取

**類型：** Bug Fix / Performance

**問題：** 從 detail view 返回 grid view 要等十幾秒（Instruments trace 顯示 t=25–37s 全在 `FolderReader.readExifDate` / `makeItem`，I/O bound）。

**根因／做法：** `detailPhoto != nil` 時 PhotoGridView 被移出 hierarchy，返回時重建並重跑 `loadCurrentLevel()` → `FolderReader.listLevel` 對每個檔案：開 CGImageSource 讀 EXIF 日期 + `attributesOfItem` syscall + XMP sidecar `fileExists` stat。數千檔案在 NAS 上逐檔 I/O 即十餘秒。

分析後發現 EXIF 日期在 grid 只用於排序，而相機直寫檔案的 mtime 即拍攝時間（SearchResultsView 已是 mtime-only 先例；Inspector 的 Date Taken 由 detail view 按需讀完整 EXIF，不受影響）。修法：

1. **移除 grid 路徑的 `readExifDate`**——`dateTaken` 直接用 mtime。
2. **改用 `contentsOfDirectory` 預取的 `resourceValues`**（size/mtime），移除逐檔 `attributesOfItem` syscall。
3. **XMP sidecar 改由目錄列舉建 `Set` 查 membership**，移除逐檔 `fileExists` stat，只對真的有 sidecar 的檔案讀取。
4. 移除 `concurrentPerform` 平行化——`makeItem` 已無 I/O，平行化反成開銷。

`listLevel` 從「每檔 3 次 I/O」降為「一次 `contentsOfDirectory`」，返回 grid 即時完成。

**修改的檔案：**
- `Spectrum/Services/FolderReader.swift`：移除 `readExifDate` / `exifDateFormatter`；`makeItem` 改吃預取 resourceValues + sidecarPaths Set

## 2026-07-13 — Rename box 輸入法選字被方向鍵導航攔截

**類型：** Bug Fix

**問題：** 在 rename 對話框用輸入法打字時，按上下鍵選字會觸發 grid view 的選取移動——按鍵被吃掉，選字功能失效。

**根因／做法：** `PhotoNavigationCommands` 把無修飾鍵的方向鍵／Return 綁成選單 key equivalent。選單 equivalent 的比對發生在事件送達 text field／IME **之前**，只要命令 enabled（rename alert 開啟時 grid 的 `focusedSceneValue` 仍存在）就會攔走按鍵。同類過度綁定還有：裸 Delete 鍵（文字框按 backspace 可能觸發 Move to Trash）、搜尋框輸入時的 Cmd+C/X/V（複製選取的檔案而非文字）、全域 Escape monitor（rename box 按 Esc 被攔走觸發返回導航）。

修法演進（前兩版 reactive 方案都失敗，最終用確定性 NSEvent monitor）：

1. **第一版（失敗）**：Commands body 直接讀 `@Observable` 做 `.disabled`——`Commands` 不是 `View`，Observation 變更不會觸發 Commands 重算，disabled 停留在舊值。
2. **第二版（失敗）**：改在發佈 `focusedSceneValue` 的 View 端 gating（View body 的 Observation 追蹤可靠）。E2E 診斷證實偵測正確（rename alert 的 responder 是 `_SystemTextFieldFieldEditor`，NSTextView），但 **alert panel 成為 key window 期間，scene 的 focused values 更新到不了 Commands**——選單照樣攔鍵。
3. **第三版（成功）**：`TextInputFocusMonitor` init 時安裝 `NSEvent.addLocalMonitorForEvents(.keyDown)`——local monitor 在選單 key equivalent 比對**之前**收到事件。`routeToTextInputIfNeeded()`：first responder 是 NSTextView 時，(a) 裸方向鍵／PageUp/Down／Delete 直接 `textView.keyDown(with:)` 轉發並吃掉事件（IME 選字、游標移動恢復正常）；(b) Return 只在 `hasMarkedText()`（IME 組字中）時轉發，否則放行給 alert 預設按鈕；(c) Cmd+A/C/X/V 直接呼叫 `textView.selectAll/copy/cut/paste`（否則被 FolderEditCommands 攔走變成檔案操作）。

發佈端 gating（第二版）保留作為搜尋框情境的防護（主視窗內 responder 切換時該鏈有效）。`EscapeKeyMonitor` 對文字輸入放行。

**驗證**：新增 E2E 迴歸測試 `testRenameFieldArrowKeysStayInTextField`——用游標移動斷言（打 `abc` → ←← → 打 `X` → 必須是 `aXbc`）作為 IME 無關的代理，加上 backspace 編輯與 Cmd+A 全選文字的斷言。修正前此測試重現 bug（`abcX`、全選被攔），修正後通過；全套 280 測試無回歸。

**修改的檔案：**
- `Spectrum/SpectrumApp.swift`：`TextInputFocusMonitor` + `routeToTextInputIfNeeded()` key guard
- `Spectrum/Views/Grid/PhotoGridView.swift`、`Spectrum/Views/ContentView.swift`：focusedSceneValue gating + `EscapeKeyMonitor` 放行
- `SpectrumUITests/GridInteractionUITests.swift`：新增 E2E 迴歸測試
- `SpectrumTests/CoreServicesUnitTests.swift`：`TextInputFocusMonitorTests`

## 2026-07-13 — 影片播放卡頓（二）：gyro 矩陣計算移出渲染路徑

**類型：** Bug Fix / Performance

**問題：** 10GbE 修正 NAS I/O 後影片仍卡頓。Trace 顯示穩定播放期間有 8 次 150–220ms 的 renderFrame 空窗，空窗內全是 gyroflow-core 的 rayon 執行緒（`quat_at_timestamp` × 2160 rolling-shutter rows）。

**根因／做法：** `computeMatrixAtTime` 是同步 FFI，在 renderQueue 上逐幀執行；Sony RS 修正每幀要對 2160 個掃描列做 quaternion 取樣（rayon 平行化），偶發尖峰 150–220ms 期間 `renderSemaphore` 把後續 display link tick 全部丟棄——體感每隔幾秒頓一次。

改為非同步 pipeline（`AVFMetalView`）：

- **`gyroComputeQueue`（serial）**：渲染每一幀時排程預算下一幀（pts + 1/fps）矩陣；`performGyroCompute` 計算 → 上傳 matTex → 發佈 `GyroSnapshot`（pts + 紋理索引 + 烘焙好的 `WarpUniforms`）
- **renderFrame 永不阻塞**：直接取最新 snapshot；計算尖峰時沿用上一幀矩陣（gyro 矩陣逐幀平滑，一幀延遲視覺上可忽略）
- **同步 fallback 僅限首幀／seek**：snapshot 缺失或偏差 > max(0.3s, 4 幀) 時同步計算一次，避免呈現未穩定的畫面
- **三重緩衝 matTex**：GPU 可能落後 CPU 1–2 幀，輪替上傳避免覆寫讀取中的紋理（舊實作單一紋理每幀覆寫本身就有撕裂風險）
- **Generation counter**：切換影片／gyro toggle 時 `invalidateGyroSnapshot()` 遞增世代，in-flight 的舊計算結果被拒絕發佈
- matsBuf 是 GyroCore 內部單一緩衝，所有 `computeMatrixAtTime` 呼叫（含同步 fallback 的 `gyroComputeQueue.sync`）都收斂到同一條 serial queue 上，避免跨執行緒覆寫
- `GyroCoreProvider` 加上 `Sendable`（GyroCore 本已內部同步）

**診斷過程備註：** 同一症狀先後有兩個獨立根因——(1) SMB 走了 WiFi 而非 10GbE，AVFoundation 小塊同步讀取有效吞吐 ~20Mbps 餵不飽 256Mbps XAVC HS（`ahead` 從 10.5s 匀速流失至 0、`rendered=5–9`）；(2) I/O 修復後才暴露的 gyro 同步 FFI 尖峰。per-second render stats（ticks/drops/noBuf/rendered/drawNil/gyroMs/ahead）是關鍵工具，保留於 codebase。

**修改的檔案：**
- `Spectrum/Views/Detail/AVFMetalView.swift`：async gyro pipeline + 三重緩衝 + per-second stats + DIAG 診斷 log
- `Spectrum/Services/GyroConfig.swift`：`GyroCoreProvider: Sendable`

## 2026-07-14 — HLG 照片亮度不正確：關閉 CALayer 自動 tone mapping

**類型：** Bug Fix

**問題：** Sony HLG 照片（HIF/HEIC，BT.2100 HLG）在 detail view 顯示亮度不對。

**根因／做法：** macOS 15 起 CALayer 有 `toneMapMode` 屬性，預設 `.automatic`——系統會依 CGImage 的 `contentHeadroom`（HLG 名義值 4.93 = 1000/203 nits）對顯示器目前的 EDR headroom 做亮度重新對映，把 HLG 內容整體壓暗。但 HLG 是 scene-referred、本身就設計成隨顯示器亮度縮放的編碼，Spectrum 已明確給定 `itur_2100_HLG` colorspace + EDR，多做一層 tone mapping 反而錯。`HLGNSView` 設 `toneMapMode = .never` 修正。

驗證工具：`tools/hdr-lab/`（獨立 CLI app，載入同一張照片後以按鍵即時切換 8 種渲染管線 A/B 比較：CALayer 三種 toneMapMode、ImageIO decodeToHDR、NSImageView .high/.constrainedHigh、CIImage expandToHDR+EV 可調、SDR 對照組）。實測 `.never` 亮度最正確。

**修改的檔案：**
- `Spectrum/Views/Detail/HDRImageViews.swift`：`HLGNSView` 設 `toneMapMode = .never`
- `tools/hdr-lab/`（新增）：HDR 渲染管線實驗工具

## 2026-07-14 — HLG 照片縮圖偏暗：跳過 QuickLook 改走 ImageIO + EDR

**類型：** Bug Fix

**問題：** HLG 照片的 grid 縮圖亮度偏暗（detail view 修正後，縮圖與之不一致）。

**根因／做法：** 縮圖由 `QLThumbnailGenerator` 產生，QuickLook 一律輸出 SDR 縮圖，其 HLG→SDR tone mapping 把亮度壓暗——SDR 像素產出後顯示端無從救回（`NSImageView .high` 也沒用）。修法分兩端：

- **產生端**（`ThumbnailService`）：HLG 照片（以 `ImagePreloadCache.detectHDR` 判定）改用 `CGImageSourceCreateThumbnailAtIndex` 產生縮圖，`kCGImageSourceCreateThumbnailFromImageAlways`（內嵌預覽圖是 SDR 不能用）+ `WithTransform`；縮放會保留 itur_2100_HLG colorspace
- **顯示端**（`PhotoThumbnailView.AspectFillImageView`）：偵測到縮圖 colorspace 為 ITU-R 2100 TF 時，改走 CALayer contents + EDR + `toneMapMode = .never`（與 detail view 的 HLGNSView 同一套、經 hdr-lab 驗證的路徑）；其餘照片維持 NSImageView

**已知未處理：** HLG 影片的縮圖走 `AVAssetImageGenerator`，仍是 SDR 偏暗，待後續處理。

**修改的檔案：**
- `Spectrum/Services/ThumbnailService.swift`：HLG 分支 `generateHLGThumbnail`
- `Spectrum/Views/Grid/PhotoThumbnailView.swift`：HLG layer 顯示路徑

## 2026-07-14 — Folder 封面與 HLG 影片預覽偏暗：補齊所有縮圖顯示點的 EDR 路徑

**類型：** Bug Fix

**問題：** HLG 照片縮圖修正後，folder 封面、影片預覽格（detail view 按播放前）、搜尋結果、Import 面板的 HLG 內容仍偏暗。

**根因／做法：** 兩個獨立缺口：

- **影片縮圖產生端**：`AVAssetImageGenerator.dynamicRangePolicy` 預設 `.forceSDR`（macOS 15+），HLG 影格被強制 tone map 成 SDR——產出後顯示端無從救回。改設 `.matchSource` 保留來源 colorspace。
- **顯示端**：SwiftUI `Image(nsImage:)` 沒有 EDR 路徑，HDR 縮圖一律被 SDR 合成壓暗。把 `HDRThumbnailImageView`（HLG → CALayer+EDR+`toneMapMode=.never`、其餘 → NSImageView）改為 internal 共用，替換四處：SubfolderTileView（folder 封面）、PhotoDetailView 影片預覽格（新增 `fit` aspect-fit 模式）、SearchResultsView、ImportPanelView。

**修改的檔案：**
- `Spectrum/Services/ThumbnailService.swift`：`dynamicRangePolicy = .matchSource`
- `Spectrum/Views/Grid/PhotoThumbnailView.swift`：`HDRThumbnailImageView` internal + `fit` 參數
- `Spectrum/Views/Grid/PhotoGridView.swift`、`Spectrum/Views/Detail/PhotoDetailView.swift`、`Spectrum/Views/SearchResultsView.swift`、`Spectrum/Views/Import/ImportPanelView.swift`：換用 HDRThumbnailImageView

## 2026-07-14 — Detail view 返回後縮圖長時間空白：內嵌 HLG 縮圖 + 分級記憶體壓力清除

**類型：** Bug Fix

**問題：** 進 detail view 看圖後退回 grid，縮圖要很久才重新出現。

**根因／做法：** 因果鏈：detail view prefetch ±5 張全解析度影像（HLG 為 4K CGImage，單張解碼後可達數百 MB）→ 記憶體壓力 warning → ThumbnailService 與 ImagePreloadCache 的 cache 同時全清 → 回 grid 所有縮圖重生成，而 HLG 縮圖走 `FromImageAlways` 每張都要解碼 4K 主圖。兩處修正：

- **HLG 縮圖改用內嵌縮圖**（`FromImageIfAbsent`）：實測 Sony HIF 的內嵌縮圖本身就是 HLG（8bpc itur_2100_HLG），不需解碼主圖；若其他相機的內嵌縮圖是 SDR（colorspace 檢查失敗）才退回從主圖生成
- **縮圖 cache 只在 critical 壓力清空**：warning 級別由 ImagePreloadCache（大戶）釋放；縮圖總量已受 NSCache totalCostLimit 管制，重生成成本高不該在 warning 就陪葬

**修改的檔案：**
- `Spectrum/Services/ThumbnailService.swift`

## 2026-07-14 — 影片播放期間暫停鄰圖 prefetch

**類型：** Feature

**問題：** Detail view 的鄰圖 prefetch（±5 張全解析度影像）在影片播放時與高碼率串流搶 NAS 頻寬，可能造成播放卡頓。

**根因／做法：** `ImagePreloadCache` 新增 `setPrefetchSuspended(_:)`：

- 暫停時 `prefetch()` 直接 no-op，並取消所有由 prefetch 發起的 in-flight 載入（`prefetchTasks` 追蹤，為 `inFlight` 的子集）；task 內部在讀檔前有兩處 `Task.isCancelled` 檢查提早退出
- 取消的載入結果不存 cache；已取消的 pending task 不會被後續直接載入 join（避免拿到不完整結果）；完成時只清掉仍指向自身的 inFlight/prefetchTasks 登錄，避免清錯後續載入
- 直接載入（目前顯示的照片）不受影響
- `PhotoDetailView`：`videoController.isPlaying` onChange → 播放暫停/停止時恢復並補跑 prefetch；`onDisappear` 保險恢復

**修改的檔案：**
- `Spectrum/Services/ImagePreloadCache.swift`
- `Spectrum/Views/Detail/PhotoDetailView.swift`
- `SpectrumTests/ImagePreloadCacheTests.swift`（+3 測試）
