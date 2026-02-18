import SwiftUI
import SwiftData

@main
struct SpectrumApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Photo.self, ScannedFolder.self])
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            FileCommands()
            PhotoNavigationCommands()
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

            Divider()

            Button("Open") {
                navigation?.enter()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(navigation == nil)
        }
    }
}
