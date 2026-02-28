import SwiftUI

struct PhotoInfoPanel: View {
    @Bindable var photo: Photo
    var isHDR: Bool = false

    @State private var selectedTab: InspectorTab = .info

    private enum InspectorTab: Hashable {
        case info, gyro
    }

    var body: some View {
        if photo.isVideo {
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
                    GyroConfigSection(photo: photo)
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
            if photo.isVideo {
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
            LabeledContent("Name", value: photo.fileName)
            LabeledContent("Path", value: photo.filePath)
            LabeledContent("Size", value: formatFileSize(photo.fileSize))
            LabeledContent("Dimensions", value: "\(photo.pixelWidth) x \(photo.pixelHeight)")
            LabeledContent("Date Taken", value: photo.dateTaken.shortDate)
            if let tz = photo.offsetTimeOriginal {
                LabeledContent("Timezone", value: tz)
            }
            if isHDR {
                LabeledContent("Dynamic Range") {
                    Text("HDR")
                        .foregroundStyle(.orange)
                        .fontWeight(.semibold)
                }
            }
            if let depth = photo.colorDepth {
                LabeledContent("Color Depth", value: "\(depth)-bit")
            }
            if let profile = photo.profileName {
                LabeledContent("Color Profile", value: profile)
            }
            if let headroom = photo.headroom {
                LabeledContent("Headroom", value: String(format: "%.2f", headroom))
            }
            if let orient = photo.orientation {
                LabeledContent("Orientation", value: "\(orient)")
            }
            if let dw = photo.dpiWidth, let dh = photo.dpiHeight {
                LabeledContent("DPI", value: "\(Int(dw)) x \(Int(dh))")
            }
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        Section("Video") {
            if let duration = photo.duration {
                LabeledContent("Duration", value: formatDuration(duration))
            }
            if let codec = photo.videoCodec {
                LabeledContent("Video Codec", value: codec)
            }
            if let codec = photo.audioCodec {
                LabeledContent("Audio Codec", value: codec)
            }
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        let hasContent = photo.cameraMake != nil || photo.cameraModel != nil
            || photo.lensModel != nil || photo.software != nil
        if hasContent {
            Section("Camera") {
                if let make = photo.cameraMake {
                    LabeledContent("Make", value: make)
                }
                if let model = photo.cameraModel {
                    LabeledContent("Model", value: model)
                }
                if let lens = photo.lensModel {
                    LabeledContent("Lens", value: lens)
                }
                if let sw = photo.software {
                    LabeledContent("Software", value: sw)
                }
            }
        }
    }

    @ViewBuilder
    private var exposureSection: some View {
        let hasContent = photo.aperture != nil || photo.shutterSpeed != nil
            || photo.iso != nil || photo.focalLength != nil
            || photo.exposureBias != nil || photo.exposureProgram != nil
        if hasContent {
            Section("Exposure") {
                if let aperture = photo.aperture {
                    LabeledContent("Aperture", value: String(format: "f/%.1f", aperture))
                }
                if let shutter = photo.shutterSpeed {
                    LabeledContent("Shutter", value: shutter)
                }
                if let iso = photo.iso {
                    LabeledContent("ISO", value: "\(iso)")
                }
                if let focal = photo.focalLength {
                    if let focal35 = photo.focalLenIn35mm {
                        LabeledContent("Focal Length", value: String(format: "%.0fmm (35mm eq: %dmm)", focal, focal35))
                    } else {
                        LabeledContent("Focal Length", value: String(format: "%.0fmm", focal))
                    }
                }
                if let bias = photo.exposureBias {
                    LabeledContent("Exposure Bias", value: String(format: "%+.1f EV", bias))
                }
                if let prog = photo.exposureProgram {
                    LabeledContent("Exposure Program", value: formatExposureProgram(prog))
                }
                if let meter = photo.meteringMode {
                    LabeledContent("Metering", value: formatMeteringMode(meter))
                }
                if let flash = photo.flash {
                    LabeledContent("Flash", value: formatFlash(flash))
                }
                if let wb = photo.whiteBalance {
                    LabeledContent("White Balance", value: wb == 0 ? "Auto" : "Manual")
                }
                if let brightness = photo.brightnessValue {
                    LabeledContent("Brightness", value: String(format: "%.2f", brightness))
                }
                if let scene = photo.sceneCaptureType {
                    LabeledContent("Scene Type", value: formatSceneCaptureType(scene))
                }
                if let light = photo.lightSource {
                    LabeledContent("Light Source", value: formatLightSource(light))
                }
            }
        }
    }

    @ViewBuilder
    private var lensSpecSection: some View {
        if let spec = photo.lensSpecification, spec.count >= 4 {
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
        let hasContent = photo.exifVersion != nil || photo.imageStabilization != nil
            || photo.contrast != nil || photo.saturation != nil || photo.sharpness != nil
            || photo.digitalZoomRatio != nil
        if hasContent {
            Section("Technical") {
                if let ver = photo.exifVersion {
                    LabeledContent("EXIF Version", value: ver)
                }
                if let stab = photo.imageStabilization {
                    LabeledContent("Image Stabilization", value: stab == 1 ? "On" : "Off")
                }
                if let c = photo.contrast {
                    LabeledContent("Contrast", value: formatLevel(c))
                }
                if let s = photo.saturation {
                    LabeledContent("Saturation", value: formatLevel(s))
                }
                if let s = photo.sharpness {
                    LabeledContent("Sharpness", value: formatLevel(s))
                }
                if let zoom = photo.digitalZoomRatio, zoom > 0 {
                    LabeledContent("Digital Zoom", value: String(format: "%.1fx", zoom))
                }
            }
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        if photo.latitude != nil || photo.longitude != nil {
            Section("Location") {
                if let lat = photo.latitude, let lon = photo.longitude {
                    LabeledContent("Coordinates", value: String(format: "%.4f, %.4f", lat, lon))
                }
            }
        }
    }

    // MARK: - Formatters

    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatExposureProgram(_ value: Int) -> String {
        switch value {
        case 0: return "Not Defined"
        case 1: return "Manual"
        case 2: return "Program AE"
        case 3: return "Aperture Priority"
        case 4: return "Shutter Priority"
        case 5: return "Creative"
        case 6: return "Action"
        case 7: return "Portrait"
        case 8: return "Landscape"
        default: return "Unknown (\(value))"
        }
    }

    private func formatMeteringMode(_ value: Int) -> String {
        switch value {
        case 0: return "Unknown"
        case 1: return "Average"
        case 2: return "Center-weighted"
        case 3: return "Spot"
        case 4: return "Multi-spot"
        case 5: return "Multi-segment"
        case 6: return "Partial"
        default: return "Other (\(value))"
        }
    }

    private func formatFlash(_ value: Int) -> String {
        let fired = (value & 0x01) != 0
        let mode = (value >> 3) & 0x03
        var parts: [String] = []
        parts.append(fired ? "Fired" : "No Flash")
        switch mode {
        case 1: parts.append("Compulsory")
        case 2: parts.append("Suppressed")
        case 3: parts.append("Auto")
        default: break
        }
        return parts.joined(separator: ", ")
    }

    private func formatSceneCaptureType(_ value: Int) -> String {
        switch value {
        case 0: return "Standard"
        case 1: return "Landscape"
        case 2: return "Portrait"
        case 3: return "Night"
        default: return "Unknown (\(value))"
        }
    }

    private func formatLightSource(_ value: Int) -> String {
        switch value {
        case 0: return "Unknown"
        case 1: return "Daylight"
        case 2: return "Fluorescent"
        case 3: return "Tungsten"
        case 4: return "Flash"
        case 9: return "Fine Weather"
        case 10: return "Cloudy"
        case 11: return "Shade"
        case 17: return "Standard Light A"
        case 18: return "Standard Light B"
        case 19: return "Standard Light C"
        case 20: return "D55"
        case 21: return "D65"
        case 22: return "D75"
        case 23: return "D50"
        case 255: return "Other"
        default: return "Unknown (\(value))"
        }
    }

    private func formatLevel(_ value: Int) -> String {
        switch value {
        case 0: return "Normal"
        case 1: return "Low"
        case 2: return "High"
        default: return "Unknown (\(value))"
        }
    }
}

// MARK: - Per-Video Gyro Config

private struct GyroConfigSection: View {
    @Bindable var photo: Photo

    // Global settings (read-only, for "Copy from Global" and display)
    @AppStorage("gyroSmooth") private var globalSmooth: Double = 0.5
    @AppStorage("gyroOffsetMs") private var globalOffsetMs: Double = 0
    @AppStorage("gyroIntegrationMethod") private var globalIntegrationMethod: Int = 2
    @AppStorage("gyroImuOrientation") private var globalImuOrientation: String = "YXz"
    @AppStorage("gyroFov") private var globalFov: Double = 1.0
    @AppStorage("gyroLensCorrectionAmount") private var globalLensCorrectionAmount: Double = 1.0
    @AppStorage("gyroZoomingMethod") private var globalZoomingMethod: Int = 1
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

    private var hasCustom: Bool { photo.gyroConfigJson != nil }

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
                            photo.gyroConfigJson = nil
                            dirty = false
                        }
                    }
                ))

                if !hasCustom {
                    Text("使用全域設定")
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
                            photo.gyroConfigJson = nil
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
                        Text("Complementary").tag(0)
                        Text("Complementary2").tag(1)
                        Text("VQF").tag(2)
                    }

                    HStack {
                        Text("IMU Orientation")
                        Spacer()
                        TextField("", text: binding(\.imuOrientation))
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
                        Text("Envelope Follower").tag(1)
                    }

                    if config.zoomingMethod == 1 {
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
            integrationMethod: globalIntegrationMethod,
            imuOrientation: globalImuOrientation,
            fov: globalFov,
            lensCorrectionAmount: globalLensCorrectionAmount,
            zoomingMethod: globalZoomingMethod,
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
            smoothnessRoll: globalSmoothnessRoll
        )
    }

    private func load() {
        guard let json = photo.gyroConfigJson,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GyroConfig.self, from: data)
        else { return }
        config = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        photo.gyroConfigJson = String(data: data, encoding: .utf8)
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
