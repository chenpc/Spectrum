# Spectrum Call Graph

## 1. App 啟動與資料夾掃描

```mermaid
flowchart TD
    A["SpectrumApp @main"] --> B["WindowGroup"]
    A --> S["Settings → SettingsView"]
    B --> C["ContentView"]
    B --> CMD["Menu Commands"]

    CMD --> CMD1["FileCommands → addFolderAction"]
    CMD --> CMD2["PhotoNavigationCommands → ←→↑↓ Enter"]
    CMD --> CMD3["FolderEditCommands → ⌘C/X/V"]
    CMD --> CMD4["DeleteCommands → ⌫"]
    CMD --> CMD5["MpvPlaybackCommands → Space"]

    C -->|".task {}"| BOOT["啟動流程"]
    BOOT --> SCAN["Delta Scan 所有資料夾"]
    BOOT --> PREFETCH["背景 prefetch 資料夾樹"]
    BOOT --> MONITOR["啟動 FSEvents 監視"]
    BOOT --> RESTORE["恢復上次瀏覽位置"]

    SCAN --> |"for each folder"| BS1["BookmarkService.resolveBookmark"]
    BS1 --> FS1["FolderScanner.scanFolder(clearAll: false)"]
    FS1 --> EXIF["EXIFService.readEXIF"]
    FS1 --> VMD["VideoMetadataService.readMetadata"]
    FS1 --> XMP["XMPSidecarService.read → editOps"]
    FS1 --> BATCH["批次 insert Photo (100/batch)"]
    BATCH --> SAVE["modelContext.save → @Query 更新"]

    PREFETCH --> |"Task.detached"| PFT["FolderScanner.prefetchFolderTree"]
    PFT --> FLC["FolderListCache.setEntries"]
    PFT --> SBM["StatusBarModel.setGlobal"]

    MONITOR --> FM["FolderMonitor.startMonitoring(path:)"]
    FM -->|"FSEvents 通知"| INV["FolderListCache.invalidate"]
    INV -->|"觸發重新掃描"| SCAN2["scanCurrentLevel()"]
```

## 2. 側邊欄與資料夾管理

```mermaid
flowchart TD
    SV["SidebarView"] -->|".task"| LOAD["loadAllFolderChildren()"]
    LOAD --> CACHE["FolderListCache.entries (快取)"]
    LOAD --> LS["FolderScanner.listSubfolders"]
    LS --> COVER["findCoverFile (封面照片)"]

    SV --> ADD["addFolder()"]
    ADD --> PANEL["NSOpenPanel (多選)"]
    PANEL --> AURL["addFolderURL(url)"]
    AURL --> BK["BookmarkService.createBookmark"]
    AURL --> RMT["BookmarkService.remountURL"]
    AURL --> INS["modelContext.insert(ScannedFolder)"]
    INS --> RESCAN["FolderScanner.scanFolder(clearAll: true)"]

    SV --> DROP["onDrop(.fileURL)"]
    DROP --> AURL

    SV --> CTX["右鍵選單"]
    CTX --> CTX1["Rescan → scanFolder(clearAll: true)"]
    CTX --> CTX2["Show in Finder"]
    CTX --> CTX3["Remove → modelContext.delete"]

    SV --> TREE["SubfolderSidebarRow (遞迴)"]
    TREE --> |"DisclosureGroup"| TREE
    TREE -->|"選擇"| SEL["selectedSidebarItem = .subfolder"]
```

## 3. 照片網格

