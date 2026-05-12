import SwiftUI

/// Profile avatar in the nav bar — opens Settings on tap.
struct AvatarButton: View {
    let initials: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(initials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .frame(width: 32, height: 32)
                .background(AppColor.avatarFill)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(AppColor.hairline, lineWidth: 0.5)
                )
        }
        .accessibilityLabel("Settings")
    }
}

#Preview {
    NavigationStack {
        Text("Demo")
            .navigationTitle("home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AvatarButton(initials: "SA") { }
                }
            }
    }
}
