import Darwin
import Foundation

// MARK: - mpv render param type constants (mpv_render_param_type)

let MPV_RC_API_TYPE: Int32 = 1
let MPV_RC_OGL_INIT: Int32 = 2
let MPV_RC_OGL_FBO:  Int32 = 3
let MPV_RC_FLIP_Y:   Int32 = 4
let MPV_RC_DEPTH:    Int32 = 5
let MPV_RC_NEXT_FRAME_INFO: Int32 = 11
let MPV_RC_BLOCK_FOR_TARGET_TIME: Int32 = 12
let MPV_RC_ADVANCED: Int32 = 10

/// mpv_render_context_update() return flags
let MPV_RENDER_UPDATE_FRAME: UInt64 = 1 << 0

// mpv_render_frame_info_flag
let MPV_FRAME_INFO_PRESENT:     UInt64 = 1 << 0
let MPV_FRAME_INFO_REDRAW:      UInt64 = 1 << 1
let MPV_FRAME_INFO_REPEAT:      UInt64 = 1 << 2
let MPV_FRAME_INFO_BLOCK_VSYNC: UInt64 = 1 << 3

// MARK: - mpv event ID constants

let MPV_EV_SHUTDOWN: Int32 = 1

// MARK: - mpv C struct mirrors

/// mpv_render_param: { int type; [4B pad]; void *data; } = 16 bytes on 64-bit
struct MPVRenderParam {
    var type: Int32
    private var _pad: Int32 = 0
    var data: UnsafeMutableRawPointer?
    init(_ t: Int32, _ d: UnsafeMutableRawPointer?) { type = t; _pad = 0; data = d }
    init() { type = 0; _pad = 0; data = nil }
}

/// mpv_opengl_fbo
struct MPVOpenGLFBO {
    var fbo: Int32; var w: Int32; var h: Int32; var internal_format: Int32
}

/// mpv_opengl_init_params
struct MPVOpenGLInitParams {
    var get_proc_address: (@convention(c) (UnsafeMutableRawPointer?,
                                           UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    var get_proc_address_ctx: UnsafeMutableRawPointer?
}

/// mpv_event (minimal layout — only event_id used)
struct MPVEvent {
    var event_id: Int32; var error: Int32; var reply_userdata: UInt64
    var data: UnsafeMutableRawPointer?
}

/// mpv_render_frame_info: { uint64_t flags; int64_t target_time; } = 16 bytes
struct MPVRenderFrameInfo {
    var flags: UInt64 = 0
    var targetTime: Int64 = 0   // microseconds, same time base as mpv_get_time_us()
}

// MARK: - GL proc address helper

nonisolated(unsafe) let mpvGLLibHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)

func mpvGLProcAddr(_ ctx: UnsafeMutableRawPointer?,
                   _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return dlsym(mpvGLLibHandle, name)
}

// MARK: - LibMPV

/// Loads libmpv at runtime via dlopen.
///
/// Search order:
///   1. App bundle Resources/lib/libmpv.dylib  — copied at build time from IINA or source
///      (the only path that works inside the App Sandbox)
///   2. IINA.app Frameworks/                   — development fallback (no sandbox)
///   3. Homebrew /opt/homebrew / /usr/local     — development fallback (no sandbox)
///
/// The "Bundle libmpv" Xcode build phase automatically copies libmpv from IINA.app,
/// so sandbox mode works without any manual steps when IINA is installed.
class LibMPV: @unchecked Sendable {
    static let shared = LibMPV()

    private(set) var ok = false
    private(set) var loadedPath: String?
    private var handle: UnsafeMutableRawPointer?

    typealias FCreate   = @convention(c) () -> OpaquePointer?
    typealias FInit     = @convention(c) (OpaquePointer) -> Int32
    typealias FSetStr   = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    typealias FGetStr   = @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias FCmd      = @convention(c) (OpaquePointer, UnsafePointer<UnsafePointer<CChar>?>) -> Int32
    typealias FWait     = @convention(c) (OpaquePointer, Double) -> UnsafeMutableRawPointer
    typealias FDestroy  = @convention(c) (OpaquePointer) -> Void
    typealias FFree     = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FRCCreate = @convention(c) (UnsafeMutableRawPointer, OpaquePointer, UnsafeMutableRawPointer) -> Int32
    typealias FRCCb     = @convention(c) (OpaquePointer, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
                                          UnsafeMutableRawPointer?) -> Void
    typealias FRCRender = @convention(c) (OpaquePointer, UnsafeMutableRawPointer) -> Int32
    typealias FRCSwap   = @convention(c) (OpaquePointer) -> Void
    typealias FRCFree   = @convention(c) (OpaquePointer) -> Void
    /// mpv_render_context_update(ctx) → UInt64 flags  (MPV_RENDER_UPDATE_FRAME = 1)
    typealias FRCUpdate = @convention(c) (OpaquePointer) -> UInt64
    // mpv_render_context_get_info(ctx, mpv_render_param{type,data}) — struct passed by value
    // arm64 ABI: 16-byte struct → first 8 bytes (type+pad) in x1, next 8 bytes (data*) in x2
    typealias FRCGetInfo = @convention(c) (OpaquePointer, Int64, UnsafeMutableRawPointer?) -> Int32
    typealias FGetTimeUs = @convention(c) (OpaquePointer) -> Int64

