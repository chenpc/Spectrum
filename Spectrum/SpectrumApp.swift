import SwiftUI
import SwiftData
import AppKit

// MARK: - TextInputFocusMonitor

/// Tracks whether the current first responder is a text input (the field editor
/// NSTextView backing any TextField / search field / rename alert).
///
/// Menu commands bound to bare keys (arrows, Return, Delete) match in the key-
/// equivalent phase BEFORE the event reaches the focused text field or the IME,
/// so an enabled command steals the key — e.g. arrow keys navigating the photo
/// grid while the user is picking IME candidates in the rename box. Commands
/// consult this monitor and disable themselves while text input is active,
/// letting the event flow to the field editor / IME normally.
@MainActor
@Observable
final class TextInputFocusMonitor {
    static let shared = TextInputFocusMonitor()

    private(set) var isTextInputActive = false

    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var responderObservation: NSKeyValueObservation?
    @ObservationIgnored private var keyGuardMonitor: Any?

    init() {
        // Deterministic guard: local monitors see key events BEFORE menu
        // key-equivalent matching, so this is the only reliable place to stop
        // bare-key menu shortcuts from stealing keys out of a text field.
        // (Gating focusedSceneValue alone fails while an alert panel is key —
        // the scene's focused values don't reach Commands from there.)
        keyGuardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.routeToTextInputIfNeeded(event)
        }

        let nc = NotificationCenter.default
        windowObservers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            Task { @MainActor [weak self] in self?.attach(to: window) }
        })
        windowObservers.append(nc.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, NSApp.keyWindow == nil else { return }
                self.attach(to: nil)
            }
        })
        attach(to: NSApp.keyWindow)
    }

    /// Follow first-responder changes of the given (key) window.
    /// Internal for unit testing.
    func attach(to window: NSWindow?) {
        guard let window else {
            responderObservation = nil
            isTextInputActive = false
            return
        }
        responderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] win, _ in
            // Responder changes always happen on the main thread
            MainActor.assumeIsolated {
                let responder = win.firstResponder
                let isTextView = Self.isTextInput(responder)
                Log.debug(Log.general, "[textfocus] responder=\(responder.map { String(describing: type(of: $0)) } ?? "nil") isTextInput=\(isTextView)")
                self?.isTextInputActive = isTextView
            }
        }
    }

    /// A text input session is active when the responder is an NSTextView —
    /// AppKit focuses the shared field editor (an NSTextView) for every editable
    /// text field, including SwiftUI TextField and the toolbar search field.
    nonisolated static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    /// Bare navigation/editing keys (arrows, Page Up/Down, Delete) are bound as
    /// modifier-less menu key equivalents, which match BEFORE the focused text
    /// field or the IME ever see the event. While a text input session is
    /// active, deliver these keys straight to the field editor and consume the
    /// event, so IME candidate navigation and caret movement work normally.
    /// Returns nil when the event was consumed; the event otherwise.
    static func routeToTextInputIfNeeded(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window,
              let textView = window.firstResponder as? NSTextView else { return event }

        let mods = event.modifierFlags.intersection([.command, .control, .option])

        // Cmd+A/C/X/V are remapped to file operations by FolderEditCommands;
        // while editing text they must act on the TEXT. Dispatch directly.
        if mods == .command {
            switch event.charactersIgnoringModifiers {
            case "a": textView.selectAll(nil);  return nil
            case "c": textView.copy(nil);       return nil
            case "x": textView.cut(nil);        return nil
            case "v": textView.paste(nil);      return nil
            default:  return event
            }
        }

        // Only bare keys are at risk below — menu equivalents are modifier-less.
        // (.shift allowed: shift+arrow is text selection, also owned by the field.)
        guard mods.isEmpty else { return event }
        switch event.keyCode {
        case 123, 124, 125, 126,   // ← → ↓ ↑
             116, 121,             // Page Up / Page Down
             51, 117:              // Delete (backspace) / Forward Delete
            textView.keyDown(with: event)   // → interpretKeyEvents → IME / caret
            return nil
        case 36, 76:               // Return / keypad Enter
            // During IME composition Return commits the candidate — must reach
            // the text view. Otherwise let the window's default button
            // (e.g. the alert's "Rename") handle it as usual.
            guard textView.hasMarkedText() else { return event }
            textView.keyDown(with: event)
            return nil
        default:
            return event
        }
    }
}

