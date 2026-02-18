import SwiftUI

struct PhotoInfoPanel: View {
    @Bindable var photo: Photo
    var isHDR: Bool = false

    var body: some View {
        Form {
            fileSection
            if photo.isVideo {
                videoSection
            } else {
                cameraSection
                exposureSection
                lensSpecSection
                pictureProfileSection
                technicalSection
            }
            locationSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 250)
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
    private var pictureProfileSection: some View {
        if let pp = photo.pictureProfile {
            Section("Picture Profile") {
                LabeledContent("Profile", value: pp)
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
