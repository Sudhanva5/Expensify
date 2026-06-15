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
    @Environment(TransactionStore.self) private var store

    /// Editable buffer for the notes editor. Initialised from the
    /// transaction on appear; saved on commit (blur / Done button).
    /// Kept separate from `transaction.notes` so users can edit + cancel
    /// without rewriting the store row.
    @State private var notesDraft: String = ""
    @State private var notesOriginal: String = ""
    @State private var notesSaving: Bool = false
    @FocusState private var notesFocused: Bool

    private var hasMap: Bool { transaction.hasCoordinates }

    private var primaryTitle: String {
        if transaction.hasResolvedMerchant {
            return transaction.merchantNormalized
        }
        return transaction.displayMerchant
    }

    /// Content-sized height per Apple HIG ("Sheets") — adapts to which
    /// sections are present. Receipt adds ~140pts (snippet card) to
    /// ~240pts (full items card); map adds 240pts. Numbers tuned to leave
    /// minimal trailing whitespace on iPhone 14/15-class screens.
    private var sheetHeight: CGFloat {
        let receipt = transaction.receipt
        let receiptHeight: CGFloat = receipt?.hasStructuredItems == true
            ? 240
            : (receipt != nil ? 140 : 0)
        let base: CGFloat = hasMap ? 380 : 140
        // Notes editor adds ~160pts (80 input + section label + footnote).
        // Always present, so always count it.
        let notesHeight: CGFloat = 160
        // Use a fraction-style cap so very tall sheets still fit the
        // screen — the system will switch to a scrollable detent.
        return min(base + receiptHeight + notesHeight, 760)
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if hasMap { mapPreview }
                    if hasMap { mapsButton }
                    if let suggestions = transaction.placesSuggestions,
                       !suggestions.isEmpty,
                       !transaction.hasResolvedMerchant {
                        NearbyPlacesPicker(
                            transactionId: transaction.id,
                            suggestions: suggestions
                        )
                    }
                    if let receipt = transaction.receipt {
                        ReceiptCard(receipt: receipt)
                    }
                    notesEditor
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.height(sheetHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColor.canvas)
        .task {
            // Seed the draft from the transaction once per appearance.
            // Re-seeding on every body invocation would clobber in-progress
            // typing, so we use `.task` (runs on appear, cancelled on
            // dismiss) instead of `.onChange(of: transaction.notes)`.
            notesDraft = transaction.notes ?? ""
            notesOriginal = notesDraft
        }
    }

    /// Notes editor — a TextEditor (multi-line) wrapped in a card with the
    /// same hairline border as ReceiptCard. Save fires on:
    ///   1. blur (focus leaves the field), AND
    ///   2. explicit "save" button (only shown when the draft differs from
    ///      the original — keeps the chrome quiet when nothing changed).
    /// Saving optimistically updates the store row so the next time the
    /// sheet renders the value is already there.
    @ViewBuilder
    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("notes")
                    .font(.system(size: 11, weight: .semibold).smallCaps())
                    .foregroundStyle(AppColor.textTertiary)
                Spacer()
                if notesSaving {
                    ProgressView().controlSize(.small)
                } else if notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    != notesOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
                {
                    Button("save") { Task { await saveNotes() } }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.tap)
                        .buttonStyle(.plain)
                }
            }

            // TextEditor doesn't have a placeholder — overlay a ghost
            // string when empty so the field doesn't read as broken.
            ZStack(alignment: .topLeading) {
                if notesDraft.isEmpty && !notesFocused {
                    Text("e.g. 'ETF rebalance — keep for taxes' or 'paid Anita back for dinner'")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColor.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notesDraft)
                    .focused($notesFocused)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minHeight: 80, maxHeight: 200)
            }
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppColor.hairline, lineWidth: 0.5)
            )
            .onChange(of: notesFocused) { _, newFocused in
                // Auto-save on blur — but only if something actually
                // changed. Avoid spurious PATCH requests when the user
                // taps the field, scrolls, and dismisses.
                if !newFocused {
                    let trimmed = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let originalTrimmed = notesOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != originalTrimmed {
                        Task { await saveNotes() }
                    }
                }
            }

            Text("private to you. surfaced to claude via mcp so spend questions can reference what you wrote.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    private func saveNotes() async {
        let trimmed = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        notesSaving = true
        defer { notesSaving = false }
        do {
            try await APIClient.shared.updateNotes(
                transactionId: transaction.id,
                notes: trimmed
            )
            notesOriginal = trimmed
            notesDraft = trimmed
            // Refresh the store so the next render of any view that holds
            // this transaction sees the new value too.
            await store.refresh()
        } catch {
            // Surface the error inline with the save button — keep the
            // draft so the user can retry without re-typing.
            print("[notes] save failed:", error.localizedDescription)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MerchantAvatar(
                merchantName: primaryTitle,
                size: 44,
                // Stable brand key from the bank's text, not the
                // renameable title — see MerchantAvatar.brandKey.
                brandKey: transaction.merchantRaw.isEmpty
                    ? transaction.vpa ?? ""
                    : transaction.merchantRaw,
                contactImageData: contactImageData,
                contactName: contactName,
                categoryFallback: transaction.category
            )

            VStack(alignment: .leading, spacing: 3) {
                // Small attribution caption — tells the user where the
                // headline name comes from. For Places-resolved rows it
                // says "probable nearby place"; for contact rows it says
                // "from your contacts". Title below is the only name we
                // show — no VPA / merchantRaw subtitle, intentionally,
                // since duplicating the bank's cryptic payee right under
                // a probable-place name was confusing.
                if !attributionLabel.isEmpty {
                    Text(attributionLabel)
                        .font(.system(size: 10, weight: .semibold).smallCaps())
                        .foregroundStyle(AppColor.textTertiary)
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

    /// One-line attribution shown above the title in the sheet. Honest
    /// signal about where the "what is this transaction" name came from.
    private var attributionLabel: String {
        if contactName != nil { return "from your contacts" }
        if transaction.wasPlacesResolved || transaction.hasResolvedMerchant {
            return "probable nearby place"
        }
        return ""
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
            // Monochrome inverse pair: bg = tap (dark grey in light /
            // light grey in dark), fg = canvas (the OPPOSITE: light in
            // light, dark in dark). Never `.white` literal — that
            // disappears against tap's near-white dark-mode value.
            .background(AppColor.tap)
            .foregroundStyle(AppColor.canvas)
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
