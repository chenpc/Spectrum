import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CacheSettingsTab()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
            PlaybackSettingsTab()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            GyroSettingsTab()
                .tabItem { Label("Gyro", systemImage: "gyroscope") }
        }
        .frame(width: 460, height: 520)
    }
}

// MARK: - Cache

private struct CacheSettingsTab: View {
    @AppStorage("thumbnailCacheLimitMB") private var thumbnailCacheLimitMB: Int = 500
    @State private var thumbSize: Int64 = 0

    var body: some View {
        Form {
            Section("Thumbnails") {
                HStack {
                    Text("Disk Usage")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: thumbSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        Task {
                            await ThumbnailService.shared.clearCache()
                            ThumbnailCacheState.shared.invalidate()
                            thumbSize = await ThumbnailService.shared.diskCacheSize()
                        }
                    }
                }

                Picker("Size Limit", selection: $thumbnailCacheLimitMB) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                    Text("∞").tag(0)
                }
            }
        }
        .formStyle(.grouped)
        .task { thumbSize = await ThumbnailService.shared.diskCacheSize() }
    }
}

// MARK: - Playback

private struct PlaybackSettingsTab: View {
    @AppStorage("showMPVDiagBadge") private var showMPVDiagBadge: Bool = true
    @AppStorage("videoPlayer") private var videoPlayer: String = "libmpv"
    @AppStorage("mpvHwdec") private var mpvHwdec: String = "auto"
    @AppStorage("mpvAVSync") private var mpvAVSync: Bool = true
    @AppStorage("mpvFrameDrop") private var mpvFrameDrop: Bool = true