@main
struct SpectrumApp: App {
    let container: ModelContainer

    init() {
        // 必須在任何 SpectrumLibrary.url 存取之前先處理 CLI 參數
        let launchArgs = AppLaunchArgs.shared
        if let userDir = launchArgs.userDir {
            // --userdir：由 mktemp -d 建立的乾淨目錄，直接使用不清除
            SpectrumLibrary.overrideURL = userDir
            // UserDefaults 隔離：清除 app 的 persistent domain，
            // 避免視窗位置、設定值等跨測試污染
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
        }

        SpectrumLibrary.migrateFromLegacyLocationIfNeeded()
        SpectrumLibrary.acquireOrTerminate()
        do {
            let config = ModelConfiguration(url: SpectrumLibrary.databaseURL)
            container = try ModelContainer(for: Photo.self, ScannedFolder.self, configurations: config)
        } catch {
            fatalError("Failed to open Spectrum Library database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            FileCommands()
            PhotoNavigationCommands()
            FolderEditCommands()
            DeleteCommands()
            MpvPlaybackCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

struct FileCommands: Commands {
    @FocusedValue(\.addFolderAction) var addFolder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder...") {
                addFolder?()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(addFolder == nil)
        }
    }
}

struct FolderEditCommands: Commands {
    @FocusedValue(\.folderEditAction) var folderEdit
    @FocusedValue(\.selectAllAction) var selectAll

    var body: some Commands {
        // Replace the system Cut/Copy/Paste entries in the Edit menu.
        // When our actions are nil (disabled), macOS lets the first-responder
        // (e.g. a focused text field) handle the same shortcuts normally.
        // The publishing views set these to nil while text input is active.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { folderEdit?.cut?() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(folderEdit?.cut == nil)

            Button("Copy") { folderEdit?.copy?() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(folderEdit?.copy == nil)

            Button("Paste") { folderEdit?.paste?() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(folderEdit?.paste == nil)

            Divider()

            Button("Select All") { selectAll?() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(selectAll == nil)
        }
    }
}

struct PhotoNavigationCommands: Commands {
    // Becomes nil while text input is active — the publishing views gate their
    // focusedSceneValue on TextInputFocusMonitor (Commands cannot observe
    // @Observable directly; @FocusedValue changes DO invalidate Commands).
    @FocusedValue(\.photoNavigation) var navigation

    var body: some Commands {
        let blocked = navigation == nil
        CommandMenu("Navigate") {
            Button("Left") {
                navigation?.navigateLeft()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(blocked)

            Button("Right") {
                navigation?.navigateRight()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(blocked)

            Button("Up") {
                navigation?.navigateUp()
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(blocked)

            Button("Down") {
                navigation?.navigateDown()
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(blocked)

            Button("Page Up") {
                navigation?.pageUp()
            }
            .keyboardShortcut(.pageUp, modifiers: [])
            .disabled(blocked)

            Button("Page Down") {
                navigation?.pageDown()
            }
            .keyboardShortcut(.pageDown, modifiers: [])
            .disabled(blocked)

            Divider()

            Button("Open") {
                navigation?.enter()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(blocked)
        }
    }
}

struct DeleteCommands: Commands {
    @FocusedValue(\.deletePhotoAction) var deletePhoto

    var body: some Commands {
        let blocked = deletePhoto == nil
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Move to Trash") {
                deletePhoto?()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(blocked)
            Button("Move to Trash") {
                deletePhoto?()
            }
            .keyboardShortcut(KeyEquivalent.deleteForward, modifiers: [])
            .disabled(blocked)
        }
    }
}

struct MpvPlaybackCommands: Commands {
    @FocusedValue(\.videoPlayPause) var playPause

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") {
                playPause?()
            }
            .disabled(playPause == nil)
        }
    }
}