    var create:     FCreate?
    var initialize: FInit?
    var setStr:     FSetStr?
    var setProp:    FSetStr?     // mpv_set_property_string (runtime, after init)
    var getStr:     FGetStr?
    var command:    FCmd?
    var waitEvent:  FWait?
    var destroy:    FDestroy?
    var free:       FFree?
    var rcCreate:   FRCCreate?
    var rcSetCb:    FRCCb?
    var rcRender:   FRCRender?
    var rcSwap:     FRCSwap?
    var rcFree:     FRCFree?
    var rcUpdate:   FRCUpdate?
    var rcGetInfo:  FRCGetInfo?
    var getTimeUs:  FGetTimeUs?

    private init() {
        // Build bundle path first (sandbox-compatible; copied by "Bundle libmpv" build phase)
        var searchPaths: [String] = []
        if let resPath = Bundle.main.resourcePath {
            searchPaths.append("\(resPath)/lib/libmpv.dylib")
        }
        // External fallbacks for non-sandbox development builds
        // Homebrew first: mpv 0.41+ supports rcGetInfo (frame timing for gyro sync)
        searchPaths += [
            "/opt/homebrew/lib/libmpv.dylib",
            "/usr/local/lib/libmpv.dylib",
            "/Applications/IINA.app/Contents/Frameworks/libmpv.dylib",
            "/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib",
        ]
        for path in searchPaths {
            handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
            if handle != nil { loadedPath = path; break }
        }
        guard let h = handle else { return }

        create     = dlsym(h, "mpv_create")                              .map { unsafeBitCast($0, to: FCreate.self)   }
        initialize = dlsym(h, "mpv_initialize")                          .map { unsafeBitCast($0, to: FInit.self)     }
        setStr     = dlsym(h, "mpv_set_option_string")                   .map { unsafeBitCast($0, to: FSetStr.self)   }
        setProp    = dlsym(h, "mpv_set_property_string")                 .map { unsafeBitCast($0, to: FSetStr.self)   }
        getStr     = dlsym(h, "mpv_get_property_string")                 .map { unsafeBitCast($0, to: FGetStr.self)   }
        command    = dlsym(h, "mpv_command")                             .map { unsafeBitCast($0, to: FCmd.self)      }
        waitEvent  = dlsym(h, "mpv_wait_event")                          .map { unsafeBitCast($0, to: FWait.self)     }
        destroy    = dlsym(h, "mpv_terminate_destroy")                   .map { unsafeBitCast($0, to: FDestroy.self)  }
        free       = dlsym(h, "mpv_free")                                .map { unsafeBitCast($0, to: FFree.self)     }
        rcCreate   = dlsym(h, "mpv_render_context_create")               .map { unsafeBitCast($0, to: FRCCreate.self) }
        rcSetCb    = dlsym(h, "mpv_render_context_set_update_callback")  .map { unsafeBitCast($0, to: FRCCb.self)    }
        rcRender   = dlsym(h, "mpv_render_context_render")               .map { unsafeBitCast($0, to: FRCRender.self) }
        rcSwap     = dlsym(h, "mpv_render_context_report_swap")          .map { unsafeBitCast($0, to: FRCSwap.self)  }
        rcFree     = dlsym(h, "mpv_render_context_free")                 .map { unsafeBitCast($0, to: FRCFree.self)  }
        rcUpdate   = dlsym(h, "mpv_render_context_update")             .map { unsafeBitCast($0, to: FRCUpdate.self) }
        rcGetInfo  = dlsym(h, "mpv_render_context_get_info")           .map { unsafeBitCast($0, to: FRCGetInfo.self) }
        getTimeUs  = dlsym(h, "mpv_get_time_us")                      .map { unsafeBitCast($0, to: FGetTimeUs.self) }

        ok = create != nil
    }

    @discardableResult
    func set(_ ctx: OpaquePointer, _ key: String, _ val: String) -> Int32 {
        guard let fn = setStr else { return -1 }
        return key.withCString { k in val.withCString { v in fn(ctx, k, v) } }
    }

    /// Set property at runtime (after mpv_initialize).
    @discardableResult
    func setProperty(_ ctx: OpaquePointer, _ key: String, _ val: String) -> Int32 {
        guard let fn = setProp else { return -1 }
        return key.withCString { k in val.withCString { v in fn(ctx, k, v) } }
    }
}
