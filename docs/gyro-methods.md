# Gyro 穩定化方法：Spectrum vs Gyroflow

MyPhoto 提供兩種 gyro 穩定化引擎，透過 Settings → Gyro Method 切換：

- **Spectrum** (`GyroCore`) — 一次性載入，凍結計算參數
- **Gyroflow** (`GyroFlowCore`) — 增量式，保留完整狀態機，支援即時參數調整

兩者共用同一個 dylib（`libgyrocore_c.dylib`）、同一組 Rust 底層（gyroflow-core），同一套 GPU warp shader，差異在於 **C API 設計模式** 和 **Rust 端狀態管理方式**。

---

## 架構總覽

兩個方法的呼叫路徑：

- **Spectrum**: `PhotoDetailView.startGyro()` → `VideoController.startGyroStab()` → `GyroCore.start()` → `gyrocore_load()`
- **Gyroflow**: `PhotoDetailView.startGyro()` → `VideoController.startGyroStabGyroflow()` → `GyroFlowCore.start()` → `gyroflow_create()` → `gyroflow_load_video()` → `gyroflow_set_param()` × N → `gyroflow_recompute()`

兩者最終都透過 `GyroCoreProvider` protocol 提供 `computeMatrixAtTime(timeSec)` 給 `AVFMetalView.renderFrame()`，GPU Metal warp shader 完全不知道底層是哪個引擎。Rust 側共用同一個 `libgyrocore_c.dylib`（兩組 API 並存）。

---

## 核心差異比較

### 1. Rust 端狀態結構

#### Spectrum: `State`（凍結快照）

```rust
struct State {
    frame_count:    usize,
    row_count:      usize,
    scaled_fps:     f64,
    vid_w/vid_h:    usize,
    fx/fy/cx/cy:    f32,
    k:              [f32; 12],
    distortion_model: i32,
    r_limit:        f32,
    lens_info:      String,
    compute_params: ComputeParams,    // ← 凍結！載入後不可變
}
```

`compute_params` 是 `ComputeParams::from_manager(&stab)` 的快照。`StabilizationManager` 在 `gyrocore_load()` 結束後被 drop，只留下這個凍結的計算參數。

#### Gyroflow: `GyroflowState`（持久狀態機）

```rust
struct GyroflowState {
    stab: StabilizationManager,        // ← 保留！可隨時修改
    compute_params: Option<ComputeParams>,
    frame_count/row_count/scaled_fps/...,
}
```

`StabilizationManager` 被完整保留。任何時候都可以透過 `set_param()` 修改參數，再呼叫 `recompute()` 重新計算。

**這就是兩者最根本的差異：Spectrum 丟棄狀態機，Gyroflow 保留狀態機。**

---

### 2. C API 對比

| | Spectrum (`gyrocore_*`) | Gyroflow (`gyroflow_*`) |
|---|---|---|
| **建立** | `gyrocore_load(video, lens?, config_json?)` | `gyroflow_create(lens_db_dir?)` |
| **載入影片** | 包含在 `_load` 中 | `gyroflow_load_video(handle, path)` |
| **載入鏡頭** | 包含在 `_load` 中 | `gyroflow_load_lens(handle, path)` |
| **設定參數** | 包含在 `config_json` 中 | `gyroflow_set_param(handle, key, val)`<br>`gyroflow_set_param_str(handle, key, val)` |
| **計算穩定化** | 包含在 `_load` 中 | `gyroflow_recompute(handle)` |
| **讀取後設資料** | `gyrocore_get_params(handle, buf96)` | `gyroflow_get_params(handle, buf96)` |
| **取得幀矩陣** | `gyrocore_get_frame(handle, idx, buf)`<br>`gyrocore_get_frame_at_ts(handle, ts, buf)` | `gyroflow_get_frame(handle, ts, buf)` |
| **鏡頭資訊** | `gyrocore_get_lens_info(handle, buf, len)` | `gyroflow_get_lens_info(handle, buf, len)` |
| **釋放** | `gyrocore_free(handle)` | `gyroflow_free(handle)` |
| **函數總數** | 6 | 10 |

Spectrum 是「一步到位」模式：所有初始化（載入影片 → 解析鏡頭 → 設定參數 → recompute）濃縮在一個 `gyrocore_load()` 呼叫中。

Gyroflow 是「分步組裝」模式：create → load_video → load_lens → set_param × N → recompute，每一步都可獨立呼叫。

---

### 3. 初始化流程

#### Spectrum

