import Foundation

/// Single-user V1 — the owner of the app. One place to update name/email
/// so the avatar initials and Settings profile section stay in sync.
enum CurrentUser {
    static let name: String = "Sudhanva Udupi"
    static let email: String = "sudhanva.udupi55@gmail.com"

    /// Two-letter initials derived from name. "Sudhanva Udupi" → "SU".
    /// Used in the nav-bar avatar and Settings profile circle.
    static var initials: String {
        let parts = name
            .split(separator: " ")
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return ((parts[0].first.map(String.init) ?? "")
                + (parts[1].first.map(String.init) ?? "")).uppercased()
        }
        if let only = parts.first {
            return String(only.prefix(2)).uppercased()
        }
        return "•"
    }
}
