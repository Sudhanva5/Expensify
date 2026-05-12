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

    private var faviconURL: URL? {
        MerchantBranding.faviconURL(for: merchantName, size: 128)
    }

    private var initials: String {
        MerchantBranding.initials(for: merchantName)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppColor.avatarFill)
                .frame(width: size, height: size)

            if let url = faviconURL {
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
                        initialsView
                    @unknown default:
                        initialsView
                    }
                }
            } else {
                initialsView
            }
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