```mermaid
flowchart TD
    PGV["PhotoGridView"] -->|".task"| SCL["scanCurrentLevel()"]
    SCL --> NVS["NetworkVolumeService 掛載檢查"]
    SCL --> CACHE["FolderListCache (快取子資料夾)"]
    SCL --> LS["FolderScanner.listSubfolders"]
    SCL --> DELTA["FolderScanner.scanFolder (delta)"]
    DELTA --> QUERY["@Query photos 更新"]

    PGV --> GRID["LazyVGrid (.adaptive 150px)"]
    GRID --> SUB["SubfolderTileView"]
    GRID --> PTV["PhotoThumbnailView"]

    PTV -->|".task"| THUMB["ThumbnailService.thumbnail"]
    THUMB --> MEM["memoryCache (NSCache 500項)"]
    THUMB --> DISK["diskCache (SHA256.heic)"]
    THUMB --> GEN["generateAndCacheThumbnail"]
    GEN --> CGI["CGImageSource (圖片 300px)"]
    GEN --> AVG["AVAssetImageGenerator (影片)"]
    GEN --> EVICT["evictIfNeeded (LRU)"]

    PGV --> MSEL["多選操作"]
    MSEL --> CMD["Cmd+click toggle"]
    MSEL --> SHIFT["Shift+click range"]
    MSEL --> MARQUEE["Marquee 圈選"]

    PGV --> DEL["Delete"]
    DEL --> TRASH["FileManager.trashItem"]
    TRASH -->|"失敗(網路磁碟)"| REMOVE["FileManager.removeItem"]
    DEL --> DBDEL["modelContext.delete(photo)"]

    PGV --> CLIP["剪貼簿操作"]
    CLIP --> COPY["FolderClipboard.copy"]
    CLIP --> CUT["FolderClipboard.cut"]
    CLIP --> PASTE["performPaste()"]
    PASTE --> MOVE["FileManager.moveItem (同 scope)"]
    PASTE --> CPDEL["copyItem + removeItem (跨 scope)"]

    PGV --> RENAME["performRename"]
    RENAME --> FMMOVE["FileManager.moveItem"]
    RENAME --> SCL

    PGV --> IMPORT["右鍵 Add to Import"]
    IMPORT --> IMP["importModel.openFolder(url)"]

    SUB -->|"點擊"| NAV["onNavigateToSubfolder"]
    PTV -->|"雙擊 / Enter"| DETAIL["detailPhoto = photo"]
```

## 4. 照片詳情與 HDR

```mermaid
flowchart TD
    PDV["PhotoDetailView"] -->|".task(id: filePath)"| ROUTE{"photo.isVideo?"}
    ROUTE -->|"否"| IMG["loadFullImage()"]
    ROUTE -->|"是"| VID["loadVideo()"]

    IMG --> TCACHE["ThumbnailService.cachedThumbnail (即時)"]
    IMG --> IPC["ImagePreloadCache.loadImageEntry"]
    IPC --> SCOPE["BookmarkService 安全範圍"]
    IPC --> DETECT["detectHDR(source)"]
    DETECT --> GM["AuxiliaryData HDRGainMap → .gainMap"]
    DETECT --> HLG["CGColorSpaceUsesITUR_2100TF → .hlg"]
    IPC --> NSIMG["NSImage(contentsOf:)"]
    IPC --> HLGCG["CGImageSourceCreateImageAtIndex → hlgCGImage"]

    IMG --> PRELOAD["preloadAdjacent (前後各1張)"]
    PRELOAD --> IPC

    IMG --> DISPLAY{"hdrFormat?"}
    DISPLAY -->|".hlg + showEDR"| HLGV["HLGImageView"]
    HLGV --> CALAY["CALayer.contents = cgImage"]
    HLGV --> CS["colorspace = itur_2100_HLG"]
    DISPLAY -->|".gainMap / SDR"| HDRV["HDRImageView"]
    HDRV --> NSIDR["NSImageView.preferredImageDynamicRange"]

    PDV --> BADGE["edrBadge (點擊切換 HDR/SDR)"]
    BADGE --> TOGGLE["showEDR.toggle()"]

    PDV --> KEYIMG["installImageKeyMonitor"]
    KEYIMG --> FKEY["F → toggleFullScreen"]
    KEYIMG --> SPACE["Space → Live Photo toggle"]
```

## 5. 影片播放 + Gyro

