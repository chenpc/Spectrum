import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            CacheSettingsTab()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
            GyroSettingsTab()
                .tabItem { Label("Gyro", systemImage: "gyroscope") }
            // TODO: [Backlog] Face/Object Detection — Vision framework VNDetectFaceRectanglesRequest
        }
        .frame(width: 460, height: 520)
    }
}

// MARK: - General (Appearance + Playback)

private struct GeneralSettingsTab: View {
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("showMPVDiagBadge") private var showMPVDiagBadge: Bool = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.radioGroup)
            }

            Section("Playback") {
                Toggle("Show diagnostics badge", isOn: $showMPVDiagBadge)
            }
        }
        .formStyle(.grouped)
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
                    Text(verbatim: "100 MB").tag(100)
                    Text(verbatim: "250 MB").tag(250)
                    Text(verbatim: "500 MB").tag(500)
                    Text(verbatim: "1 GB").tag(1000)
                    Text(verbatim: "2 GB").tag(2000)
                    Text(verbatim: "∞").tag(0)
                }
            }
        }
        .formStyle(.grouped)
        .task { thumbSize = await ThumbnailService.shared.diskCacheSize() }
    }
}

// MARK: - Gyro

private struct GyroSettingsTab: View {
    @AppStorage("gyroStabEnabled") private var gyroStabEnabled: Bool = true
    @AppStorage("gyroSmooth") private var gyroSmooth: Double = 0.5
    @AppStorage("gyroOffsetMs") private var gyroOffsetMs: Double = 0
    @AppStorage("gyroLensPath") private var gyroLensPath: String = ""
    @AppStorage("gyroIntegrationMethod") private var integrationMethod: Int = -1
    @AppStorage("gyroImuOrientation") private var imuOrientation: String = ""
    @AppStorage("gyroFov") private var fov: Double = 1.0
    @AppStorage("gyroLensCorrectionAmount") private var lensCorrectionAmount: Double = 1.0
    @AppStorage("gyroZoomingMethod") private var zoomingMethod: Int = 1
    @AppStorage("gyroZoomingAlgorithm") private var zoomingAlgorithm: Int = 1
    @AppStorage("gyroAdaptiveZoom") private var adaptiveZoom: Double = 4.0
    @AppStorage("gyroMaxZoom") private var maxZoom: Double = 130.0
    @AppStorage("gyroMaxZoomIterations") private var maxZoomIterations: Int = 5
    @AppStorage("gyroUseGravityVectors") private var useGravityVectors: Bool = false
    @AppStorage("gyroVideoSpeed") private var videoSpeed: Double = 1.0
    @AppStorage("gyroHorizonLockEnabled") private var horizonLockEnabled: Bool = false
    @AppStorage("gyroHorizonLockAmount") private var horizonLockAmount: Double = 1.0
    @AppStorage("gyroHorizonLockRoll") private var horizonLockRoll: Double = 0
    @AppStorage("gyroPerAxis") private var perAxis: Bool = false
    @AppStorage("gyroSmoothnessPitch") private var smoothnessPitch: Double = 0
    @AppStorage("gyroSmoothnessYaw") private var smoothnessYaw: Double = 0
    @AppStorage("gyroSmoothnessRoll") private var smoothnessRoll: Double = 0
    @AppStorage("gyroMethod") private var gyroMethod: String = "spectrum"
    @State private var gyroDylibFound: Bool = false

