import SwiftUI
import PhotosUI

/// Settings sheet — presented from the avatar in any tab's nav bar.
/// Standard iOS: inset-grouped list, system colors (no app theme tokens),
/// large navigation title.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BudgetStore.self) private var budgetStore
    @Environment(ProfilePhotoStore.self) private var profilePhotoStore

    /// Bound to the profile-photo PhotosPicker; loaded + persisted on change.
    @State private var photoPickerItem: PhotosPickerItem?

    /// Theme preference, persisted by ExpensifyApp's @AppStorage. We
    /// bind to the same key here so the picker change instantly
    /// re-renders the root view via preferredColorScheme.
    @AppStorage(ThemePreference.storageKey) private var themeRaw: String =
        ThemePreference.system.rawValue

    /// One row per category. Categories without a backend budget get a
    /// placeholder "not set" Budget so the user can tap in and create one.
    private var allBudgetRows: [Budget] {
        Category.allCases.map { budgetStore.budget(for: $0) }
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                appearanceSection
                budgetsSection
                rulesSection
                diagnosticsSection
                accountSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var profileSection: some View {
        Section {
            HStack(spacing: 12) {
                // Tap the avatar to pick a photo; long-press handled by the
                // Remove button below when one is set.
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Group {
                        if let img = profilePhotoStore.image {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Text(CurrentUser.initials)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .background(Color(.secondarySystemFill))
                    .clipShape(Circle())
                    .overlay(alignment: .bottomTrailing) {
                        // Small camera badge to signal it's editable.
                        Image(systemName: "camera.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 18, height: 18)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(CurrentUser.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text(CurrentUser.email)
                        .font(AppFont.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                if profilePhotoStore.hasPhoto {
                    Button(role: .destructive) {
                        profilePhotoStore.clear()
                    } label: {
                        Text("Remove")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    profilePhotoStore.save(data)
                }
                photoPickerItem = nil
            }
        }
    }

    /// Light/Dark/System override. Default `.system` follows the
    /// device's appearance setting; the other two force the app
    /// independent of the OS. Persisted via @AppStorage and applied
    /// at the root view in ExpensifyApp.
    private var appearanceSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: appearanceIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 24, height: 24)
                    .background(Color(.secondarySystemFill))
                    .clipShape(Circle())
                Text("Theme")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary)
                Spacer()
                Picker("", selection: $themeRaw) {
                    ForEach(ThemePreference.allCases) { pref in
                        Text(pref.label).tag(pref.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.accentColor)
            }
        } header: {
            Text("Appearance")
                .font(AppFont.sectionLabel)
                .foregroundStyle(Color.secondary)
        } footer: {
            Text("'System' follows your iPhone's light/dark setting. Choose Light or Dark to override.")
                .font(AppFont.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    /// SF Symbol that mirrors the active selection — empty circle (system),
    /// sun (light), or moon (dark).
    private var appearanceIcon: String {
        switch ThemePreference(rawValue: themeRaw) ?? .system {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// Single navigation link to the diagnostics screen. Everything that
    /// used to live as separate rows (connection check, test push, reload
    /// contacts, sync google contacts, view recent matches) moved into
    /// DiagnosticsView so Settings stays focused on user-visible config.
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 24, height: 24)
                        .background(Color(.secondarySystemFill))
                        .clipShape(Circle())
                    Text("Diagnostics")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary)
                }
            }
        } header: {
            Text("System")
                .font(AppFont.sectionLabel)
                .foregroundStyle(Color.secondary)
        } footer: {
            Text("Connection check, test push preview, contact match diagnostics.")
                .font(AppFont.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var budgetsSection: some View {
        Section {
            ForEach(allBudgetRows) { budget in
                NavigationLink {
                    BudgetEditView(initial: budget)
                } label: {
                    BudgetSummaryRow(budget: budget)
                }
            }
        } header: {
            Text("Budgets")
                .font(AppFont.sectionLabel)
                .foregroundStyle(Color.secondary)
        } footer: {
            Text("Set a monthly limit per category. We'll notify you as you approach or cross it.")
                .font(AppFont.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    /// Contextual auto-tagging rules. The "create rule from this
    /// transaction" wizard creates these inline from the category
    /// picker; this row is the management surface — list/disable/delete.
    private var rulesSection: some View {
        Section {
            NavigationLink {
                ManageRulesView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 24, height: 24)
                        .background(Color(.secondarySystemFill))
                        .clipShape(Circle())
                    Text("Manage Rules")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary)
                }
            }
        } header: {
            Text("Rules")
                .font(AppFont.sectionLabel)
                .foregroundStyle(Color.secondary)
        } footer: {
            Text("Rules auto-tag transactions matching contextual patterns — amount range, time of day, distance from a saved location. Create them from any category picker.")
                .font(AppFont.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var accountSection: some View {
        Section {
            Button(role: .destructive) { } label: {
                Text("Sign Out")
            }
        } header: {
            Text("Account")
                .font(AppFont.sectionLabel)
                .foregroundStyle(Color.secondary)
        }
    }
}

private struct BudgetSummaryRow: View {
    let budget: Budget

    var body: some View {
        HStack(spacing: 12) {
            // Custom category illustration (falls back to its SF Symbol).
            Group {
                if let asset = budget.category.spendImageName {
                    Image(asset).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: budget.category.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            }
            .frame(width: 30, height: 30)
            .background(Color(.secondarySystemFill))
            .clipShape(Circle())

            Text(budget.category.shortName)
                .font(.system(size: 15))
                .foregroundStyle(Color.primary)

            Spacer()

            Text(limitString)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(budget.isSet ? Color.primary : Color.secondary)
        }
    }

    private var limitString: String {
        guard let amount = budget.monthlyLimitInr else { return "not set" }
        let value = NSDecimalNumber(decimal: amount).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "₹\(f.string(from: NSNumber(value: value)) ?? String(value))"
    }
}

#Preview {
    SettingsView()
        .environment(BudgetStore())
        .environment(ContactsService())
        .environment(ProfilePhotoStore())
}
