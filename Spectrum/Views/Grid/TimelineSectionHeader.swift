import SwiftUI

struct TimelineSectionHeader: View {
    var localizedLabel: LocalizedStringKey? = nil
    var verbatimLabel: String? = nil
    let count: Int
    var unit: HeaderUnit = .photos

    enum HeaderUnit { case photos, folders }

    var body: some View {
        HStack {
            if let localizedLabel {
                Text(localizedLabel)
                    .font(.title2)
                    .fontWeight(.bold)
            } else if let verbatimLabel {
                Text(verbatim: verbatimLabel)
                    .font(.title2)
                    .fontWeight(.bold)
            }
            switch unit {
            case .photos:
                Text("\(count) photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .folders:
                Text("\(count) folders")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