```
GyroCore.start()
  ├─ dlopen(libgyrocore_c.dylib)          ← 主線程
  ├─ dlsym(gyrocore_load, _get_params, _get_frame, _get_frame_at_ts?, _get_lens?, _free)
  └─ ioQueue.async (qos: .userInteractive)
       └─ gyrocore_load(videoPath, lensPath?, configJSON)    ← ~300ms 阻塞
            │  ↓ Rust 內部
            │  StabilizationManager::default()
            │  stab.load_video_file()
            │  [lens profile auto-detect / .gyroflow project loading]
            │  [set all params: smoothing, fov, RS, horizon lock, zoom...]
            │  stab.recompute_blocking()                     ← 主要耗時
            │  cp = ComputeParams::from_manager(&stab)       ← 凍結
            │  State { compute_params: cp, ... }
            │  → drop(stab)                                  ← StabilizationManager 被丟棄
            ↓
       gyrocore_get_params(handle, buf96)                    ← 讀 frameCount, videoW/H, fps, f, c, k, distModel
       pre-allocate rawBuf[rowCount*14+9], matsBuf[videoH*16]
       _isReady = true → onReady()
```

#### Gyroflow

```
GyroFlowCore.start()
  └─ ioQueue.async (qos: .userInitiated)
       ├─ dlopen(libgyrocore_c.dylib)
       ├─ dlsym(gyroflow_create, _load_video, _load_lens, _set_param, _set_param_str,
       │        _recompute, _get_frame, _get_params, _get_lens_info, _free)
       │
       ├─ gyroflow_create(lensDbDir?)                        ← 建立空的 StabilizationManager
       ├─ gyroflow_load_video(handle, videoPath)             ← 解析影片 + gyro 資料
       ├─ gyroflow_load_lens(handle, lensPath)               ← [可選] 載入鏡頭
       │
       ├─ applyConfig(config, handle)                        ← 逐一設定參數
       │    ├─ set_param("smoothness", 0.5)
       │    ├─ set_param("fov", 1.0)
       │    ├─ set_param("lens_correction_amount", 1.0)
       │    ├─ set_param("adaptive_zoom", 4.0)
       │    ├─ set_param("frame_readout_time", 20.0)
       │    ├─ set_param("horizon_lock_amount", ...)
       │    ├─ set_param_str("imu_orientation", ...)
       │    └─ ... (15+ 參數)
       │
       ├─ gyroflow_recompute(handle)                         ← ~50ms 重算
       │    │  ↓ Rust 內部
       │    │  stab.recompute_blocking()
       │    │  cp = ComputeParams::from_manager(&stab)
       │    │  state.compute_params = Some(cp)
       │    │  → stab 仍然保留                               ← 不 drop！
       │    ↓
       ├─ gyroflow_get_params(handle, buf96)
       ├─ pre-allocate matBuf[rowCount*14+9]
       └─ _isReady = true → onReady()
```

---

### 4. 參數變更能力

這是兩者最大的使用體驗差異。

#### Spectrum：無法增量修改

使用者改了任何參數（smoothness、FOV、horizon lock...），都必須 **完整重新載入**：

```
stop() → gyrocore_free() → start() → gyrocore_load()
                                         ↓
                                      ~300ms 重新載入
```

因為 `State` 中只有凍結的 `ComputeParams`，沒有 `StabilizationManager`，無法修改任何參數。

#### Gyroflow：增量修改 + 快速重算

```swift
// Swift: 使用者拖動 smoothness slider
core.setParam("smoothness", 0.8)
core.recompute {
    // ~50ms 後完成，畫面立即更新
}
```

Rust 端：

```rust
// gyroflow_set_param: 直接修改 StabilizationManager 的對應欄位
"smoothness" → stab.smoothing.write().current_mut().set_parameter("smoothness", value)
"fov"        → stab.params.write().fov = value
"adaptive_zoom" → stab.set_adaptive_zoom(value)
// ...

// gyroflow_recompute: ~50ms
stab.recompute_blocking()
state.compute_params = Some(ComputeParams::from_manager(&stab))
state.update_from_compute_params()  // 更新 row_count, f, c, k 等
```

**為什麼 recompute 只要 ~50ms？** 因為 `gyroflow_recompute` 不需要重新載入影片、不需要重新解析 gyro 資料、不需要重新載入鏡頭 profile。它只需要根據已有的陀螺儀四元數 + 新參數重新計算平滑四元數和 adaptive zoom。

---

### 5. 每幀矩陣計算

兩者在「查詢單一幀的穩定化矩陣」的 Rust 端邏輯完全相同：

