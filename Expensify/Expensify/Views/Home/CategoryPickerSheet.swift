import SwiftUI
import Contacts

/// Compact bottom sheet shown when the user swipes a row → "edit tag".
/// Lists the seven V1 categories as tappable rows; selecting one fires
/// `TransactionStore.retag(...)` which optimistically updates the row
/// and PATCHes the backend in the background.
///
/// Sheet height is set explicitly so it matches content — see Apple HIG
/// "Sheets": presentations should be sized for their content, not the
/// full half-screen .medium detent. Anything taller than this would leave
/// awkward whitespace below the seven category rows.
struct CategoryPickerSheet: View {
    let transaction: Transaction

    @Environment(\.dismiss) private var dismiss
    @Environment(TransactionStore.self) private var store
    @Environment(ContactsService.self) private var contactsService

    /// Drives the "Save as rule" follow-up sheet. Set when the user picks
    /// a category; the wizard inherits that category as the rule's action.
    @State private var createRuleFor: Category?
    /// Drives the iPhone-Contacts picker sheet for pinning a VPA to a
    /// specific person. Only meaningful when the transaction has a VPA
    /// that isn't a merchant Q-code.
    @State private var showingContactPicker: Bool = false
    /// Snapshot of the pinned contact name (so the sheet's "current pin"
    /// row reflects edits without bouncing off the parent view).
    @State private var pinnedName: String?

    /// True when this row is eligible for a contact pin. We allow pins
    /// on any UPI debit from a bank account whose VPA isn't a clear
    /// merchant Q-code. Credit-card transactions and merchant-VPA rows
    /// are people-agnostic and skip the affordance.
    private var canPinContact: Bool {
        guard transaction.direction == .out else { return false }
        guard transaction.instrument.hasPrefix("account_") else { return false }
        guard let vpa = transaction.vpa, !vpa.isEmpty else { return false }
        return !ContactsService.isMerchantVpaPublic(vpa)
    }

    /// Content-sized detent. Footer grows when the contact-pin option is
    /// visible so layout never crops.
    private var sheetHeight: CGFloat {
        let base: CGFloat = 520
        return canPinContact ? base + 56 : base
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().opacity(0.4)
                categoryList
                Divider().opacity(0.4)
                createRuleFooter
                if canPinContact {
                    pinContactFooter
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColor.canvas)
        .sheet(item: $createRuleFor) { cat in
            CreateRuleSheet(transaction: transaction, category: cat)
        }
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerSheet(
                onPick: { cn in
                    if let vpa = transaction.vpa {
                        contactsService.pin(vpa: vpa, toContactId: cn.identifier)
                        // Refresh the local CN cache so the new pin
                        // surfaces immediately without a relaunch.
                        Task { await contactsService.requestAccessAndLoad() }
                        let display = "\(cn.givenName) \(cn.familyName)".trimmingCharacters(in: .whitespaces)
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

    /// Anchored at the bottom of the picker. Opens the "create rule from
    /// this transaction" wizard pre-filled with the row's current
    /// category. Available regardless of whether the user changed the
    /// category — sometimes the displayed category is already right but
    /// the user wants to teach the system to recognize this *kind* of
    /// transaction automatically next time.
    /// Bottom-most footer when the row could plausibly be a P2P. Lets the
    /// user override the algorithm with a manual `VPA → iPhone-contact`
    /// pin. Shows the currently-pinned name (with an unpin affordance) or
    /// the "tap to pin" prompt depending on state.
    @ViewBuilder
    private var pinContactFooter: some View {
        Button {
            showingContactPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pinnedName == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.fill.badge.checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(pinnedName == nil ? AppColor.tap : AppColor.inflow)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pinnedName == nil ? "pin to contact" : "pinned: \(pinnedName ?? "")")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColor.textPrimary)
                    if pinnedName != nil {
                        Text("tap to change · long-press to unpin")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Unpin gesture — only meaningful when a pin already exists.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard let vpa = transaction.vpa, pinnedName != nil else { return }
                contactsService.unpin(vpa: vpa)
                pinnedName = nil
            }
        )
    }

    @ViewBuilder
    private var createRuleFooter: some View {
        Button {
            let cat = transaction.category ?? .personalTransfer
            createRuleFor = cat
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.tap)
                Text("create rule from this transaction")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("change category")
                .font(.system(size: 11, weight: .semibold).smallCaps())
                .foregroundStyle(AppColor.textTertiary)
            Text(transaction.displayMerchant)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var categoryList: some View {
        VStack(spacing: 2) {
            ForEach(Category.allCases) { cat in
                Button(action: { pick(cat) }) {
                    HStack(spacing: 12) {
                        Image(systemName: cat.symbolName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColor.textPrimary)
                            .frame(width: 28, height: 28)
                            .background(AppColor.avatarFill)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Text(cat.shortName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppColor.textPrimary)

                        Spacer()

                        if transaction.category == cat {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppColor.tap)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Pick a category — fire the optimistic retag, dismiss immediately.
    /// The store handles the network round-trip + error recovery; the user
    /// shouldn't have to wait staring at the sheet while we POST.
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
    }
}