```mermaid
flowchart TD
    LV["loadVideo()"] --> RESET["重設狀態"]
    LV --> XMPREAD["XMPSidecarService.read → gyroConfigJson"]
    LV --> START["startPlayback()"]

    START --> HDRD["detectVideoHDRType"]
    HDRD --> AVTRACK["AVURLAsset → loadTracks"]
    HDRD --> FMTDESC["track.formatDescriptions"]
    FMTDESC --> DV["DolbyVision (dvcC/dvvC)"]
    FMTDESC --> HLGV["HLG (ITU_R_2100_HLG)"]
    FMTDESC --> PQV["HDR10 (SMPTE_ST_2084_PQ)"]

    START --> POSTER["AVAssetImageGenerator → posterFrame"]
    START --> GYROSTART{"gyroStabEnabled\n&& dylibFound?"}
    GYROSTART -->|"是"| GSTAB["videoController.startGyroStab"]
    START --> KEYMON["installActiveKeyMonitor"]

    KEYMON --> SPACE["Space → togglePlayPause"]
    KEYMON --> FKEY["F → toggleFullScreen"]
    KEYMON --> HKEY["H → showEDR.toggle + flashBadge"]
    KEYMON --> SGKEY["S/G → toggleGyroStab + flashBadge"]
    KEYMON --> IKEY["I → toggleInspector"]

    GSTAB --> STOPOLD["stopGyroStab (停舊的)"]
    GSTAB --> WAIT["setWaitingForGyro(true)"]
    GSTAB --> CORE["GyroCore()"]
    CORE --> CORESTART["core.start()"]
    CORESTART -->|"ioQueue 背景"| DLOPEN["dlopen(libgyrocore_c.dylib)"]
    DLOPEN --> GCLOAD["gyrocore_load(video, lens, configJSON)"]
    GCLOAD -->|"Rust 內部"| STAB["StabilizationManager"]
    STAB --> LOADV["load_video_file"]
    STAB --> AUTODET["auto-detect lens profile"]
    STAB --> GOPRO{"GoPro detected?"}
    GOPRO -->|"是"| SKIPRS["frame_readout_time = 0\n(skip RS correction)"]
    GOPRO -->|"否"| SETRS["set_frame_readout_time(ms)"]
    STAB --> RECOMP["recompute_blocking (~300ms)"]
    RECOMP --> FREEZE["ComputeParams 凍結快照"]

    GCLOAD --> GETPARAM["gyrocore_get_params → 96 bytes"]
    GETPARAM --> ALLOC["分配 rawBuf + matsBuf"]

    CORESTART -->|"onReady"| READY["gyroStabEnabled = true"]
    READY --> LOADGC["nsView.loadGyroCore(core)"]
    LOADGC --> DEFERRED{"deferredPlay?"}
    DEFERRED -->|"是"| PLAY["nsView.setPause(false)"]
```

## 6. Metal 渲染管線 (renderFrame)

```mermaid
flowchart TD
    CVD["CVDisplayLink callback"] -->|"renderQueue"| RF["renderFrame()"]
    RF --> GUARD{"waitingForGyro\n|| avfLayerMode?"}
    GUARD -->|"是"| SKIP["return (跳過)"]
    GUARD -->|"否"| PB["output.copyPixelBuffer\n(forItemTime:itemTimeForDisplay:)"]

    PB --> PTS["精確 PTS (presentation timestamp)"]

    PTS --> GYROQ{"gyroCore.isReady?"}
    GYROQ -->|"是"| GMAT["gyroCore.computeMatrixAtTime(pts)"]
    GMAT --> FFI["gyrocore_get_frame_at_ts (C FFI)"]
    FFI --> FTRANS["FrameTransform.at_timestamp"]
    FTRANS --> MATS["row_count × 14 + 9 floats"]
    MATS --> EXPAND["展開: rowCount×14 → videoH×16"]
    EXPAND --> MATTEX["上傳 matTex (RGBA32F w=4 h=videoH)"]
    GMAT --> SI["計算 Gyro Stability Index"]

    GYROQ -->|"否"| SINGLE["單段渲染"]

    MATTEX --> PASS1["Pass 1: YCbCr → RGBA16Float"]
    PASS1 --> TEXY["makeTexture plane:0 → texY"]
    PASS1 --> TEXCBCR["makeTexture plane:1 → texCbCr"]
    PASS1 --> DECODE["Fragment Shader\n(14 decode modes)"]
    DECODE --> OFFTEX["offscreen texture"]

    OFFTEX --> PASS2["Pass 2: Warp Shader"]
    PASS2 --> WARP["Fragment Shader"]
    WARP --> UNDIST["undistort_point (Newton-Raphson)"]
    WARP --> READMAT["讀取 matTex → mat3×3"]
    WARP --> DIST["distort_point (5 models)"]
    WARP --> IBIS["IBIS: rotate(-ra) + shift(-sx,-sy)"]
    WARP --> OIS["OIS: shift(+ox, +oy)"]
    PASS2 --> DRAW["CAMetalLayer drawable"]

    SINGLE --> TEXY2["makeTexture → texY + texCbCr"]
    SINGLE --> DEC2["Fragment Shader → drawable"]

    DRAW --> PRESENT["cmdBuf.present + commit"]
    PRESENT --> DIAG["measureFrameTiming\n→ renderFPS, renderCV"]
```

