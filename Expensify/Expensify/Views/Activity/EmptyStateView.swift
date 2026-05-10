import SwiftUI

/// Shown in the Activity tab when the review queue is empty.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("All caught up")
                .font(.title2.weight(.semibold))
            Text("No transactions need review.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

#Preview {
    EmptyStateView()
}
