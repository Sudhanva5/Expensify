import SwiftUI
import Contacts

/// Compact bottom sheet shown when the user swipes a row → "edit details".
/// Lists the seven V1 categories as tappable rows; selecting one fires
/// `TransactionStore.retag(...)` which optimistically updates the row
/// and PATCHes the backend in the background.
///
/// For UPI-from-account rows with a non-merchant VPA, a "pin to contact"
/// row sits at the bottom of the list (same visual style as the category
/// rows) so the user can manually link a VPA to a specific iPhone
/// contact when the algorithmic matcher can't.
///
/// Sheet height is set explicitly so it matches content — see Apple HIG
/// "Sheets": presentations should be sized for their content, not the
/// full half-screen .medium detent.
struct CategoryPickerSheet: View {
    let transaction: Transaction

    @Environment(\.dismiss) private var dismiss
    @Environment(TransactionStore.self) private var store
    @Environment(ContactsService.self) private var contactsService

    /// Drives the iPhone-Contacts picker sheet for pinning a VPA to a
    /// specific person. Only meaningful when the transaction has a VPA
    /// that isn't a merchant Q-code.
    @State private var showingContactPicker: Bool = false
    /// Snapshot of the pinned contact name, refreshed on appear and on
    /// every successful pick so the sheet shows the current state.
    @State private var pinnedName: String?

    /// True when this row is eligible for a contact pin. UPI debit from
    /// a bank account whose VPA isn't a merchant Q-code (those are shops,
    /// not people, so no contact-overlay makes sense).
    private var canPinContact: Bool {
        guard transaction.direction == .out else { return false }
        guard transaction.instrument.hasPrefix("account_") else { return false }
        guard let vpa = transaction.vpa, !vpa.isEmpty else { return false }
        return !ContactsService.isMerchantVpaPublic(vpa)
    }

    /// Content-sized detent. header (~72 with the action one-liner) +
    /// divider + 7 category rows (~48 each) + optional pin row (~48 +
    /// divider ~12) + bottom cushion. Grows only when the pin row is
    /// actually shown.
    private var sheetHeight: CGFloat {
        let base: CGFloat = 490
        return canPinContact ? base + 64 : base
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().opacity(0.4)
                categoryList
                if canPinContact {
                    Divider().opacity(0.4)
                    contactPinRow
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColor.canvas)
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerSheet(
                onPick: { cn in
                    if let vpa = transaction.vpa {
                        contactsService.pin(vpa: vpa, toContactId: cn.identifier)
                        // Refresh the local CN cache so the new pin
                        // surfaces immediately without a relaunch.
                        Task { await contactsService.requestAccessAndLoad() }
                        let display = "\(cn.givenName) \(cn.familyName)"
                            .trimmingCharacters(in: .whitespaces)
                        pinnedName = display.isEmpty ? nil : display
                    }
                    showingContactPicker = false
                },
                onCancel: { showingContactPicker = false }
            )
        }
        .onAppear {
            if let vpa = transaction.vpa,
               let c = contactsService.pinnedContact(for: vpa) {
                pinnedName = c.displayName
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("edit tag")
                .font(.system(size: 11, weight: .semibold).smallCaps())
                .foregroundStyle(AppColor.textTertiary)
            Text(transaction.displayMerchant)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            // One-liner hint of what's available in the sheet. Drops
            // the contact half when the row isn't pin-eligible (merchant
            // VPAs / credit card rows) so we don't promise affordances
            // that won't appear below.
            Text(canPinContact ? "add contact · pick category" : "pick category")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var categoryList: some View {
        VStack(spacing: 2) {
            ForEach(Category.allCases) { cat in
                Button(action: { pick(cat) }) {
                    rowLayout(
                        icon: cat.symbolName,
                        title: cat.shortName,
                        subtitle: nil,
                        accessory: transaction.category == cat ? .checkmark : .none
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Same visual language as the category rows above: 28pt rounded-
    /// square icon, 15pt medium title, optional secondary caption when
    /// already pinned. Reads as part of the same "edit details" list
    /// instead of a tacked-on footer.
    @ViewBuilder
    private var contactPinRow: some View {
        Button {
            showingContactPicker = true
        } label: {
            rowLayout(
                icon: pinnedName == nil
                    ? "person.crop.circle.badge.plus"
                    : "person.crop.circle.fill.badge.checkmark",
                title: pinnedName ?? "pin to contact",
                subtitle: pinnedName != nil ? "long-press to unpin" : nil,
                accessory: .chevron
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard let vpa = transaction.vpa, pinnedName != nil else { return }
                contactsService.unpin(vpa: vpa)
                pinnedName = nil
            }
        )
    }

    /// Shared row scaffold — keeps every line in the sheet on the same
    /// grid so the category list and the pin row don't visually drift.
    private enum RowAccessory { case none, checkmark, chevron }

    @ViewBuilder
    private func rowLayout(
        icon: String,
        title: String,
        subtitle: String?,
        accessory: RowAccessory
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .frame(width: 28, height: 28)
                .background(AppColor.avatarFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            switch accessory {
            case .none:
                EmptyView()
            case .checkmark:
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.tap)
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Pick a category — fire the optimistic retag, dismiss immediately.
    /// The store handles the network round-trip + error recovery; the
    /// user shouldn't wait staring at the sheet while we POST.
    private func pick(_ category: Category) {
        let txId = transaction.id
        Task { await store.retag(transactionId: txId, to: category) }
        dismiss()
    }
}

#Preview {
    let mock = Transaction(
        id: "p1", amountInr: 320, currency: "INR",
        merchantRaw: "RAJESH KUMAR", merchantNormalized: "RAJESH KUMAR",
        vpa: "rajesh@oksbi", direction: .out, instrument: "account_5264",
        occurredAt: Date(), category: .food, confidence: nil, signalSource: nil,
        status: .pendingReview, locationLat: nil, locationLng: nil,
        locationCity: nil, locationStatus: .missed
    )
    return Color.gray.sheet(isPresented: .constant(true)) {
        CategoryPickerSheet(transaction: mock)
            .environment(TransactionStore())
            .environment(ContactsService())
    }
}
