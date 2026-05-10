import SwiftUI

/// Shown after the user has swiped through every card. Each item that was
/// swiped LEFT (needs tag) appears here with a Picker. Hitting "Update Changes"
/// applies all the chosen categories at once.
struct TaggingListView: View {
    @Binding var pending: [PendingTag]
    let onUpdate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ForEach($pending) { $tag in
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(amountString(tag.transaction))
                                    .font(.title3.weight(.semibold))
                                Text(tag.transaction.displayMerchant)
                                    .font(.subheadline)
                                Text(timeString(tag.transaction))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Picker("Category", selection: $tag.chosenCategory) {
                                ForEach(Category.allCases) { c in
                                    Label(c.shortName, systemImage: c.symbolName).tag(c)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.insetGrouped)

                // Sticky bottom CTA
                VStack(spacing: 0) {
                    Divider()
                    Button(action: onUpdate) {
                        Text("Update Changes")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(16)
                }
                .background(.bar)
            }
            .navigationTitle("Tag \(pending.count) item\(pending.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private func amountString(_ tx: Transaction) -> String {
        let value = NSDecimalNumber(decimal: tx.amountInr).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = (value.truncatingRemainder(dividingBy: 1) == 0) ? 0 : 2
        return "₹\(f.string(from: NSNumber(value: value)) ?? String(value))"
    }

    private func timeString(_ tx: Transaction) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE, d MMM · h:mm a"
        return df.string(from: tx.occurredAt)
    }
}

#Preview {
    @Previewable @State var pending: [PendingTag] =
        MockData.reviewItems.map { PendingTag(item: $0) }
    return TaggingListView(
        pending: $pending,
        onUpdate: { print("update") },
        onCancel: { print("cancel") }
    )
}
