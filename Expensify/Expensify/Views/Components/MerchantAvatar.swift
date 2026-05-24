import SwiftUI

/// Circular merchant avatar.
///   • If we recognize the merchant → render a Google favicon
///   • Otherwise → two-letter initials on a warm-tinted circle
///
/// AsyncImage handles loading + caching automatically. While the favicon
/// loads (or if it fails), we show the initials placeholder so the row
/// is never blank.
struct MerchantAvatar: View {
    let merchantName: String
    var size: CGFloat = 44
    /// Stable identifier used for favicon lookup, independent of the
    /// renameable display name. When the user renames a row's title,
    /// the favicon should still resolve from the bank's underlying
    /// merchant text or VPA — the brand identity is fixed at the bank
    /// side, the title is just the user's preferred label. Pass
    /// `merchantRaw` or the VPA here. When nil, falls back to
    /// `merchantName` (preserves preview / one-arg call sites).
    var brandKey: String? = nil
    /// Optional contact photo data. When supplied, takes priority over
    /// favicons + initials — the user's friend's actual DP fills the
    /// circle. Sourced from `ContactsService.imageData(for:)`.
    var contactImageData: Data? = nil
    /// Optional contact display name. When supplied AND no photo is
    /// available, initials are derived from THIS name instead of
    /// `merchantName`, so a row that visually says "Sneha Appa" doesn't
    /// show the avatar initials "SR" from the underlying merchantRaw.
    var contactName: String? = nil
    /// Optional category fallback. When supplied AND there's no contact
    /// photo and no recognized favicon, the category's SF Symbol fills
    /// the circle instead of plain initials. More informative for rows
    /// where we don't have a brand mark (Places-resolved restaurants,
    /// random kirana stores) — the user immediately sees a fork-and-knife
    /// for food, a basket for groceries, etc.
    var categoryFallback: Category? = nil

    private var faviconURL: URL? {
        // When a contact name is supplied, the avatar is representing a
        // person, not a merchant — no favicon lookup.
        if let contactName, !contactName.isEmpty { return nil }
        // Resolve from the stable brand key (bank's merchantRaw / VPA),
        // NOT the renameable display name. The user may have flipped
        // the row title to "Manju Tea Stall" but the bank text is still
        // "PAYTMQR6FGL36" — favicon should track that underlying signal.
        let key = brandKey?.isEmpty == false ? brandKey! : merchantName
        return MerchantBranding.faviconURL(for: key, size: 128)
    }

    private var initials: String {
        if let contactName, !contactName.isEmpty {
            return MerchantBranding.initials(for: contactName)
        }
        return MerchantBranding.initials(for: merchantName)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppColor.avatarFill)
                .frame(width: size, height: size)

            if let contactImageData,
               let uiImage = UIImage(data: contactImageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if let url = faviconURL {
                AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size * 0.58, height: size * 0.58)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    case .failure, .empty:
                        fallbackView
                    @unknown default:
                        fallbackView
                    }
                }
            } else {
                fallbackView
            }
        }
    }

    /// What to render when neither a contact photo nor a favicon is
    /// available. Prefers the category icon (more informative) over
    /// initials when a categoryFallback was supplied.
    @ViewBuilder
    private var fallbackView: some View {
        if let categoryFallback {
            Image(systemName: categoryFallback.symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary.opacity(0.78))
        } else {
            initialsView
        }
    }

    private var initialsView: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
            .foregroundStyle(AppColor.textPrimary.opacity(0.75))
    }
}

#Preview {
    VStack(spacing: 12) {
        HStack(spacing: 12) {
            MerchantAvatar(merchantName: "Swiggy")
            MerchantAvatar(merchantName: "Anthropic")
            MerchantAvatar(merchantName: "Netflix")
            MerchantAvatar(merchantName: "Zomato")
        }
        HStack(spacing: 12) {
            MerchantAvatar(merchantName: "SNEHA R")
            MerchantAvatar(merchantName: "BIVEK DEB")
            MerchantAvatar(merchantName: "Sri Guru Raghavendra Enterprises")
            MerchantAvatar(merchantName: "RAJESH KUMAR")
        }
    }
    .padding()
}
