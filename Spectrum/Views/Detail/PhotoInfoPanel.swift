import SwiftUI

struct PhotoInfoPanel: View {
    let item: PhotoItem
    var isHDR: Bool = false
    @FocusedValue(\.gyroConfigBinding) var gyroConfigBinding
    @FocusedValue(\.videoController) var videoController

    @State private var selectedTab: InspectorTab = .info

    private enum InspectorTab: Hashable {
        case info, gyro
    }

    var body: some View {
        if item.isVideo {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Info").tag(InspectorTab.info)
                    Text("Gyro").tag(InspectorTab.gyro)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                switch selectedTab {
                case .info:
                    infoForm
                case .gyro:
                    if let binding = gyroConfigBinding {
                        GyroConfigSection(gyroConfigJson: binding)
                    } else {
                        Text("No video selected")
                            .foregroundStyle(.secondary)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(minWidth: 250)
        } else {
            infoForm
                .frame(minWidth: 250)
        }
    }

    private var infoForm: some View {
        Form {
            fileSection
            if item.isVideo {
                videoSection
            } else {
                cameraSection
                exposureSection
                lensSpecSection
                technicalSection
            }
            locationSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    @ViewBuilder
    private var fileSection: some View {
        Section("File") {
            LabeledContent("Name", value: item.fileName)
            LabeledContent("Path", value: item.filePath)
            LabeledContent("Size", value: formatFileSize(item.fileSize))
            LabeledContent("Dimensions", value: "\(item.pixelWidth) x \(item.pixelHeight)")
            LabeledContent("Date Taken", value: item.dateTaken.shortDate)
            if let tz = item.offsetTimeOriginal {
                LabeledContent("Timezone", value: tz)
            }
            if isHDR {
                LabeledContent("Dynamic Range") {
                    Text("HDR")
                        .foregroundStyle(.orange)
                        .fontWeight(.semibold)
                }
            }
            if let depth = item.colorDepth {
                LabeledContent("Color Depth", value: "\(depth)-bit")
            }
            if let profile = item.profileName {
                LabeledContent("Color Profile", value: profile)
            }
            if let headroom = item.headroom {
                LabeledContent("Headroom", value: String(format: "%.2f", headroom))
            }
            if let orient = item.orientation {
                LabeledContent("Orientation", value: "\(orient)")
            }
            if let dw = item.dpiWidth, let dh = item.dpiHeight {
                LabeledContent("DPI", value: "\(Int(dw)) x \(Int(dh))")
            }
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        Section("Video") {
            if let duration = item.duration {
                LabeledContent("Duration", value: formatDuration(duration))
            }
            if item.fileSize > 0, let duration = item.duration, duration > 0 {
                LabeledContent("Bitrate", value: formatBitrate(Double(item.fileSize) * 8 / duration))
            }
            if let codec = item.videoCodec {
                LabeledContent("Video Codec", value: codec)
            }
            if let codec = item.audioCodec {
                LabeledContent("Audio Codec", value: codec)
            }
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        let hasContent = item.cameraMake != nil || item.cameraModel != nil
            || item.lensModel != nil || item.software != nil
        if hasContent {
            Section("Camera") {
                if let make = item.cameraMake {
                    LabeledContent("Make", value: make)
                }
                if let model = item.cameraModel {
                    LabeledContent("Model", value: model)
                }
                if let lens = item.lensModel {
                    LabeledContent("Lens", value: lens)
                }
                if let sw = item.software {
                    LabeledContent("Software", value: sw)
                }
            }
        }
    }

    @ViewBuilder
    private var exposureSection: some View {
        let hasContent = item.aperture != nil || item.shutterSpeed != nil
            || item.iso != nil || item.focalLength != nil
            || item.exposureBias != nil || item.exposureProgram != nil
        if hasContent {
            Section("Exposure") {
                if let aperture = item.aperture {
                    LabeledContent("Aperture", value: String(format: "f/%.1f", aperture))
                }
                if let shutter = item.shutterSpeed {
                    LabeledContent("Shutter", value: shutter)
                }
                if let iso = item.iso {
                    LabeledContent("ISO", value: "\(iso)")
                }
                if let focal = item.focalLength {
                    if let focal35 = item.focalLenIn35mm {
                        LabeledContent("Focal Length", value: String(format: "%.0fmm (35mm eq: %dmm)", focal, focal35))
                    } else {
                        LabeledContent("Focal Length", value: String(format: "%.0fmm", focal))
                    }
                }
                if let bias = item.exposureBias {
                    LabeledContent("Exposure Bias", value: String(format: "%+.1f EV", bias))
                }
                if let prog = item.exposureProgram {
                    LabeledContent("Exposure Program", value: formatExposureProgram(prog))
                }
                if let meter = item.meteringMode {
                    LabeledContent("Metering", value: formatMeteringMode(meter))
                }
                if let flash = item.flash {
                    LabeledContent("Flash", value: formatFlash(flash))
                }
                if let wb = item.whiteBalance {
                    LabeledContent("White Balance", value: wb == 0 ? String(localized: "Auto") : String(localized: "Manual"))
                }
                if let brightness = item.brightnessValue {
                    LabeledContent("Brightness", value: String(format: "%.2f", brightness))
                }
                if let scene = item.sceneCaptureType {
                    LabeledContent("Scene Type", value: formatSceneCaptureType(scene))
                }
                if let light = item.lightSource {
                    LabeledContent("Light Source", value: formatLightSource(light))
                }
            }
        }
    }

    @ViewBuilder
    private var lensSpecSection: some View {
        if let spec = item.lensSpecification, spec.count >= 4 {
            Section("Lens Specification") {
                LabeledContent("Focal Range", value: String(format: "%.0f–%.0fmm", spec[0], spec[1]))
                if spec[2] > 0 && spec[3] > 0 {
                    if spec[2] == spec[3] {
                        LabeledContent("Max Aperture", value: String(format: "f/%.1f", spec[2]))
                    } else {
                        LabeledContent("Max Aperture", value: String(format: "f/%.1f–%.1f", spec[2], spec[3]))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var technicalSection: some View {
        let hasContent = item.exifVersion != nil || item.imageStabilization != nil
            || item.contrast != nil || item.saturation != nil || item.sharpness != nil
            || item.digitalZoomRatio != nil
        if hasContent {
            Section("Technical") {
                if let ver = item.exifVersion {
                    LabeledContent("EXIF Version", value: ver)
                }
                if let stab = item.imageStabilization {
                    LabeledContent("Image Stabilization", value: stab == 1 ? String(localized: "On") : String(localized: "Off"))
                }
                if let c = item.contrast {
                    LabeledContent("Contrast", value: formatLevel(c))
                }
                if let s = item.saturation {
                    LabeledContent("Saturation", value: formatLevel(s))
                }
                if let s = item.sharpness {
                    LabeledContent("Sharpness", value: formatLevel(s))
                }
                if let zoom = item.digitalZoomRatio, zoom > 0 {
                    LabeledContent("Digital Zoom", value: String(format: "%.1fx", zoom))
                }
            }
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        if item.latitude != nil || item.longitude != nil {
            Section("Location") {
                if let lat = item.latitude, let lon = item.longitude {
                    LabeledContent("Coordinates", value: String(format: "%.4f, %.4f", lat, lon))
                }
            }
        }
    }

    // MARK: - Formatters

    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatBitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        } else {
            return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
        }
    }

    private func formatExposureProgram(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Not Defined")
        case 1: return String(localized: "Manual")
        case 2: return String(localized: "Program AE")
        case 3: return String(localized: "Aperture Priority")
        case 4: return String(localized: "Shutter Priority")
        case 5: return String(localized: "Creative")
        case 6: return String(localized: "Action")
        case 7: return String(localized: "Portrait")
        case 8: return String(localized: "Landscape")
        default: return "Unknown (\(value))"
        }
    }

    private func formatMeteringMode(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Unknown")
        case 1: return String(localized: "Average")
        case 2: return String(localized: "Center-weighted")
        case 3: return String(localized: "Spot")
        case 4: return String(localized: "Multi-spot")
        case 5: return String(localized: "Multi-segment")
        case 6: return String(localized: "Partial")
        default: return "Other (\(value))"
        }
    }

    private func formatFlash(_ value: Int) -> String {
        let fired = (value & 0x01) != 0
        let mode = (value >> 3) & 0x03
        var parts: [String] = []
        parts.append(fired ? String(localized: "Fired") : String(localized: "No Flash"))
        switch mode {
        case 1: parts.append(String(localized: "Compulsory"))
        case 2: parts.append(String(localized: "Suppressed"))
        case 3: parts.append(String(localized: "Auto"))
        default: break
        }
        return parts.joined(separator: ", ")
    }

    private func formatSceneCaptureType(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Standard")
        case 1: return String(localized: "Landscape")
        case 2: return String(localized: "Portrait")
        case 3: return String(localized: "Night")
        default: return "Unknown (\(value))"
        }
    }

    private func formatLightSource(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Unknown")
        case 1: return String(localized: "Daylight")
        case 2: return String(localized: "Fluorescent")
        case 3: return String(localized: "Tungsten")
        case 4: return String(localized: "Flash")
        case 9: return String(localized: "Fine Weather")
        case 10: return String(localized: "Cloudy")
        case 11: return String(localized: "Shade")
        case 17: return String(localized: "Standard Light A")
        case 18: return String(localized: "Standard Light B")
        case 19: return String(localized: "Standard Light C")
        case 20: return "D55"
        case 21: return "D65"
        case 22: return "D75"
        case 23: return "D50"
        case 255: return String(localized: "Other")
        default: return "Unknown (\(value))"
        }
    }

    private func formatLevel(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Normal")
        case 1: return String(localized: "Low")
        case 2: return String(localized: "High")
        default: return "Unknown (\(value))"
        }
    }
}

// MARK: - Per-Video Gyro Config

private struct GyroConfigSection: View {
    @Binding var gyroConfigJson: String?

    // Global settings (read-only, for "Copy from Global" and display)
    @AppStorage("gyroSmooth") private var globalSmooth: Double = 0.5
    @AppStorage("gyroOffsetMs") private var globalOffsetMs: Double = 0
    @AppStorage("gyroIntegrationMethod") private var globalIntegrationMethod: Int = -1
    @AppStorage("gyroImuOrientation") private var globalImuOrientation: String = ""
    @AppStorage("gyroFov") private var globalFov: Double = 1.0
    @AppStorage("gyroLensCorrectionAmount") private var globalLensCorrectionAmount: Double = 1.0
    @AppStorage("gyroZoomingMethod") private var globalZoomingMethod: Int = 1
    @AppStorage("gyroZoomingAlgorithm") private var globalZoomingAlgorithm: Int = 1
    @AppStorage("gyroAdaptiveZoom") private var globalAdaptiveZoom: Double = 4.0
    @AppStorage("gyroMaxZoom") private var globalMaxZoom: Double = 130.0
    @AppStorage("gyroMaxZoomIterations") private var globalMaxZoomIterations: Int = 5
    @AppStorage("gyroUseGravityVectors") private var globalUseGravityVectors: Bool = false
    @AppStorage("gyroVideoSpeed") private var globalVideoSpeed: Double = 1.0
    @AppStorage("gyroHorizonLockEnabled") private var globalHorizonLockEnabled: Bool = false
    @AppStorage("gyroHorizonLockAmount") private var globalHorizonLockAmount: Double = 1.0
    @AppStorage("gyroHorizonLockRoll") private var globalHorizonLockRoll: Double = 0
    @AppStorage("gyroPerAxis") private var globalPerAxis: Bool = false
    @AppStorage("gyroSmoothnessPitch") private var globalSmoothnessPitch: Double = 0
    @AppStorage("gyroSmoothnessYaw") private var globalSmoothnessYaw: Double = 0
    @AppStorage("gyroSmoothnessRoll") private var globalSmoothnessRoll: Double = 0

    @State private var config = GyroConfig()

    private var hasCustom: Bool { gyroConfigJson != nil }

    @State private var dirty = false

    var body: some View {
        Form {
            Section {
                Toggle("Custom Gyro Config", isOn: Binding(
                    get: { hasCustom },
                    set: { on in
                        if on {
                            config = globalConfig()
                            save()
                        } else {
                            gyroConfigJson = nil
                            dirty = false
                        }
                    }
                ))

                if !hasCustom {
                    Text("Using global settings")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            if hasCustom {
                Section {
                    Button("Apply") {
                        save()
                        dirty = false
                    }
                    .disabled(!dirty)

                    HStack {
                        Button("Copy from Global") {
                            config = globalConfig()
                            dirty = true
                        }
                        Button("Reset to Global") {
                            gyroConfigJson = nil
                            dirty = false
                        }
                    }
                    .font(.caption)
                }

                Section("Horizon Lock") {
                    Toggle("Enable Horizon Lock", isOn: binding(\.horizonLockEnabled))
                        .onChange(of: config.horizonLockEnabled) { _, on in
                            if on && config.horizonLockAmount < 0.01 {
                                config.horizonLockAmount = 1.0
                                dirty = true
                            }
                        }
                    if config.horizonLockEnabled {
                        sliderRow("Lock Amount", value: binding(\.horizonLockAmount), range: 0...1.0, step: 0.01)
                        sliderRow("Roll (°)", value: binding(\.horizonLockRoll), range: -180...180, step: 0.1)
                    }
                }

                Section("Smoothing") {
                    sliderRow("Smoothness", value: binding(\.smooth), range: 0.01...1.0, step: 0.01)

                    Toggle("Per-axis smoothing", isOn: binding(\.perAxis))

                    if config.perAxis {
                        sliderRow("Pitch", value: binding(\.smoothnessPitch), range: 0...1.0, step: 0.01)
                        sliderRow("Yaw", value: binding(\.smoothnessYaw), range: 0...1.0, step: 0.01)
                        sliderRow("Roll", value: binding(\.smoothnessRoll), range: 0...1.0, step: 0.01)
                    }
                }

                Section("Sync & Lens") {
                    HStack {
                        Text("Gyro Offset (ms)")
                        Spacer()
                        TextField("", value: binding(\.gyroOffsetMs), format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("IMU") {
                    Picker("Integration", selection: binding(\.integrationMethod)) {
                        Text("Auto").tag(nil as Int?)
                        Text("Built-in Quaternions").tag(0 as Int?)
                        Text(verbatim: "Complementary").tag(1 as Int?)
                        Text(verbatim: "VQF").tag(2 as Int?)
                        Text("Simple Gyro").tag(3 as Int?)
                        Text("Simple Gyro + Accel").tag(4 as Int?)
                        Text(verbatim: "Mahony").tag(5 as Int?)
                        Text(verbatim: "Madgwick").tag(6 as Int?)
                    }

                    HStack {
                        Text("IMU Orientation")
                        Spacer()
                        if config.imuOrientation == nil || config.imuOrientation?.isEmpty == true {
                            Text("Auto")
                                .foregroundStyle(.secondary)
                        }
                        TextField("", text: Binding(
                            get: { config.imuOrientation ?? "" },
                            set: { newValue in
                                config.imuOrientation = newValue.isEmpty ? nil : newValue
                                dirty = true
                            }
                        ))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }

                    Toggle("Use gravity vectors", isOn: binding(\.useGravityVectors))
                }

                Section("Stabilization") {
                    sliderRow("FOV", value: binding(\.fov), range: 0.1...2.0, step: 0.01)
                    sliderRow("Lens Correction", value: binding(\.lensCorrectionAmount), range: 0...1.0, step: 0.01)

                    Picker("Zooming Method", selection: binding(\.zoomingMethod)) {
                        Text("None").tag(0)
                        Text("Dynamic").tag(1)
                        Text("Static").tag(2)
                    }

                    if config.zoomingMethod == 1 {
                        Picker("Zooming Algorithm", selection: binding(\.zoomingAlgorithm)) {
                            Text("Gaussian Filter").tag(0)
                            Text("Envelope Follower").tag(1)
                        }
                        sliderRow("Adaptive Zoom (s)", value: binding(\.adaptiveZoom), range: 0.1...15.0, step: 0.1)
                    }

                    sliderRow("Max Zoom (%)", value: binding(\.maxZoom), range: 100...300, step: 1)

                    Stepper("Max Zoom Iterations: \(config.maxZoomIterations)",
                            value: binding(\.maxZoomIterations), in: 1...20)
                }

                Section("Video Speed") {
                    sliderRow("Speed", value: binding(\.videoSpeed), range: 0.1...4.0, step: 0.1)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    // MARK: - Helpers

    private func globalConfig() -> GyroConfig {
        GyroConfig(
            smooth: globalSmooth,
            gyroOffsetMs: globalOffsetMs,
            integrationMethod: globalIntegrationMethod == -1 ? nil : globalIntegrationMethod,
            imuOrientation: globalImuOrientation.isEmpty ? nil : globalImuOrientation,
            fov: globalFov,
            lensCorrectionAmount: globalLensCorrectionAmount,
            zoomingMethod: globalZoomingMethod,
            zoomingAlgorithm: globalZoomingAlgorithm,
            adaptiveZoom: globalAdaptiveZoom,
            maxZoom: globalMaxZoom,
            maxZoomIterations: globalMaxZoomIterations,
            useGravityVectors: globalUseGravityVectors,
            videoSpeed: globalVideoSpeed,
            horizonLockEnabled: globalHorizonLockEnabled,
            horizonLockAmount: globalHorizonLockAmount,
            horizonLockRoll: globalHorizonLockRoll,
            perAxis: globalPerAxis,
            smoothnessPitch: globalSmoothnessPitch,
            smoothnessYaw: globalSmoothnessYaw,
            smoothnessRoll: globalSmoothnessRoll,
            lensDbDir: "/Applications/Gyroflow.app/Contents/Resources"
        )
    }

    private func load() {
        guard let json = gyroConfigJson,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GyroConfig.self, from: data)
        else { return }
        config = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        gyroConfigJson = String(data: data, encoding: .utf8)
    }

    /// Two-way binding to a GyroConfig property. Only updates local state; user must press Apply.
    private func binding<T>(_ keyPath: WritableKeyPath<GyroConfig, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                config[keyPath: keyPath] = newValue
                dirty = true
            }
        )
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
