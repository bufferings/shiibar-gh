// The boards' icons and colors in AppKit and SwiftUI.

import AppKit
import ShiibarGhCore
import SwiftUI

/// The status icons: a filled ✓ or ×, or the dashed circle (DESIGN.md, "The
/// three status icons").
struct StatusIcon: View {
    enum Look { case ok, bad, waiting, empty }
    var look: Look

    var body: some View {
        ZStack {
            switch look {
            case .ok:
                Circle().fill(Palette.green.color).frame(width: 12.25, height: 12.25)
                IconView(icon: BoardIcons.checkMark, size: 14, color: Palette.onColor.color)
            case .bad:
                Circle().fill(Palette.badge.color).frame(width: 12.25, height: 12.25)
                IconView(icon: BoardIcons.crossMark, size: 14, color: Palette.onColor.color)
            case .waiting:
                IconView(icon: BoardIcons.dashedCircle, size: 14, color: Palette.waiting.color)
            case .empty:
                Color.clear
            }
        }
        .frame(width: 14, height: 14)
    }
}

