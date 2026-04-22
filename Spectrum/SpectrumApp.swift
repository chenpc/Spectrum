import SwiftUI
import SwiftData

@main
struct SpectrumApp: App {
    let container: ModelContainer

    init() {
        // 必須在任何 SpectrumLibrary.url 存取之前先處理 CLI 參數
        let launchArgs = AppLaunchArgs.shared
        if let libURL = launchArgs.spectrumLibrary {
            // 清空舊的測試 library，確保每次從乾淨狀態開始
            try? FileManager.default.removeItem(at: libURL)
            SpectrumLibrary.overrideURL = libURL
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
    @FocusedValue(\.photoNavigation) var navigation

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Left") {
                navigation?.navigateLeft()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(navigation == nil)

            Button("Right") {
                navigation?.navigateRight()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(navigation == nil)

            Button("Up") {
                navigation?.navigateUp()
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(navigation == nil)

            Button("Down") {
                navigation?.navigateDown()
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(navigation == nil)

            Button("Page Up") {
                navigation?.pageUp()
            }
            .keyboardShortcut(.pageUp, modifiers: [])
            .disabled(navigation == nil)

            Button("Page Down") {
                navigation?.pageDown()
            }
            .keyboardShortcut(.pageDown, modifiers: [])
            .disabled(navigation == nil)

            Divider()

            Button("Open") {
                navigation?.enter()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(navigation == nil)
        }
    }
}

struct DeleteCommands: Commands {
    @FocusedValue(\.deletePhotoAction) var deletePhoto

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Move to Trash") {
                deletePhoto?()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(deletePhoto == nil)
            Button("Move to Trash") {
                deletePhoto?()
            }
            .keyboardShortcut(KeyEquivalent.deleteForward, modifiers: [])
            .disabled(deletePhoto == nil)
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