```rust
// 相同的核心計算
let ft = FrameTransform::at_timestamp(&compute_params, ts_ms, frame_idx);
// 相同的輸出格式：row_count × 14 + 9 floats
```

但 Swift 端的處理有差異：

#### Spectrum (`GyroCore.computeMatrixAtTime`)

```
1. coreLock 保護
2. 幀索引快取：若 fi == cachedFrameIdx → 返回 (matsBuf, changed=false)
3. FFI 呼叫：gyrocore_get_frame_at_ts(handle, timeSec, rawBuf)
   （回退到 gyrocore_get_frame(handle, fi, rawBuf) 如果不支援）
4. 提取每幀 lens params：rawBuf[pfBase..+9] → frameFx/Fy/Cx/Cy, frameK[4], frameFov
5. FOV 歷史追蹤：120 幀滾動窗口 → fovMin/fovMax
6. 行展開：rawBuf[rowCount×14] → matsBuf[videoH×16]
   ├─ 每行 14 floats 重新排列為 16 floats (RGBA32F texel format)
   └─ 從 rowCount 行插值/複製到 videoH 行
7. cachedFrameIdx = fi
8. 返回 (matsBuf, changed=true)
```

#### Gyroflow (`GyroFlowCore.computeMatrixAtTime`)

```
1. coreLock 保護
2. 無快取（每次都重新計算）
3. FFI 呼叫：gyroflow_get_frame(handle, timeSec, matBuf)
4. 提取每幀 lens params：matBuf[pfBase..+9] → frameFx/Fy/Cx/Cy, frameK[4], frameFov
5. 無 FOV 歷史追蹤
6. 無行展開（直接返回 rowCount×14 格式）
7. 返回 (matBuf, changed=false)
```

| 差異點 | Spectrum | Gyroflow |
|--------|----------|----------|
| 快取機制 | 有（相同幀索引跳過 FFI 呼叫） | 無（每幀都呼叫 FFI） |
| 返回 `changed` | `true`（新幀）/ `false`（快取命中） | 始終 `false` |
| 行展開 | 有：`rowCount×14 → videoH×16` | 無：直接返回 `rowCount×14` |
| FOV 追蹤 | 有：120 幀窗口 `fovMin/fovMax` | 無 |
| 時間戳 API | 優先 `_at_ts`，回退 `_get_frame(idx)` | 僅 `_get_frame(ts)` |
| 緩衝區大小 | `rawBuf[rc×14+9]` + `matsBuf[vH×16]` | `matBuf[rc×14+9]` |

> **注意**：行展開的差異意味著 GPU 端收到的矩陣紋理格式不同。Spectrum 提供 `videoH × 16` 的完整紋理（每個像素行一個矩陣），Gyroflow 提供 `rowCount × 14` 的原始格式。但因為 `draw()` 中使用 `core.gyroVideoH` 作為紋理高度，而 Gyroflow 的 `rowCount` 通常等於 `videoH`（rolling shutter 場景），所以兩者在 GPU 端的行為實際上是一致的。

---

### 6. 線程模型

| | Spectrum | Gyroflow |
|---|---|---|
| ioQueue QoS | `.userInteractive` | `.userInitiated` |
| dlopen 時機 | 主線程（start 方法中） | ioQueue 背景線程 |
| 載入阻塞 | ioQueue (~300ms) | ioQueue (~300ms) |
| 參數重算 | 不支援 | ioQueue (~50ms) |
| 矩陣查詢 | 渲染線程（CVDisplayLink → renderFrame） | 渲染線程 |
| 鎖 | `readyLock`（isReady）+ `coreLock`（compute/stop 互斥） | 相同 |
| deinit 安全網 | 有（若 stop() 未被呼叫） | 無 |

---

### 7. 配置傳遞方式

#### Spectrum：JSON 一次傳入

```swift
let configJSON = try JSONEncoder().encode(config)  // GyroConfig → JSON string
gyrocore_load(videoPath, lensPath, configJSON)
```

所有 30+ 參數打包成一個 JSON string，Rust 端用 `serde_json::from_str::<Config>()` 反序列化。

好處：原子性（全部或無），Rust 端可以在正確的順序設定參數（先 set smoothing method，再 set params）。

壞處：不能事後修改。

#### Gyroflow：逐個參數設定

```swift
"smoothness".withCString { fn(handle, $0, 0.5) }
"fov".withCString { fn(handle, $0, 1.0) }
"adaptive_zoom".withCString { fn(handle, $0, 4.0) }
// ...
```

