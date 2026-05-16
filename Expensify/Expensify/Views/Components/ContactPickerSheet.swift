import SwiftUI
import ContactsUI
import Contacts

/// SwiftUI wrapper around iOS's native `CNContactPickerViewController`.
///
/// Used by CategoryPickerSheet to let the user pin a transaction's VPA
/// to a specific iPhone contact — the manual override for cases the
/// strict token matcher legitimately rejects (e.g. bank says "SAGAR
/// PRABHU" but the contact is saved as "Sagar Nitte").
///
/// Returns the picked CNContact via `onPick`. The host view dismisses
/// itself; this wrapper doesn't manage presentation state.
struct ContactPickerSheet: UIViewControllerRepresentable {
    var onPick: (CNContact) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Keep the keys minimal — the caller only needs identifier +
        // names + (optionally) photo availability. Pulling phone numbers
        // and images here would be wasteful since we already have a
        // hydrated cache in ContactsService.
        picker.displayedPropertyKeys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
        ]
        return picker
    }

    func updateUIViewController(_: CNContactPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPickerSheet
        init(_ parent: ContactPickerSheet) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            parent.onPick(contact)
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}
