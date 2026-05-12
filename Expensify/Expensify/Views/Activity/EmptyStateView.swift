import SwiftUI

/// Activity tab when the review queue is empty.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(AppColor.inflow)
            Text("all caught up")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
            Text("nothing needs your review.")
                .font(AppFont.rowSubtitle)
                .foregroundStyle(AppColor.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

#Preview {
    EmptyStateView()
        .background(AppColor.canvas)
}
