import SwiftUI

/// Pushed from Settings → Contacts → "view recent matches". For the last
/// ~30 outbound UPI transactions, shows BOTH match paths the avatar can
/// use AND which one actually supplied the photo on screen:
///
///   • LOCAL  — iPhone CNContactStore match (private; never leaves device)
///   • GOOGLE — backend cache populated via People API (synced contacts)
///   • PHOTO SOURCE — which of the above was used by the avatar (or "—")
///
/// This is the answer to "why does the row show a photo even though
/// the diagnostic says no match?" — usually because LOCAL missed but
/// GOOGLE hit. Lets you reason about the system without guessing.
struct ContactMatchPreview: View {
    @Environment(TransactionStore.self) private var store
    @Environment(ContactsService.self) private var contactsService

    /// Mirrors what `ContactsService.fetchGooglePhotoIfNeeded(for:)`
    /// would cache after iOS scrolls the home list. Re-runs on appear
    /// so the diagnostic stays current; idempotent.
    @State private var googleFetchRan: Bool = false

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
        .task {
            // Fire the Google lookup for every candidate once when the
            // diagnostic opens. Without this, the "GOOGLE" column would
            // show stale state — fetchGooglePhotoIfNeeded is normally
            // triggered by row appearance in the home list, not here.
            // Idempotent + per-VPA debounced inside ContactsService.
            guard !googleFetchRan else { return }
            googleFetchRan = true
            for tx in p2pCandidates {
                await contactsService.fetchGooglePhotoIfNeeded(for: tx)
            }
        }
    }

    @ViewBuilder
    private var summaryRow: some View {
        let totals = computeSummary()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("rows scanned")
                Spacer()
                Text("\(totals.scanned)").foregroundStyle(AppColor.textTertiary)
            }
            HStack {
                Text("local matches")
                Spacer()
                Text("\(totals.localMatched) (\(totals.localWithPhoto) with photo)")
                    .foregroundStyle(totals.localMatched > 0 ? AppColor.inflow : AppColor.textTertiary)
            }
            HStack {
                Text("google matches")
                Spacer()
                Text("\(totals.googleMatched) (\(totals.googleWithPhoto) with photo)")
                    .foregroundStyle(totals.googleMatched > 0 ? AppColor.inflow : AppColor.textTertiary)
            }
            HStack {
                Text("avatar showing photo")
                Spacer()
                Text("\(totals.avatarHasPhoto) of \(totals.scanned)")
                    .foregroundStyle(totals.avatarHasPhoto > 0 ? AppColor.inflow : AppColor.textTertiary)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(AppColor.textPrimary)
    }

    @ViewBuilder
    private func row(for tx: Transaction) -> some View {
        let local = contactsService.match(for: tx)
        let localHasPhoto = local.map { contactsService.hasCachedPhoto($0) } ?? false
        let googleName = tx.vpa.flatMap { contactsService.googleDisplayName(for: $0) }
        let googlePhoto = tx.vpa.flatMap { contactsService.googlePhotoData(for: $0) }
        let avatarPhoto = contactsService.bestPhotoData(for: tx)

        // Which path actually fed the avatar on the home screen?
        let photoSource: String = {
            if let avatarPhoto, let local, contactsService.hasCachedPhoto(local),
               contactsService.imageData(for: local) == avatarPhoto {
                return "local"
            }
            if avatarPhoto != nil && googlePhoto != nil { return "google" }
            if avatarPhoto != nil { return "local" }
            return "—"
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
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
                Text("photo: \(photoSource)")
                    .font(AppFont.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        photoSource == "—"
                            ? AppColor.avatarFill
                            : AppColor.inflow.opacity(0.18)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(photoSource == "—" ? AppColor.textTertiary : AppColor.textPrimary)
            }
            HStack(spacing: 6) {
                pathBadge(
                    label: "LOCAL",
                    name: local?.displayName,
                    hasPhoto: localHasPhoto
                )
                pathBadge(
                    label: "GOOGLE",
                    name: googleName,
                    hasPhoto: googlePhoto != nil
                )
            }
        }
        .padding(.vertical, 4)
    }

    /// Compact "PATH · name · 📷" badge so the user can see at a glance
    /// which of the two match paths fired for this row.
    @ViewBuilder
    private func pathBadge(label: String, name: String?, hasPhoto: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold).monospaced())
                .foregroundStyle(AppColor.textTertiary)
            if let name {
                Image(systemName: hasPhoto ? "photo.fill" : "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(hasPhoto ? AppColor.inflow : AppColor.textTertiary)
                Text(name)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
            } else {
                Text("no match")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppColor.avatarFill)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func computeSummary() -> (
        scanned: Int,
        localMatched: Int,
        localWithPhoto: Int,
        googleMatched: Int,
        googleWithPhoto: Int,
        avatarHasPhoto: Int
    ) {
        var localMatched = 0
        var localWithPhoto = 0
        var googleMatched = 0
        var googleWithPhoto = 0
        var avatarHasPhoto = 0
        for tx in p2pCandidates {
            if let contact = contactsService.match(for: tx) {
                localMatched += 1
                if contactsService.hasCachedPhoto(contact) { localWithPhoto += 1 }
            }
            if let vpa = tx.vpa {
                if contactsService.googleDisplayName(for: vpa) != nil {
                    googleMatched += 1
                    if contactsService.googlePhotoData(for: vpa) != nil { googleWithPhoto += 1 }
                }
            }
            if contactsService.bestPhotoData(for: tx) != nil { avatarHasPhoto += 1 }
        }
        return (
            scanned: p2pCandidates.count,
            localMatched: localMatched,
            localWithPhoto: localWithPhoto,
            googleMatched: googleMatched,
            googleWithPhoto: googleWithPhoto,
            avatarHasPhoto: avatarHasPhoto
        )
    }
}

#Preview {
    NavigationStack {
        ContactMatchPreview()
            .environment(TransactionStore())
            .environment(ContactsService())
    }
}