    var body: some View {
        Form {
            // MARK: Gyro Method
            Section("Gyro Method") {
                Picker("Method", selection: $gyroMethod) {
                    Text("Spectrum").tag("spectrum")
                    Text("Gyroflow").tag("gyroflow")
                }
                .pickerStyle(.radioGroup)
            }

            // MARK: Enable + dylib status
            Section {
                Toggle("Enable Gyroflow stabilization", isOn: $gyroStabEnabled)

                HStack(spacing: 5) {
                    Image(systemName: gyroDylibFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(gyroDylibFound ? .green : .red)
                    Text(verbatim: gyroDylibFound
                         ? "libgyrocore_c.dylib found"
                         : "libgyrocore_c.dylib not found")
                        .foregroundStyle(gyroDylibFound ? Color.secondary : Color.red)
                }
                .font(.caption)

                if !gyroDylibFound {
                    Text(verbatim: "cd MyPhoto/gyro-wrapper && cargo build --release")
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
                        integrationMethod = -1
                        imuOrientation = ""
                        fov = 1.0
                        lensCorrectionAmount = 1.0
                        zoomingMethod = 1
                        zoomingAlgorithm = 1
                        adaptiveZoom = 4.0
                        maxZoom = 130.0
                        maxZoomIterations = 5
                        useGravityVectors = false
                        videoSpeed = 1.0
                        horizonLockEnabled = false
                        horizonLockAmount = 1.0
                        horizonLockRoll = 0
                        perAxis = false
                        smoothnessPitch = 0
                        smoothnessYaw = 0
                        smoothnessRoll = 0
                    }
                }

                // MARK: Horizon Lock
                Section("Horizon Lock") {
                    Toggle("Enable Horizon Lock", isOn: $horizonLockEnabled)
                        .onChange(of: horizonLockEnabled) { _, on in
                            if on && horizonLockAmount < 0.01 { horizonLockAmount = 1.0 }
                        }
                    if horizonLockEnabled {
                        sliderRow("Lock Amount", value: $horizonLockAmount, range: 0...1.0, step: 0.01)
                        sliderRow("Roll (°)", value: $horizonLockRoll, range: -180...180, step: 0.1)
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
                        Text("0 = use global Smoothness value")
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
                    Text("Positive = gyro leads video")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Text("Lens Profile")
                        Spacer()
                        if gyroLensPath.isEmpty {
                            Text("Auto-detect")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(URL(fileURLWithPath: gyroLensPath).lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    HStack {
                        Button("Choose .gyroflow file...") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.init(filenameExtension: "gyroflow")!]
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                gyroLensPath = url.path
                            }
                        }
                        if !gyroLensPath.isEmpty {
                            Button("Clear") { gyroLensPath = "" }
                        }
                    }
                }

                // MARK: IMU
                Section("IMU") {
                    Picker("Integration Method", selection: $integrationMethod) {
                        Text("Auto").tag(-1)
                        Text("Built-in Quaternions").tag(0)
                        Text(verbatim: "Complementary").tag(1)
                        Text(verbatim: "VQF").tag(2)
                        Text("Simple Gyro").tag(3)
                        Text("Simple Gyro + Accel").tag(4)
                        Text(verbatim: "Mahony").tag(5)
                        Text(verbatim: "Madgwick").tag(6)
                    }

                    HStack {
                        Text("IMU Orientation")
                        Spacer()
                        if imuOrientation.isEmpty {
                            Text("Auto")
                                .foregroundStyle(.secondary)
                        }
                        TextField("", text: $imuOrientation)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    if !imuOrientation.isEmpty {
                        Button("Reset to Auto") { imuOrientation = "" }
                            .font(.caption)
                    }

                    Toggle("Use gravity vectors", isOn: $useGravityVectors)
                }

                // MARK: Stabilization
                Section("Stabilization") {
                    sliderRow("FOV", value: $fov, range: 0.1...2.0, step: 0.01)

                    sliderRow("Lens Correction", value: $lensCorrectionAmount, range: 0...1.0, step: 0.01)

                    Picker("Zooming Method", selection: $zoomingMethod) {
                        Text("None").tag(0)
                        Text("Dynamic").tag(1)
                        Text("Static").tag(2)
                    }

                    if zoomingMethod == 1 {
                        Picker("Zooming Algorithm", selection: $zoomingAlgorithm) {
                            Text("Gaussian Filter").tag(0)
                            Text("Envelope Follower").tag(1)
                        }
                        sliderRow("Adaptive Zoom (s)", value: $adaptiveZoom, range: 0.1...15.0, step: 0.1)
                    }

                    sliderRow("Max Zoom (%)", value: $maxZoom, range: 100...300, step: 1)

                    Stepper("Max Zoom Iterations: \(maxZoomIterations)", value: $maxZoomIterations, in: 1...20)
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

    private func sliderRow(_ label: LocalizedStringKey, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(verbatim: step >= 1 ? String(format: "%.0f", value.wrappedValue)
                     : step >= 0.1 ? String(format: "%.1f", value.wrappedValue)
                     : String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
