import SwiftUI

/// Profile avatar in the header — opens Settings on tap. Renders the
/// user's chosen profile photo when set, falling back to initials.
struct AvatarButton: View {
    let initials: String
    /// User-picked profile photo; nil shows the initials badge.
    var image: UIImage? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(initials)
                        .font(.system(size: 13, weight: .semibold))
                        // Accent-blue initials match the other interactive
                        // items (Done / + / Save) so this reads as an
                        // actionable affordance, not a static badge.
                        .foregroundStyle(AppColor.tap)
                }
            }
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
