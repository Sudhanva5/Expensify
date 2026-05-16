import SwiftUI

/// Settings → Rules. Lists every user-authored rule.
///
/// Per-row interactions:
///   • Tap                → edit the rule (RuleEditorSheet pre-filled)
///   • Toggle             → enable/disable without leaving the list
///   • Swipe-to-delete    → remove
///   • Toolbar "+"        → create a new rule from scratch
struct ManageRulesView: View {
    @State private var rules: [UserRule] = []
    @State private var loadState: LoadState = .idle
    @State private var loadError: String?
    @State private var showEditor: Bool = false
    /// When non-nil, presents RuleEditorSheet pre-filled with this rule.
    /// Lives separately from `showEditor` (which is the new-rule path)
    /// so the same sheet API can serve both flows without a state-machine
    /// collision.
    @State private var editingRule: UserRule?

    enum LoadState { case idle, loading, loaded }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            if loadState == .loading && rules.isEmpty {
                ProgressView().controlSize(.small)
            } else if rules.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(rules) { rule in
                        Button {
                            editingRule = rule
                        } label: {
                            RuleRow(
                                rule: rule,
                                onToggle: { isOn in Task { await toggle(rule, on: isOn) } }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteAt)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppColor.canvas)
            }
        }
        .navigationTitle("rules")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if loadState == .loading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        showEditor = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColor.textPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            RuleEditorSheet(onSaved: {
                Task { await load() }
            })
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(
                editing: rule,
                onSaved: {
                    Task { await load() }
                }
            )
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28))
                .foregroundStyle(AppColor.textTertiary)
            Text("no rules yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
            Text("tap '+' to create a contextual rule — e.g. ₹100-500 near your office on weekdays → Travel.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let err = loadError {
                Text(err)
                    .font(AppFont.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
    }

    private func load() async {
        loadState = .loading
        loadError = nil
        do {
            rules = try await APIClient.shared.fetchRules()
        } catch {
            loadError = error.localizedDescription
        }
        loadState = .loaded
    }

    private func toggle(_ rule: UserRule, on: Bool) async {
        // Optimistic flip; revert on failure so the toggle doesn't drift
        // away from the server state.
        if let idx = rules.firstIndex(of: rule) {
            rules[idx].enabled = on
        }
        do {
            try await APIClient.shared.setRuleEnabled(id: rule.id, enabled: on)
        } catch {
            if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[idx].enabled = !on
            }
            loadError = error.localizedDescription
        }
    }

    private func deleteAt(_ offsets: IndexSet) {
        let targets = offsets.map { rules[$0] }
        rules.remove(atOffsets: offsets)
        Task {
            for r in targets {
                do { try await APIClient.shared.deleteRule(id: r.id) } catch {
                    loadError = error.localizedDescription
                    await load()
                    return
                }
            }
        }
    }
}

private struct RuleRow: View {
    let rule: UserRule
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: rule.category.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: 24, height: 24)
                    .background(AppColor.avatarFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(1)
                    Text("→ \(rule.category.shortName)")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
            }

            Text(rule.conditions.summary)
                .font(AppFont.caption.monospacedDigit())
                .foregroundStyle(AppColor.textTertiary)
                .lineLimit(2)

            if rule.hitCount > 0 {
                Text("fired \(rule.hitCount) time\(rule.hitCount == 1 ? "" : "s")")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
