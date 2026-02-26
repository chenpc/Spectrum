import Darwin
import Foundation

// MARK: - mpv render param type constants (mpv_render_param_type)

let MPV_RC_API_TYPE: Int32 = 1
let MPV_RC_OGL_INIT: Int32 = 2
let MPV_RC_OGL_FBO:  Int32 = 3
let MPV_RC_FLIP_Y:   Int32 = 4
let MPV_RC_DEPTH:    Int32 = 5
let MPV_RC_ADVANCED: Int32 = 10

// MARK: - mpv event ID constants

let MPV_EV_SHUTDOWN: Int32 = 1

// MARK: - mpv C struct mirrors

struct MPVRenderParam {
    var type: Int32
    private var _pad: Int32 = 0
    var data: UnsafeMutableRawPointer?
    init(_ t: Int32, _ d: UnsafeMutableRawPointer?) { type = t; _pad = 0; data = d }
    init() { type = 0; _pad = 0; data = nil }
}

struct MPVOpenGLFBO {
    var fbo: Int32; var w: Int32; var h: Int32; var internal_format: Int32
}

struct MPVOpenGLInitParams {
    var get_proc_address: (@convention(c) (UnsafeMutableRawPointer?,
                                           UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    var get_proc_address_ctx: UnsafeMutableRawPointer?
}

struct MPVEvent {
    var event_id: Int32; var error: Int32; var reply_userdata: UInt64
    var data: UnsafeMutableRawPointer?
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

class LibMPV {
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

    var create:     FCreate?
    var initialize: FInit?
    var setStr:     FSetStr?
    var setProp:    FSetStr?
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

    private init() {
        // Search order: env TESTIMG_LIB_DIR → ../MyPhoto/Spectrum/Resources/lib → IINA → Homebrew
        var searchPaths: [String] = []
        if let envLib = ProcessInfo.processInfo.environment["TESTIMG_LIB_DIR"] {
            searchPaths.append("\(envLib)/libmpv.dylib")
        }
        // Relative to executable
        let execDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        searchPaths.append("\(execDir)/../MyPhoto/Spectrum/Resources/lib/libmpv.dylib")
        searchPaths += [
            "/Applications/IINA.app/Contents/Frameworks/libmpv.dylib",
            "/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib",
            "/opt/homebrew/lib/libmpv.dylib",
            "/usr/local/lib/libmpv.dylib",
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

        ok = create != nil
    }

    @discardableResult
    func set(_ ctx: OpaquePointer, _ key: String, _ val: String) -> Int32 {
        guard let fn = setStr else { return -1 }
        return key.withCString { k in val.withCString { v in fn(ctx, k, v) } }
    }

    @discardableResult
    func setProperty(_ ctx: OpaquePointer, _ key: String, _ val: String) -> Int32 {
        guard let fn = setProp else { return -1 }
        return key.withCString { k in val.withCString { v in fn(ctx, k, v) } }
    }
}
