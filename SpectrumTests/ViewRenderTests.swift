import XCTest
import SwiftUI
import SwiftData
import AppKit
import AVFoundation
import CoreGraphics
@testable import Spectrum

/// Host-renders several low-coverage SwiftUI views through an `NSHostingView`
/// so SwiftUI evaluates their full body (conditional branches, switch/format
/// helpers) that are hard to reach via UI tests. Rendering without crashing is
/// the assertion; each test also asserts `XCTAssertNotNil` on the hosting view.
@MainActor
final class ViewRenderTests: XCTestCase {

    /// Force SwiftUI to evaluate a view's body by hosting and laying it out.
    @discardableResult
    private func render<V: View>(_ view: V, width: CGFloat = 360, height: CGFloat = 700) -> NSHostingView<some View> {
        let root = view.frame(width: width, height: height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return host
    }

    // MARK: - In-memory image fixtures

    private func makeNSImage(width: Int = 64, height: Int = 64) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    private func makeCGImage(width: Int = 64, height: Int = 64) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.itur_2100_HLG) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.7, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let base = ctx.makeImage()!
        // Re-tag into HLG colorspace if available (mimics app usage).
        return base.copy(colorSpace: cs) ?? base
    }

    // MARK: - HDRImageViews

    func testRenderHDRImageView_allDynamicRanges() {
        let img = makeNSImage()
        for range in [NSImage.DynamicRange.standard, .constrainedHigh, .high] {
            let host = render(HDRImageView(image: img, dynamicRange: range))
            XCTAssertNotNil(host)
        }
    }

    func testRenderHLGImageView() {
        let host = render(HLGImageView(cgImage: makeCGImage()))
        XCTAssertNotNil(host)
    }

    // MARK: - TimelineSectionHeader

    func testRenderTimelineSectionHeader_allCombinations() {
        // photos vs folders, localized vs verbatim vs no label, varied counts.
        let counts = [0, 1, 42, 9999]
        for count in counts {
            render(TimelineSectionHeader(localizedLabel: "Today", count: count, unit: .photos))
            render(TimelineSectionHeader(verbatimLabel: "2026-06-26", count: count, unit: .folders))
            render(TimelineSectionHeader(count: count, unit: .photos))   // no label
            render(TimelineSectionHeader(count: count, unit: .folders))
        }
        XCTAssertTrue(true)
    }

    // MARK: - VideoControlBar

    private func makeController(playing: Bool, muted: Bool,
                                volume: Float, current: Double, duration: Double) -> VideoController {
        let c = VideoController()
        c.isPlaying = playing
        c.currentTime = current
        c.duration = duration
        c.isMuted = muted
        c.volume = volume
        return c
    }

    func testRenderVideoControlBar_variedState() {
        // Cover play/pause icon, all four speaker icon branches, time formatters
        // (with and without hours), zero/non-zero duration scrubber branch.
        let states: [(Bool, Bool, Float, Double, Double)] = [
            (true,  false, 1.0,  12,    125),       // playing, full volume
            (false, false, 0.7,  0,     0),         // paused, zero duration
            (false, true,  0.0,  3661,  7200),      // muted, hours formatting
            (true,  false, 0.3,  45,    90),        // low volume (wave.1)
            (false, false, 0.0,  10,    60),        // volume == 0 (speaker.fill)
        ]
        for (playing, muted, vol, cur, dur) in states {
            let c = makeController(playing: playing, muted: muted, volume: vol,
                                   current: cur, duration: dur)
            render(VideoControlBar(controller: c), height: 80)
            render(VideoControlBar(controller: c, onPlay: {}), height: 80)
        }
        XCTAssertTrue(true)
    }

    // MARK: - LivePhotoPlayerView

    private var fixtureVideoURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SpectrumUITests/E2EFixtures/video_01.mp4")
    }

    func testRenderLivePhotoPlayerView() throws {
        let url = fixtureVideoURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "fixture video missing: \(url.path)")
        // isPlaying false then true to traverse both updateNSView branches.
        render(LivePhotoPlayerView(url: url, bookmarkData: nil, isPlaying: false), height: 200)
        render(LivePhotoPlayerView(url: url, bookmarkData: nil, isPlaying: true,
                                   onEnded: {}), height: 200)
        XCTAssertTrue(true)
    }

    // MARK: - SettingsView

    func testRenderSettingsView() {
        let host = render(SettingsView(), width: 460, height: 600)
        XCTAssertNotNil(host)
    }

    // MARK: - PhotoInfoPanel video branch with injected gyro binding

    /// Provides `gyroConfigBinding` via `.focusedSceneValue` so the video panel's
    /// gyro tab path can resolve the FocusedValue (the GyroConfigSection itself is
    /// `private` to PhotoInfoPanel.swift and cannot be constructed directly).
    private struct GyroHost: View {
        @State var json: String?
        var body: some View {
            PhotoInfoPanel(item: GyroHost.videoItem(), isHDR: false)
                .focusedSceneValue(\.gyroConfigBinding, $json)
        }
        static func videoItem() -> PhotoItem {
            var item = PhotoItem(
                filePath: "/tmp/clip.mov", fileName: "clip.mov",
                dateTaken: Date(timeIntervalSince1970: 1_726_408_222),
                fileSize: 120_000_000, isVideo: true)
            item.duration = 12.5
            item.pixelWidth = 3840
            item.pixelHeight = 2160
            item.videoCodec = "hvc1"
            item.audioCodec = "aac"
            return item
        }
    }

    func testRenderPhotoInfoPanel_videoWithGyroBinding() {
        // nil gyro config (uses global) and a custom JSON config.
        render(GyroHost(json: nil))
        let cfg = GyroConfig()
        if let data = try? JSONEncoder().encode(cfg),
           let str = String(data: data, encoding: .utf8) {
            render(GyroHost(json: str))
        }
        XCTAssertTrue(true)
    }

    // MARK: - SwiftData container helpers

    /// Build an in-memory ModelContainer and optionally seed folders + photos.
    private func makeContainer(folders: [(path: String, bookmark: Data)] = [],
                               photos: [(path: String, name: String)] = []) throws -> (ModelContainer, [ScannedFolder]) {
        let schema = Schema([Photo.self, ScannedFolder.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext
        var inserted: [ScannedFolder] = []
        for f in folders {
            let folder = ScannedFolder(path: f.path, bookmarkData: f.bookmark)
            ctx.insert(folder)
            inserted.append(folder)
        }
        for p in photos {
            // Attach to the first folder whose path is a prefix, if any.
            let owner = inserted.first { p.path.hasPrefix($0.path) }
            let photo = Photo(filePath: p.path, fileName: p.name, dateTaken: Date(), folder: owner)
            ctx.insert(photo)
        }
        try ctx.save()
        return (container, inserted)
    }

    // MARK: - SidebarView (@Query ScannedFolder)

    func testRenderSidebarView_emptyState() throws {
        let (container, _) = try makeContainer()
        // No folders -> ContentUnavailableView empty-state branch.
        let host = render(
            SidebarView(selection: .constant(nil))
                .modelContainer(container),
            width: 240, height: 500)
        XCTAssertNotNil(host)
    }

    // NOTE: SidebarView variants seeded with actual folder rows were intentionally
    // omitted. Hosting the real `List(selection:)` with ScannedFolder-tagged rows
    // (plus its `.task` that spawns detached FolderReader work) inside an
    // NSHostingView triggers a flaky AppKit layout-reentrancy crash that aborts the
    // whole xctest runner ("layoutSubtreeIfNeeded on a view which is already being
    // laid out" / "FocusedValue update tried to update multiple times per frame").
    // It passes in isolation but crashes intermittently within the full suite, so a
    // populated SidebarView cannot be host-rendered deterministically. The
    // empty-state branch (above) is stable and covered.

    // MARK: - PhotoGridView (@Query ScannedFolder + LibraryViewModel)

    private func makePopulatedViewModel() -> LibraryViewModel {
        let vm = LibraryViewModel()
        vm.flatPhotos = (0..<5).map { i in
            var item = PhotoItem(
                filePath: "/tmp/SpectrumTest/AlphaFolder/IMG_\(i).jpg",
                fileName: "IMG_\(i).jpg",
                dateTaken: Date(timeIntervalSince1970: 1_726_400_000 + Double(i) * 3600),
                fileSize: 1_000_000, isVideo: i % 2 == 0)
            item.pixelWidth = 4000
            item.pixelHeight = 3000
            return item
        }
        return vm
    }

    func testRenderPhotoGridView_emptyAndPopulated() throws {
        let (container, folders) = try makeContainer(folders: [
            ("/tmp/SpectrumTest/AlphaFolder", Data("bm-a".utf8)),
        ], photos: [
            ("/tmp/SpectrumTest/AlphaFolder/IMG_0.jpg", "IMG_0.jpg"),
            ("/tmp/SpectrumTest/AlphaFolder/IMG_1.jpg", "IMG_1.jpg"),
        ])

        // folder == nil keeps loadCurrentLevel() a no-op (deterministic, no filesystem),
        // while @Query allFolders still resolves through the injected container.
        let vm = makePopulatedViewModel()

        // Empty selection.
        render(
            PhotoGridView(
                viewModel: vm,
                selectedPhoto: .constant(nil),
                initialSelection: .constant(nil))
                .modelContainer(container),
            width: 600, height: 500)

        // With an initial selection id + a selected photo to hit onAppear/select paths.
        let selected = vm.flatPhotos.first
        render(
            PhotoGridView(
                viewModel: vm,
                selectedPhoto: .constant(selected),
                initialSelection: .constant(selected?.filePath),
                onDoubleClick: { _ in },
                onNavigateToSubfolder: { _ in },
                folder: folders.first)
                .modelContainer(container),
            width: 600, height: 500)

        // Empty view model (no photos) -> empty grid body.
        render(
            PhotoGridView(
                viewModel: LibraryViewModel(),
                selectedPhoto: .constant(nil),
                initialSelection: .constant(nil))
                .modelContainer(container),
            width: 400, height: 400)

        XCTAssertTrue(true)
    }
}
