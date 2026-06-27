import SwiftUI

extension View {
    /// Applies the system **Liquid Glass** material to a custom control
    /// (icon buttons, the filter FAB) so it matches Apple's standard
    /// controls on iOS 26, with a tinted-surface fallback on earlier iOS.
    ///
    /// Use this instead of hand-painting `AppColor` fills behind buttons —
    /// per the project rule to keep controls on standard iOS styling.
    @ViewBuilder
    func glassControl(_ shape: some Shape, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                tint.map { Glass.regular.tint($0).interactive() }
                    ?? Glass.regular.interactive(),
                in: shape
            )
        } else {
            self
                .background(tint ?? AppColor.surface, in: shape)
                .overlay(shape.stroke(AppColor.hairline, lineWidth: 0.5))
        }
    }
}
