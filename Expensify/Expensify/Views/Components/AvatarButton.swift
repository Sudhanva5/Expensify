import SwiftUI

/// Avatar pill in the navigation bar. Tapping it opens the Settings sheet.
struct AvatarButton: View {
    let initials: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(initials)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor)
                .clipShape(Circle())
        }
        .accessibilityLabel("Settings")
    }
}

#Preview {
    NavigationStack {
        Text("Demo")
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AvatarButton(initials: "SA") { }
                }
            }
    }
}
