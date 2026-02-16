import SwiftUI

struct TimelineSectionHeader: View {
    let label: String
    let count: Int
    var unit: String = "photos"

    var body: some View {
        HStack {
            Text(label)
                .font(.title2)
                .fontWeight(.bold)
            Text("\(count) \(unit)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