好處：可以只修改需要變更的參數，不需要重新傳入整組配置。
壞處：需要知道正確的參數名稱字串，且呼叫順序可能影響結果。

---

### 8. 鏡頭處理差異

#### Spectrum

```rust
// gyrocore_load 內部：
// 1. 先嘗試從影片 metadata 自動偵測鏡頭
let auto_loaded = stab.lens.read().fisheye_params.camera_matrix.len() == 3;

// 2. 若有 lens_path：載入 .gyroflow project 的 calibration_data
//    但只在 auto_loaded == false 時覆蓋鏡頭
if !auto_loaded {
    stab.load_lens_profile(&calib_str);
}

// 3. 偵測 "Distortion comp.: On" → 強制 distortion_model = 0
if lens_note.contains("Distortion comp.: On") {
    dm = 0;
}
```

#### Gyroflow

```rust
// 分步驟：
gyroflow_load_video(handle, path)   // 自動偵測鏡頭
gyroflow_load_lens(handle, path)    // 覆蓋鏡頭（無條件）
gyroflow_recompute(handle)
  → update_from_compute_params()    // 偵測 "Distortion comp.: On" → distortion_model = 0
```

**差異**：
- 兩者都偵測 Sony「機內失真補償開啟」並強制 `distortion_model=0`
- Spectrum 優先保留自動偵測的鏡頭，`.gyroflow` 只在自動偵測失敗時才覆蓋；Gyroflow 直接覆蓋

---

### 9. 效能特徵

| 指標 | Spectrum | Gyroflow |
|------|----------|----------|
| 初始載入 | ~300ms | ~300ms（create + load_video + recompute） |
| 參數變更後重算 | ~300ms（完整重載） | ~50ms（增量 recompute） |
| 每幀矩陣查詢 | ~0.5ms（FFI） / 0ms（快取命中） | ~0.5ms（FFI） / 0ms（快取命中） |
| 紋理上傳節省 | 有（`changed=false` 跳過 ~0.1ms glTexSubImage2D） | 有（相同機制） |
| 記憶體 | `rawBuf` + `matsBuf`（兩份緩衝區） | `matBuf` + `matsBuf`（兩份緩衝區） |
| Rust 端記憶體 | 僅 `ComputeParams`（~數 MB） | `StabilizationManager` 完整保留（~數十 MB） |

---

### 10. 適用場景

| 場景 | 推薦方法 | 原因 |
|------|----------|------|
| 純播放（參數已固定） | Spectrum | 較低記憶體、有快取、更完整的鏡頭處理 |
| 互動調參（slider 即時預覽） | Gyroflow | 50ms 重算 vs 300ms 重載 |
| 開發/除錯 | Gyroflow | 可即時修改單一參數觀察效果 |

---

## 共用組件

兩個方法共用以下組件，完全不需要區分：

- **GyroCoreProvider protocol** — 統一介面，GPU pipeline 不知道底層是哪個引擎
- **GyroConfig struct** — 同一組配置參數（Swift ↔ Rust snake_case 映射）
- **GPU warp shader** — MetalShaders.swift 中的 Metal warp shader（5 種畸變模型）
- **matTex 格式** — width=4 RGBA32F Metal 紋理（每行 = 3×3 矩陣 + IBIS + OIS）
- **Params blob** — 96 bytes，完全相同的二進位佈局
- **Per-frame output** — `row_count × 14 + 9` floats，完全相同的格式
- **libgyrocore_c.dylib** — 同一個 Rust cdylib（兩組 API 共存）
- **gyroflow-core** — 底層 Rust 庫（`StabilizationManager`, `ComputeParams`, `FrameTransform`）

---

## 相關檔案

| 檔案 | 說明 |
|------|------|
| `gyro-wrapper/src/lib.rs` | Rust C API（`gyrocore_*` + `gyroflow_*`） |
| `Spectrum/Services/GyroCore.swift` | `GyroConfig`, `GyroCoreProvider`, `GyroCore`, `GyroFlowCore` |
| `Spectrum/Views/Detail/AVFMetalView.swift` | GPU renderFrame() pipeline, matTex upload |
| `Spectrum/Views/Detail/MetalShaders.swift` | Metal shader（YCbCr→RGB + warp） |
| `Spectrum/Views/Detail/VideoController.swift` | 生命週期管理（start/stop） |
| `Spectrum/Views/Detail/PhotoDetailView.swift` | `startGyro()` 路由、`buildGyroConfig()` |
| `Spectrum/Views/SettingsView.swift` | `gyroMethod` picker UI |
