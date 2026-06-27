import SwiftUI

/// Bottom-sheet notes editor presented over `CategoryPickerSheet` when the
/// user taps the "notes" row. Single multi-line TextEditor with a save +
/// cancel toolbar. Saves through the same `APIClient.updateNotes` path the
/// detail sheet used to use — backend trims, empty → null.
///
/// Returns to the parent sheet on dismiss (the picker stays open underneath).
/// Cancel = discard draft; Save = PATCH and dismiss this sheet only.
struct NotesEditorSheet: View {
    let transaction: Transaction

    @Environment(\.dismiss) private var dismiss
    @Environment(TransactionStore.self) private var store

    @State private var draft: String = ""
    @State private var saving: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var originalTrimmed: String {
        (transaction.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedDraft != originalTrimmed
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColor.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Tiny merchant label so the user has anchor context
                        // when the keyboard pops up over the row that was
                        // tapped from. Caps at one line.
                        Text(transaction.displayMerchant)
                            .font(.system(size: 13))
                            .foregroundStyle(AppColor.textTertiary)
                            .lineLimit(1)

                        ZStack(alignment: .topLeading) {
                            if draft.isEmpty && !focused {
                                Text("e.g. 'ETF rebalance — keep for taxes' or 'paid Anita back for dinner'")
                                    .font(.system(size: 15))
                                    .foregroundStyle(AppColor.textTertiary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $draft)
                                .focused($focused)
                                .font(.system(size: 15))
                                .foregroundStyle(AppColor.textPrimary)
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(minHeight: 160, maxHeight: 320)
                        }
                        .background(AppColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppColor.hairline, lineWidth: 0.5)
                        )

                        if let errorMessage {
                            Text(errorMessage)
                                .font(AppFont.caption)
                                .foregroundStyle(.red)
                        }

                        Text("Private to you. Surfaced to Claude via MCP so spend questions can reference what you wrote here.")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(saving)
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .disabled(saving || !hasChanges)
                    .accessibilityLabel("Save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColor.canvas)
        .task {
            draft = transaction.notes ?? ""
            // Pop the keyboard immediately so the user can start typing
            // without an extra tap.
            try? await Task.sleep(nanoseconds: 100_000_000)
            focused = true
        }
    }

    private func save() async {
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            try await APIClient.shared.updateNotes(
                transactionId: transaction.id,
                notes: trimmedDraft
            )
            // Refresh the store so the parent sheet (and the row behind
            // it) re-render with the new notes value next time.
            await store.refresh()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
