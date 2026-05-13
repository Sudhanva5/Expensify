import SwiftUI
import MapKit

/// Bottom-sheet detail surfaced when the user taps the ⓘ next to a row, or
/// taps the location chip. Replaces the earlier popover; the popover was
/// too cramped to show a map preview without feeling like a tooltip stuck
/// to the wrong element.
///
/// Layout, top to bottom:
///   ┌─────────────────────────────────────────────────────┐
///   │ [avatar] VPA Name                  transaction time │
///   │          Location Name                              │
///   │                                                     │
///   │ ┌─────────────────────────────────────────────┐     │
///   │ │                Maps preview                 │     │
///   │ └─────────────────────────────────────────────┘     │
///   │                                                     │
///   │ [          Go to Google Maps          ]             │
///   └─────────────────────────────────────────────────────┘
///
/// Presented via `.sheet(presentationDetents: [.medium])`. Falls back
/// gracefully when the transaction has no coordinates (hides the map +
/// Maps button, keeps the header).
struct TransactionDetailSheet: View {
    let transaction: Transaction

    /// Optional override for the small "VPA Name" line. iOS sets this to a
    /// matched contact's full name when applicable.
    var contactName: String? = nil
    /// Optional contact photo data — replaces the avatar when supplied.
    var contactImageData: Data? = nil

    @Environment(\.dismiss) private var dismiss

    private var hasMap: Bool { transaction.hasCoordinates }

    private var primaryTitle: String {
        if transaction.hasResolvedMerchant {
            return transaction.merchantNormalized
        }
        return transaction.displayMerchant
    }

    /// Small line above the title — shows what the bank/UPI knew about
    /// this payee. Falls back to "—" when there's no VPA-level data.
    private var subtitle: String {
        if let contactName, !contactName.isEmpty {
            return contactName
        }
        if !transaction.merchantRaw.isEmpty,
           transaction.merchantRaw.caseInsensitiveCompare(primaryTitle) != .orderedSame {
            return transaction.merchantRaw
        }
        if let vpa = transaction.vpa, !vpa.isEmpty {
            return vpa
        }
        return ""
    }

    /// Content-sized height per Apple HIG ("Sheets") — the sheet should be
    /// just big enough for its contents, no taller. With a map: header
    /// (~70) + 16 spacing + map (180) + 16 spacing + button (44) + 24
    /// bottom padding + drag indicator + safe area ≈ 380. Without a map:
    /// only the header + small bottom padding ≈ 140.
    private var sheetHeight: CGFloat {
        hasMap ? 380 : 140
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header
                if hasMap { mapPreview }
                if hasMap { mapsButton }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColor.canvas)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MerchantAvatar(
                merchantName: primaryTitle,
                size: 44,
                contactImageData: contactImageData
            )

            VStack(alignment: .leading, spacing: 2) {
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(AppColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(primaryTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(transactionTimingText)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(AppColor.textTertiary)
                .multilineTextAlignment(.trailing)
                .layoutPriority(0)
        }
    }

    @ViewBuilder
    private var mapPreview: some View {
        if let lat = transaction.locationLat, let lng = transaction.locationLng {
            Map(initialPosition: .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
                )
            )) {
                Marker(primaryTitle, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))
                    .tint(AppColor.tap)
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .all))
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.hairline, lineWidth: 0.5)
            )
            // Whole map is tappable too — opens Apple Maps.
            .onTapGesture { openInMaps() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open in Maps")
        }
    }

    @ViewBuilder
    private var mapsButton: some View {
        Button(action: openInMaps) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .semibold))
                Text("Go to Google Maps")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AppColor.textPrimary)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var transactionTimingText: String {
        let df = DateFormatter()
        df.dateFormat = "d MMM ''yy"
        let date = df.string(from: transaction.occurredAt).lowercased()
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        let time = tf.string(from: transaction.occurredAt).lowercased()
        return "\(date)\n\(time)"
    }

    private func openInMaps() {
        guard let lat = transaction.locationLat,
              let lng = transaction.locationLng else { return }
        // Use Google Maps app if installed, otherwise fall back to the
        // web URL (which iOS will open in Safari → defer to Maps app if
        // user has the Google Maps app set as the default).
        let label = primaryTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let appURL = URL(string: "comgooglemaps://?q=\(label)&center=\(lat),\(lng)&zoom=18")!
        let webURL = URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lng)")!

        if UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else {
            UIApplication.shared.open(webURL)
        }
    }
}

#Preview {
    let mock = Transaction(
        id: "preview-1",
        amountInr: 540,
        currency: "INR",
        merchantRaw: "RAJESH KUMAR",
        merchantNormalized: "MTR Restaurant Jayanagar",
        vpa: "rajesh.kumar@oksbi",
        direction: .out,
        instrument: "account_5264",
        occurredAt: Date(),
        category: .food,
        confidence: 0.97,
        signalSource: .places,
        status: .resolved,
        locationLat: 12.9252,
        locationLng: 77.5938,
        locationCity: "Bengaluru",
        locationStatus: .fulfilled
    )

    return Color.gray.sheet(isPresented: .constant(true)) {
        TransactionDetailSheet(transaction: mock)
    }
}
