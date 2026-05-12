import SwiftUI

/// Tappable location pill on a transaction. Opens Apple Maps at the captured
/// lat/lng when tapped. Renders nothing for transactions we know don't have
/// a meaningful location (autopay, inflows).
struct LocationChip: View {
    let label: String?
    let status: Transaction.LocationStatus
    let latitude: Double?
    let longitude: Double?
    let merchantLabel: String?
    var compact: Bool = false

    var body: some View {
        if status == .notApplicable {
            EmptyView()
        } else if status == .fulfilled, let lat = latitude, let lng = longitude {
            Button {
                MapsLinker.open(latitude: lat, longitude: lng, label: merchantLabel)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(text)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(background)
        .clipShape(Capsule())
    }

    private var text: String {
        switch status {
        case .fulfilled: return label ?? "captured"
        case .missed: return "no location"
        case .awaiting: return "locating…"
        case .notApplicable: return ""
        }
    }

    private var foreground: Color {
        switch status {
        case .fulfilled: return .blue
        case .missed: return .secondary.opacity(0.7)
        case .awaiting: return .blue
        case .notApplicable: return .clear
        }
    }

    private var background: Color {
        switch status {
        case .fulfilled: return Color.blue.opacity(0.12)
        case .missed: return Color(.tertiarySystemFill)
        case .awaiting: return Color.blue.opacity(0.10)
        case .notApplicable: return .clear
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        LocationChip(label: "Bengaluru", status: .fulfilled, latitude: 12.93, longitude: 77.62, merchantLabel: "MTR Hotel")
        LocationChip(label: nil, status: .missed, latitude: nil, longitude: nil, merchantLabel: nil)
        LocationChip(label: nil, status: .awaiting, latitude: nil, longitude: nil, merchantLabel: nil)
        LocationChip(label: nil, status: .notApplicable, latitude: nil, longitude: nil, merchantLabel: nil)
    }
    .padding()
}
