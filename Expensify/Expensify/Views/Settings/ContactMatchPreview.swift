import SwiftUI

/// Pushed from Settings → Contacts → "view recent matches". For the last
/// ~30 outbound UPI transactions, shows which contact (if any) we
/// matched and whether their photo is cached. Diagnostic only — lets
/// the user answer "why does this row show initials instead of a photo?"
/// without diving into Xcode console.
///
/// Three possible per-row states:
///   • no match       — payee doesn't resolve to a contact (no phone in
///                       VPA, name too short or ambiguous)
///   • matched, photo — contact found AND has cached photo data
///   • matched, ——   — contact found but no photo in user's address book
struct ContactMatchPreview: View {
    @Environment(TransactionStore.self) private var store
    @Environment(ContactsService.self) private var contactsService

    private var p2pCandidates: [Transaction] {
        store.transactions
            .filter { $0.direction == .out && $0.instrument.hasPrefix("account_") }
            .prefix(30)
            .map { $0 }
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()
            List {
                Section {
                    summaryRow
                }
                Section {
                    ForEach(p2pCandidates) { tx in
                        row(for: tx)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } header: {
                    Text("recent outbound P2P")
                        .font(AppFont.sectionLabel)
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("contact matches")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var summaryRow: some View {
        let totals = computeSummary()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("rows scanned")
                Spacer()
                Text("\(totals.scanned)")
                    .foregroundStyle(AppColor.textTertiary)
            }
            HStack {
                Text("matched")
                Spacer()
                Text("\(totals.matched)")
                    .foregroundStyle(totals.matched > 0 ? AppColor.inflow : AppColor.textTertiary)
            }
            HStack {
                Text("of which have photo")
                Spacer()
                Text("\(totals.withPhoto)")
                    .foregroundStyle(totals.withPhoto > 0 ? AppColor.inflow : AppColor.textTertiary)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(AppColor.textPrimary)
    }

    @ViewBuilder
    private func row(for tx: Transaction) -> some View {
        let contact = contactsService.match(for: tx)
        let hasPhoto = contact.map { contactsService.hasCachedPhoto($0) } ?? false

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.merchantRaw)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                if let vpa = tx.vpa {
                    Text(vpa)
                        .font(AppFont.caption.monospaced())
                        .foregroundStyle(AppColor.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let contact {
                    HStack(spacing: 4) {
                        Image(systemName: hasPhoto ? "photo.fill" : "photo")
                            .font(.system(size: 11))
                            .foregroundStyle(hasPhoto ? AppColor.inflow : AppColor.textTertiary)
                        Text(contact.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColor.textPrimary)
                            .lineLimit(1)
                    }
                    Text(hasPhoto ? "matched · photo cached" : "matched · no photo")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                } else {
                    Text("no match")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func computeSummary() -> (scanned: Int, matched: Int, withPhoto: Int) {
        var matched = 0
        var withPhoto = 0
        for tx in p2pCandidates {
            if let contact = contactsService.match(for: tx) {
                matched += 1
                if contactsService.hasCachedPhoto(contact) {
                    withPhoto += 1
                }
            }
        }
        return (scanned: p2pCandidates.count, matched: matched, withPhoto: withPhoto)
    }
}

#Preview {
    NavigationStack {
        ContactMatchPreview()
            .environment(TransactionStore())
            .environment(ContactsService())
    }
}
