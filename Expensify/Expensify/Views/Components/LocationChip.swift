import SwiftUI

/// Tiny pill that shows where a transaction took place.
/// • fulfilled → "📍 Bengaluru" (or coords if no city)
/// • missed → "📍 unknown" (greyed out)
/// • notApplicable → not rendered (autopay / inflow have no location)
/// • awaiting → "📍 …" pulsing while we wait for the phone to respond
struct LocationChip: View {
    let label: String?
    let status: Transaction.LocationStatus

    var body: some View {
        if status == .notApplicable {
            EmptyView()
        } else {
            HStack(spacing: 3) {
                Image(systemName: "location.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(Capsule())
        }
    }

    private var text: String {
        switch status {
        case .fulfilled: return label ?? "captured"
        case .missed: return "unknown"
        case .awaiting: return "locating…"
        case .notApplicable: return ""
        }
    }

    private var foreground: Color {
        switch status {
        case .fulfilled: return .secondary
        case .missed: return .secondary.opacity(0.6)
        case .awaiting: return .blue
        case .notApplicable: return .clear
        }
    }

    private var background: Color {
        switch status {
        case .fulfilled: return Color(.tertiarySystemFill)
        case .missed: return Color(.quaternarySystemFill)
        case .awaiting: return Color.blue.opacity(0.12)
        case .notApplicable: return .clear
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        LocationChip(label: "Bengaluru", status: .fulfilled)
        LocationChip(label: "12.935, 77.624", status: .fulfilled)
        LocationChip(label: nil, status: .missed)
        LocationChip(label: nil, status: .awaiting)
        LocationChip(label: nil, status: .notApplicable) // renders nothing
    }
    .padding()
}
