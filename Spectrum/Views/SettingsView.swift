import SwiftUI

struct SettingsView: View {
    @AppStorage("developerMode") private var developerMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Developer")
                .font(.headline)

            Toggle("Developer Mode", isOn: $developerMode)

            Text("Show color space conversion controls in the toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 400)
    }
}
