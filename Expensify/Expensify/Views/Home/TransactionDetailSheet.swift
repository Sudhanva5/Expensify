import SwiftUI
import MapKit

/// Full-length transaction detail sheet (Apple-Wallet-style). No hero
/// image — a compact identity header, then stacked cards.
///
/// Layout, top to bottom:
///   • Top bar: back (dismiss) · "Edit details"
///   • Identity: merchant logo · name · category
///   • Location card: probable place name + amount, embedded map,
///     tappable "place, city" row (only when coordinates exist)
///   • Email-receipt card: itemized, functional receipt (when an email
///     receipt was bound)
///
/// "Edit details" presents `CategoryPickerSheet` — category / rename /
/// pin-to-contact / notes.
struct TransactionDetailSheet: View {
    let transaction: Transaction

    /// Optional override for the headline (a matched contact's full name).
    var contactName: String? = nil
    /// Optional contact photo data — replaces the avatar when supplied.
    var contactImageData: Data? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(TransactionStore.self) private var store
    @Environment(ContactsService.self) private var contactsService

    @State private var showingEdit = false

    /// Latest version of this transaction from the store, so edits made in
    /// the edit sheet (notes, category, rename) propagate back here live.
    private var current: Transaction {
        store.transactions.first { $0.id == transaction.id } ?? transaction
    }

    private var hasMap: Bool { transaction.hasCoordinates }

    private var primaryTitle: String {
        if transaction.hasResolvedMerchant { return transaction.merchantNormalized }
        return contactName ?? transaction.displayMerchant
    }

    /// Probable place shown under the map — prefers a Places-resolved
    /// business name, then the city, then a generic fallback (never raw
    /// coordinates).
    private var probablePlaceName: String {
        if transaction.wasPlacesResolved || transaction.hasResolvedMerchant {
            return transaction.merchantNormalized
        }
        if let city = transaction.locationCity, !city.isEmpty { return city }
        return "Nearby"
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identityHeader
                        summaryCard
                        noteSection
                        if let suggestions = transaction.placesSuggestions,
                           !suggestions.isEmpty,
                           !transaction.hasResolvedMerchant {
                            NearbyPlacesPicker(
                                transactionId: transaction.id,
                                suggestions: suggestions
                            )
                        }
                        if let receipt = transaction.receipt {
                            receiptSection(receipt)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(AppColor.canvas)
        .sheet(isPresented: $showingEdit) {
            CategoryPickerSheet(transaction: current)
                .environment(store)
                .environment(contactsService)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .glassControl(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button { showingEdit = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .glassControl(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit details")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: Identity header — logo · name · category

    private var identityHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            MerchantAvatar(
                merchantName: primaryTitle,
                size: 60,
                brandKey: transaction.merchantRaw.isEmpty
                    ? transaction.vpa ?? ""
                    : transaction.merchantRaw,
                contactImageData: contactImageData,
                contactName: contactName,
                categoryFallback: transaction.category
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let category = transaction.category {
                    Text(category.shortName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: Summary / location card

    private var summaryCard: some View {
        VStack(spacing: 0) {
            // Top strip: date over time (left), amount (right). No place
            // name here — it would just repeat the header.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dateText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                    Text(timeText)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColor.textTertiary)
                }
                Spacer(minLength: 8)
                AmountText(amount: transaction.amountInr, direction: transaction.direction, size: 18)
            }
            .padding(14)

            if hasMap {
                // Whole map embed is tappable → opens Maps. The Map itself
                // has hit-testing disabled, so this contentShape + tap
                // covers the entire embed (not just the row below).
                mapPreview
                    .contentShape(Rectangle())
                    .onTapGesture { openInMaps() }
                Divider().overlay(AppColor.hairline)
                // Probable place name (not coordinates) under the map.
                Button(action: openInMaps) {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(AppColor.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Probable Place")
                                .font(.system(size: 10, weight: .semibold).smallCaps())
                                .foregroundStyle(AppColor.textTertiary)
                            Text(probablePlaceName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(AppColor.textPrimary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColor.textTertiary)
                    }
                    .padding(14)
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                    .tint(AppColor.textSecondary)
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .all))
            .frame(height: 190)
            .allowsHitTesting(false)
        }
    }

    // MARK: Note

    /// Shows the user's note (read live from the store, so it appears as
    /// soon as it's saved in the edit sheet). Tap to edit.
    @ViewBuilder
    private var noteSection: some View {
        let note = current.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !note.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Note")
                    .font(.system(size: 12, weight: .semibold).smallCaps())
                    .foregroundStyle(AppColor.textTertiary)
                Button { showingEdit = true } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "note.text")
                            .font(.system(size: 15))
                            .foregroundStyle(AppColor.textSecondary)
                        Text(note)
                            .font(.system(size: 15))
                            .foregroundStyle(AppColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(AppColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Email receipt

    @ViewBuilder
    private func receiptSection(_ receipt: ReceiptDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Email Receipt")
                .font(.system(size: 12, weight: .semibold).smallCaps())
                .foregroundStyle(AppColor.textTertiary)
            ReceiptCard(receipt: receipt)
        }
    }

    // MARK: Helpers

    private var dateText: String {
        let df = DateFormatter()
        df.dateFormat = "d MMMM yyyy"
        return df.string(from: transaction.occurredAt)
    }

    private var timeText: String {
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        return tf.string(from: transaction.occurredAt)
    }

    /// Opens the location in a maps app: Google Maps if installed,
    /// otherwise Apple Maps (always available on iOS).
    private func openInMaps() {
        guard let lat = transaction.locationLat,
              let lng = transaction.locationLng else { return }
        let label = primaryTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let googleApp = URL(string: "comgooglemaps://?q=\(label)&center=\(lat),\(lng)&zoom=18")!
        let appleMaps = URL(string: "http://maps.apple.com/?ll=\(lat),\(lng)&q=\(label)")!
        if UIApplication.shared.canOpenURL(googleApp) {
            UIApplication.shared.open(googleApp)
        } else {
            UIApplication.shared.open(appleMaps)
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
            .environment(TransactionStore())
            .environment(ContactsService())
    }
}