## 7. HDR Colorspace 管理

```mermaid
flowchart TD
    PREP["prepareForContent(hdrType)"] --> CSSET{"VideoHDRType?"}
    CSSET -->|".hlg"| CSHLG["CAMetalLayer.colorspace\n= itur_2100_HLG"]
    CSSET -->|".hdr10"| CSPQ["CAMetalLayer.colorspace\n= itur_2100_PQ"]
    CSSET -->|".dolbyVision"| CSDV["auto-detect HLG or PQ"]
    CSSET -->|"nil (SDR)"| CSSDR["CAMetalLayer.colorspace\n= sRGB / displayP3"]

    EDR["EDR 啟用"] --> EDRMGMT["CAMetalLayer\n.wantsExtendedDynamicRangeContent = true"]

    TOGGLE["H 鍵 / showEDR.toggle"] --> CSSWITCH["切換 layer colorspace"]
    CSSWITCH --> DECSWITCH["切換 decode mode"]
```

## 8. 非破壞性編輯

```mermaid
flowchart TD
    PDV["PhotoDetailView"] --> ROT["rotateLeft()"]
    PDV --> FLIP["flipHorizontal()"]
    PDV --> CROP["enterCropMode()"]
    PDV --> RESTORE["restoreEdits()"]

    ROT --> APPEND1["photo.editOps.append(.rotate(-90))"]
    FLIP --> APPEND2["photo.editOps.append(.flipH)"]

    CROP --> OVERLAY["CropOverlayView\n(拖曳控制點)"]
    OVERLAY --> APPLY["applyCrop()"]
    APPLY --> APPEND3["photo.editOps.append(.crop(CropRect))"]

    APPEND1 --> COMP["CompositeEdit.from(ops)"]
    APPEND2 --> COMP
    APPEND3 --> COMP
    COMP --> FLATTEN["平面化: rotation + flipH + crop\n(CropRect.rotated(by:) 座標轉換)"]

    FLATTEN --> STATE["applyCompositeState()"]
    STATE --> ROTEFF[".rotationEffect(activeRotation)"]
    STATE --> CROPEFF["activeCrop → 裁切顯示"]

    APPEND1 --> XMPW["writeXMPSidecar()"]
    APPEND2 --> XMPW
    APPEND3 --> XMPW
    XMPW --> XMPS["XMPSidecarService.write"]
    XMPS --> ORIENT["exifOrientation 轉換 (D4 群)"]
    XMPS --> CRSXML["Camera Raw crop XML"]
    XMPS --> GYROXML["spectrum:GyroConfig JSON"]
    XMPS --> FILE["{filename}.{ext}.xmp"]

    RESTORE --> CLEAR["photo.editOps = []"]
    CLEAR --> XMPD["XMPSidecarService.deleteSidecar"]
```

## 9. 匯入面板

```mermaid
flowchart TD
    ENTRY["觸發方式"] --> E1["ImportPanelModel.selectFolder\n→ NSOpenPanel"]
    ENTRY --> E2["子資料夾右鍵\nAdd to Import"]
    E1 --> SURL["sourceURL = url"]
    E2 --> OPEN["importModel.openFolder(url)"]
    OPEN --> SURL

    SURL -->|"onChange"| SHOW["showImportPanel = true"]
    SHOW --> IPV["ImportPanelView"]

    IPV --> SCAN["scanFolder(url) async"]
    SCAN -->|"Task.detached"| ENUM["FileManager 列舉"]
    ENUM --> EXIF["EXIFService.readEXIF → dateTaken"]
    EXIF --> ITEMS["items: [ImportItem]"]

    ITEMS --> GROUP["dateGroups (按 EXIF 日期分組)"]
    GROUP --> UI["日期分組 UI + 展開/縮合"]

    UI --> DRAG["onDrag → NSItemProvider"]
    DRAG --> DROP["PhotoGridView.handleDrop"]
    DROP --> GDROP["performGroupDrop"]
    GDROP --> GCOPY["FileManager.copyItem (複製)"]
    GDROP --> GMOVE["FileManager.moveItem (剪下)"]
    GDROP --> STATUS["StatusBarModel 進度更新"]
    GMOVE --> REMOVE["importModel.removeItems"]

    UI --> CTXMENU["右鍵 Copy / Cut"]
```
