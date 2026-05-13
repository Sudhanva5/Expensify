import SwiftUI

/// Compact bottom sheet shown when the user swipes a row → "edit tag", or
/// from any other "change this transaction's category" entry point. Lists
/// the seven V1 categories as tappable rows; selecting one PATCHes the
/// transaction via `APIClient.confirmTransaction(id:overrideCategory:)`
/// and dismisses.
///
/// Picks small enough that .medium detent feels right; the user shouldn't
/// have to scroll a 7-row list.
struct CategoryPickerSheet: View {
    /// Transaction to re-tag. Used for the title hint at the top.
    let transaction: Transaction
    /// Caller-supplied success handler. Receives the chosen category so
    /// the parent can optimistically update its local store before the
    /// network round-trip lands.
    var onPick: (Category) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(TransactionStore.self) private var store

    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().opacity(0.4)
                categoryList
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppFont.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColor.canvas)
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
                Button(action: { Task { await pick(cat) } }) {
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
                .disabled(saving)
            }
        }
    }

    private func pick(_ category: Category) async {
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            try await APIClient.shared.confirmTransaction(
                id: transaction.id,
                overrideCategory: category
            )
            onPick(category)
            await store.refresh()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        CategoryPickerSheet(transaction: mock, onPick: { _ in })
            .environment(TransactionStore())
    }
}
