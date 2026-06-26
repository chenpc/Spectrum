import XCTest
import SwiftUI
@testable import Spectrum

/// Renders `PhotoInfoPanel` (and related metadata views) through an `NSHostingView`
/// so SwiftUI evaluates the full body — including the camera / exposure / lens-spec /
/// technical / location / video sections that are gated on EXIF/metadata being present.
/// This exercises the conditional row builders and the format* helpers that are
/// otherwise hard to reach via the running UI.
@MainActor
final class PhotoInfoPanelRenderTests: XCTestCase {

    /// Force SwiftUI to evaluate a view's body by hosting and laying it out.
    /// A very tall frame keeps every grouped-Form section "on screen" so the lower
    /// sections (technical / location) are not skipped by lazy List virtualization.
    private func render<V: View>(_ view: V, height: CGFloat = 8000) {
        let host = NSHostingView(rootView: view.frame(width: 320, height: height))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Pump a few runloop turns so SwiftUI commits the hosting update + lazy rows.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    private func richPhotoItem() -> PhotoItem {
        var item = PhotoItem(
            filePath: "/tmp/richexif.heic",
            fileName: "richexif.heic",
            dateTaken: Date(timeIntervalSince1970: 1_726_408_222),
            fileSize: 8_400_000,
            isVideo: false
        )
        item.pixelWidth = 6000
        item.pixelHeight = 4000
        item.orientation = 6
        item.cameraMake = "SONY"
        item.cameraModel = "ILCE-7M4"
        item.lensModel = "FE 85mm F1.8"
        item.software = "Spectrum 1.0"
        item.focalLength = 85
        item.aperture = 1.8
        item.shutterSpeed = "1/250"
        item.iso = 400
        item.latitude = 35.6586
        item.longitude = 139.7454
        item.headroom = 3.2
        item.profileName = "Display P3"
        item.colorDepth = 10
        item.dpiWidth = 72
        item.dpiHeight = 72
        item.offsetTimeOriginal = "+09:00"
        item.exposureBias = -0.33
        item.exposureProgram = 3
        item.meteringMode = 5
        item.flash = 16
        item.whiteBalance = 0
        item.brightnessValue = 4.2
        item.focalLenIn35mm = 85
        item.sceneCaptureType = 1
        item.lightSource = 1
        item.lensSpecification = [24, 70, 2.8, 2.8]
        item.exifVersion = "0232"
        item.imageStabilization = 1
        item.contrast = 0
        item.saturation = 1
        item.sharpness = 2
        item.digitalZoomRatio = 1.0
        return item
    }

    private func videoItem() -> PhotoItem {
        var item = PhotoItem(
            filePath: "/tmp/clip.mov",
            fileName: "clip.mov",
            dateTaken: Date(timeIntervalSince1970: 1_726_408_222),
            fileSize: 120_000_000,
            isVideo: true
        )
        item.duration = 12.5
        item.pixelWidth = 3840
        item.pixelHeight = 2160
        item.videoCodec = "hvc1"
        item.audioCodec = "aac"
        item.latitude = 35.0
        item.longitude = 139.0
        return item
    }

    // MARK: - Tests

    func testRenderPhotoInfoPanel_richMetadata() {
        render(PhotoInfoPanel(item: richPhotoItem(), isHDR: false))
    }

    func testRenderPhotoInfoPanel_richMetadataHDR() {
        render(PhotoInfoPanel(item: richPhotoItem(), isHDR: true))
    }

    func testRenderPhotoInfoPanel_video() {
        render(PhotoInfoPanel(item: videoItem(), isHDR: false))
    }

    func testRenderPhotoInfoPanel_minimalPhoto() {
        let item = PhotoItem(
            filePath: "/tmp/bare.jpg", fileName: "bare.jpg",
            dateTaken: Date(), fileSize: 1000, isVideo: false)
        render(PhotoInfoPanel(item: item, isHDR: false))
    }

    func testRenderPhotoInfoPanel_partialExposureOnly() {
        var item = PhotoItem(
            filePath: "/tmp/partial.jpg", fileName: "partial.jpg",
            dateTaken: Date(), fileSize: 2000, isVideo: false)
        item.aperture = 2.8
        item.iso = 100
        item.shutterSpeed = "1/60"
        item.focalLength = 35
        render(PhotoInfoPanel(item: item, isHDR: false))
    }

    func testRenderPhotoInfoPanel_everyFieldVariations() {
        // Vary enum-coded fields across their full ranges to traverse every format*
        // helper switch case (exposureProgram 0-8, meteringMode 0-6, sceneCaptureType
        // 0-3, lightSource 0-24, flash bitfield, white balance, contrast/sat/sharp 0-2).
        var item = richPhotoItem()
        for v in 0...25 {
            item.exposureProgram = v
            item.meteringMode = v
            item.flash = v
            item.whiteBalance = v % 2
            item.sceneCaptureType = v % 5
            item.lightSource = v
            item.contrast = v % 4
            item.saturation = v % 4
            item.sharpness = v % 4
            item.orientation = (v % 8) + 1
            render(PhotoInfoPanel(item: item, isHDR: v % 2 == 0))
        }
    }

    func testRenderPhotoInfoPanel_flashBitfieldVariations() {
        // Flash is a bitfield; exercise common encoded values.
        var item = richPhotoItem()
        for flash in [0x00, 0x01, 0x05, 0x07, 0x08, 0x09, 0x0D, 0x0F, 0x10, 0x18, 0x19, 0x1D, 0x1F, 0x20, 0x41, 0x45, 0x47, 0x49, 0x4D, 0x4F, 0x50, 0x58, 0x59] {
            item.flash = flash
            render(PhotoInfoPanel(item: item, isHDR: false))
        }
    }

    func testRenderPhotoInfoPanel_locationAndTechnicalOnly() {
        // Item with only GPS + technical fields, no camera/exposure, to hit those
        // sections' hasContent gates independently.
        var item = PhotoItem(
            filePath: "/tmp/geo.jpg", fileName: "geo.jpg",
            dateTaken: Date(), fileSize: 5000, isVideo: false)
        item.latitude = -33.8688
        item.longitude = 151.2093
        item.imageStabilization = 1
        item.contrast = 1
        item.saturation = 2
        item.sharpness = 1
        item.digitalZoomRatio = 2.0
        item.exifVersion = "0231"
        item.lensSpecification = [16, 35, 4.0, 4.0]
        render(PhotoInfoPanel(item: item, isHDR: false))

        // Negative-then-positive GPS hemispheres.
        item.latitude = 48.8566
        item.longitude = -2.3522
        render(PhotoInfoPanel(item: item, isHDR: true))
    }
}
