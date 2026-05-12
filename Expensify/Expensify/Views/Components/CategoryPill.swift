import SwiftUI

/// Small category tag pill. Used in transaction rows under the merchant name.
struct CategoryPill: View {
    let category: Category
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: category.symbolName)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(category.shortName)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
        }
        .foregroundStyle(category.tint)
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(category.tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        CategoryPill(category: .food)
        CategoryPill(category: .travel)
        CategoryPill(category: .groceries, compact: true)
        CategoryPill(category: .personalTransfer)
        CategoryPill(category: .subscriptions)
    }
    .padding()
}
