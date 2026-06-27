import SwiftUI
import UIKit

/// User's profile photo for the nav-bar avatar.
///
/// iOS exposes no public API for the "Me" contact card or the Contact
/// Poster, so we can't auto-fetch the user's poster image. Instead the
/// user picks a photo (Settings → profile) which we downscale and persist
/// on-device as a small JPEG. Read everywhere the avatar renders; falls
/// back to initials when unset. Nothing ever leaves the device.
@Observable
final class ProfilePhotoStore {
    /// Current avatar image, or nil when the user hasn't set one.
    private(set) var image: UIImage?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("profile-avatar.jpg")
    }

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        image = UIImage(data: data)
    }

    /// Downscale the picked image to avatar size and persist it.
    /// Raw library images are multi-MB; an avatar only needs ~256px.
    func save(_ data: Data) {
        guard let picked = UIImage(data: data) else { return }
        let resized = picked.downscaled(maxDimension: 256)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
        try? jpeg.write(to: fileURL, options: .atomic)
        image = UIImage(data: jpeg)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        image = nil
    }

    var hasPhoto: Bool { image != nil }
}

private extension UIImage {
    /// Aspect-fit downscale so the longest side is `maxDimension` points.
    /// Returns self unchanged if it's already small enough.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // newSize is already in pixels we want
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
