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
    /// Drives the rename alert that lets the user edit the merchant
    /// display name. On submit, fires apply-place which (a) updates
    /// THIS row's merchantNormalized and (b) bulk-updates every other
    /// row with the same VPA to the new name.
    @State private var showingRenamePrompt: Bool = false
    @State private var renameDraft: String = ""
    @State private var renaming: Bool = false

    /// Drives the notes editor sheet. Presented OVER this picker, so the
    /// picker stays underneath when the editor is dismissed (mirrors how
    /// the contact picker works).
    @State private var showingNotesEditor: Bool = false

    /// True when this row is eligible for a contact pin. Any UPI flow
    /// from a bank account — inbound OR outbound — whose VPA isn't a
    /// merchant Q-code. A ₹1 inbound from Bivek and a ₹1 outbound to
    /// Bivek are the same person; the user wants to pin either side.
    /// (Merchant Q-codes are shops, no person to attach.)
    private var canPinContact: Bool {
        guard transaction.instrument.hasPrefix("account_") else { return false }
        guard let vpa = transaction.vpa, !vpa.isEmpty else { return false }
        return !ContactsService.isMerchantVpaPublic(vpa)
    }

    /// Content-sized detent. header (~72) + 7 category rows (~48 each)
    /// + rename row (~56 + divider) + notes row (~56 + divider) +
    /// optional pin row (~64 + divider) + bottom cushion. Grows
    /// depending on which optional rows are actually shown.
    private var sheetHeight: CGFloat {
        let base: CGFloat = 490
        let renameRow: CGFloat = 56 // always shown
        let notesRow: CGFloat = 56  // always shown
        let pinRow: CGFloat = canPinContact ? 64 : 0
        return base + renameRow + notesRow + pinRow
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().opacity(0.4)
                categoryList
                Divider().opacity(0.4)
                renameRow
                Divider().opacity(0.4)
                notesRow
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
        .alert("rename merchant", isPresented: $showingRenamePrompt) {
            TextField("display name", text: $renameDraft)
                .textInputAutocapitalization(.words)
            Button("cancel", role: .cancel) {}
            Button(renaming ? "saving…" : "save") {
                Task { await submitRename() }
            }
            .disabled(renaming || renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            if let vpa = transaction.vpa, !vpa.isEmpty {
                Text("applies to all transactions on \(vpa).")
            } else {
                Text("applies to this transaction only — it has no VPA to propagate against.")
            }
        }
        .sheet(isPresented: $showingNotesEditor) {
            NotesEditorSheet(transaction: transaction)
                .environment(store)
        }
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
            Text("edit details")
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
            Text(canPinContact
                 ? "pick category · rename · notes · pin contact"
                 : "pick category · rename · notes")
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
                        accessory: transaction.category == cat ? .checkmark : .none,
                        highlighted: transaction.category == cat
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Lets the user override the merchant display name. When the row
    /// has a VPA, the rename bulk-applies to every other transaction
    /// with the same VPA — same propagation flow as claiming a Nearby
    /// Places suggestion. The user can give an opaque "PAYTMQR…" payee
    /// a human-readable name once and have it stick across history +
    /// future debits (the backend stores the name in VpaPattern so
    /// fresh inbound transactions adopt it on first parse).
    @ViewBuilder
    private var renameRow: some View {
        Button {
            renameDraft = transaction.displayMerchant
            showingRenamePrompt = true
        } label: {
            rowLayout(
                icon: "pencil",
                title: "rename merchant",
                subtitle: transaction.vpa.map { "applies to \($0)" }
                    ?? "applies to this row only",
                accessory: .chevron,
                highlighted: true
            )
        }
        .buttonStyle(.plain)
    }

    /// Opens the dedicated NotesEditorSheet stacked above this picker.
    /// We use a separate sheet (not an inline expansion) because a
    /// multi-line TextEditor needs more room than the picker can
    /// afford without disrupting the rest of the rows.
    ///
    /// Subtitle previews the first ~60 chars of the existing note so
    /// the user can tell whether one is already attached without
    /// drilling in.
    @ViewBuilder
    private var notesRow: some View {
        let existing = transaction.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview: String? = existing.isEmpty
            ? nil
            : String(existing.prefix(60)) + (existing.count > 60 ? "…" : "")
        Button {
            showingNotesEditor = true
        } label: {
            rowLayout(
                icon: existing.isEmpty ? "square.and.pencil" : "note.text",
                title: existing.isEmpty ? "add notes" : "edit notes",
                subtitle: preview,
                accessory: .chevron,
                highlighted: true
            )
        }
        .buttonStyle(.plain)
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
                accessory: .chevron,
                highlighted: true
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
    /// `highlighted` rows get the accent-blue glyph treatment (used
    /// for the contact-pin row + the currently-selected category).
    private enum RowAccessory { case none, checkmark, chevron }

    @ViewBuilder
    private func rowLayout(
        icon: String,
        title: String,
        subtitle: String?,
        accessory: RowAccessory,
        highlighted: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(highlighted ? AppColor.tap : AppColor.textPrimary)
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

    /// Submit the rename. Reuses `applyPlace` on the store — same
    /// endpoint used by the Nearby Places picker: writes
    /// merchantNormalized on this row + bulk-updates every other row
    /// with the same VPA + records VpaPattern.merchantName so future
    /// debits adopt the name on first parse.
    private func submitRename() async {
        renaming = true
        defer { renaming = false }
        let name = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Keep the row's existing category — the rename is name-only.
        let cat = transaction.category ?? .personalTransfer
        await store.applyPlace(
            transactionId: transaction.id,
            placesName: name,
            category: cat,
            lat: nil,
            lng: nil
        )
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