    var body: some View {
        Form {
            Section("Video Decoder") {
                if LibMPV.shared.ok {
                    Picker("Decoder", selection: $videoPlayer) {
                        Text("libmpv").tag("libmpv")
                        Text("AVPlayer").tag("avplayer")
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text("libmpv 不可用，僅 AVPlayer")
                        .foregroundStyle(.secondary)
                }
            }

            if LibMPV.shared.ok {
                Section("Hardware Decode") {
                    Picker("hwdec", selection: $mpvHwdec) {
                        Text("auto").tag("auto")
                        Text("videotoolbox").tag("videotoolbox")
                        Text("videotoolbox-copy").tag("videotoolbox-copy")
                        Text("no (software)").tag("no")
                    }
                    Text("變更於下次載入影片生效")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Sync & Drop") {
                Toggle("Video/Audio Sync", isOn: $mpvAVSync)
                    .help("關閉後影音可不同步，不會為追趕 audio 而丟幀")
                Toggle("Frame Drop", isOn: $mpvFrameDrop)
                    .help("關閉後完全不丟幀（可能導致 audio 延遲）")
                Text("變更於下次載入影片生效")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Diagnostics") {
                Toggle("Show diagnostics badge", isOn: $showMPVDiagBadge)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gyro

private struct GyroSettingsTab: View {
    @AppStorage("gyroStabEnabled") private var gyroStabEnabled: Bool = true
    @AppStorage("gyroSmooth") private var gyroSmooth: Double = 0.5
    @AppStorage("gyroOffsetMs") private var gyroOffsetMs: Double = 0
    @AppStorage("gyroLensPath") private var gyroLensPath: String = ""
    @AppStorage("gyroIntegrationMethod") private var integrationMethod: Int = 2
    @AppStorage("gyroImuOrientation") private var imuOrientation: String = "YXz"
    @AppStorage("gyroFov") private var fov: Double = 1.0
    @AppStorage("gyroLensCorrectionAmount") private var lensCorrectionAmount: Double = 1.0
    @AppStorage("gyroZoomingMethod") private var zoomingMethod: Int = 1
    @AppStorage("gyroAdaptiveZoom") private var adaptiveZoom: Double = 4.0
    @AppStorage("gyroMaxZoom") private var maxZoom: Double = 130.0
    @AppStorage("gyroMaxZoomIterations") private var maxZoomIterations: Int = 5
    @AppStorage("gyroUseGravityVectors") private var useGravityVectors: Bool = false
    @AppStorage("gyroVideoSpeed") private var videoSpeed: Double = 1.0
    @AppStorage("gyroHorizonLockAmount") private var horizonLockAmount: Double = 0
    @AppStorage("gyroHorizonLockRoll") private var horizonLockRoll: Double = 0
    @AppStorage("gyroPerAxis") private var perAxis: Bool = false
    @AppStorage("gyroSmoothnessPitch") private var smoothnessPitch: Double = 0
    @AppStorage("gyroSmoothnessYaw") private var smoothnessYaw: Double = 0
    @AppStorage("gyroSmoothnessRoll") private var smoothnessRoll: Double = 0

    @State private var gyroDylibFound: Bool = false

    var body: some View {
        Form {
            // MARK: Enable + dylib status
            Section {
                Toggle("啟用 Gyroflow 校正（mpv 播放時）", isOn: $gyroStabEnabled)

                HStack(spacing: 5) {
                    Image(systemName: gyroDylibFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(gyroDylibFound ? .green : .red)
                    Text(gyroDylibFound
                         ? "libgyrocore_c.dylib 已找到"
                         : "找不到 libgyrocore_c.dylib")
                        .foregroundStyle(gyroDylibFound ? Color.secondary : Color.red)
                }
                .font(.caption)

                if !gyroDylibFound {
                    Text("cd MyPhoto/gyro-wrapper && cargo build --release")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if gyroStabEnabled {
                // MARK: Reset
                Section {
                    Button("Reset to Defaults") {
                        gyroSmooth = 0.5
                        gyroOffsetMs = 0
                        gyroLensPath = ""
                        integrationMethod = 2
                        imuOrientation = "YXz"
                        fov = 1.0
                        lensCorrectionAmount = 1.0
                        zoomingMethod = 1
                        adaptiveZoom = 4.0
                        maxZoom = 130.0
                        maxZoomIterations = 5
                        useGravityVectors = false
                        videoSpeed = 1.0
                        horizonLockAmount = 0
                        horizonLockRoll = 0
                        perAxis = false
                        smoothnessPitch = 0
                        smoothnessYaw = 0
                        smoothnessRoll = 0
                    }
                }

                // MARK: Smoothing
                Section("Smoothing") {
                    sliderRow("Smoothness", value: $gyroSmooth, range: 0.01...1.0, step: 0.01)

                    Toggle("Per-axis smoothing", isOn: $perAxis)

                    if perAxis {
                        sliderRow("Pitch", value: $smoothnessPitch, range: 0...1.0, step: 0.01)
                        sliderRow("Yaw", value: $smoothnessYaw, range: 0...1.0, step: 0.01)
                        sliderRow("Roll", value: $smoothnessRoll, range: 0...1.0, step: 0.01)
                        Text("0 = 使用全域 Smoothness 值")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // MARK: Sync & Lens
                Section("Sync & Lens") {
                    HStack {
                        Text("Gyro Offset (ms)")
                        Spacer()
                        TextField("", value: $gyroOffsetMs, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("正值 = gyro 超前影像")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Text("Lens Profile")
                        Spacer()
                        if gyroLensPath.isEmpty {
                            Text("未設定")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(URL(fileURLWithPath: gyroLensPath).lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    HStack {
                        Button("選擇 .gyroflow 檔案…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.init(filenameExtension: "gyroflow")!]
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                gyroLensPath = url.path
                            }
                        }
                        if !gyroLensPath.isEmpty {
                            Button("清除") { gyroLensPath = "" }
                        }
                    }
                }

                // MARK: IMU
                Section("IMU") {
                    Picker("Integration Method", selection: $integrationMethod) {
                        Text("Complementary").tag(0)
                        Text("Complementary2").tag(1)
                        Text("VQF").tag(2)
                    }

                    HStack {
                        Text("IMU Orientation")
                        Spacer()
                        TextField("", text: $imuOrientation)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }

                    Toggle("Use gravity vectors", isOn: $useGravityVectors)
                }

                // MARK: Stabilization
                Section("Stabilization") {
                    sliderRow("FOV", value: $fov, range: 0.1...2.0, step: 0.01)

                    sliderRow("Lens Correction", value: $lensCorrectionAmount, range: 0...1.0, step: 0.01)

                    Picker("Zooming Method", selection: $zoomingMethod) {
                        Text("None").tag(0)
                        Text("Envelope Follower").tag(1)
                    }

                    if zoomingMethod == 1 {
                        sliderRow("Adaptive Zoom (s)", value: $adaptiveZoom, range: 0.1...15.0, step: 0.1)
                    }

                    sliderRow("Max Zoom (%)", value: $maxZoom, range: 100...300, step: 1)

                    Stepper("Max Zoom Iterations: \(maxZoomIterations)", value: $maxZoomIterations, in: 1...20)
                }

                // MARK: Horizon Lock
                Section("Horizon Lock") {
                    sliderRow("Lock Amount", value: $horizonLockAmount, range: 0...1.0, step: 0.01)
                    sliderRow("Roll (°)", value: $horizonLockRoll, range: -180...180, step: 0.1)
                }

                // MARK: Playback
                Section("Video Speed") {
                    sliderRow("Speed", value: $videoSpeed, range: 0.1...4.0, step: 0.1)
                }
            }
        }
        .formStyle(.grouped)
        .task { gyroDylibFound = GyroCore.dylibFound }
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(step >= 1 ? String(format: "%.0f", value.wrappedValue)
                     : step >= 0.1 ? String(format: "%.1f", value.wrappedValue)
                     : String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
