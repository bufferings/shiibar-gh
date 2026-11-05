// The icons of the boards on their 16 by 16 grid, copied from the SVG in
// docs/design/. Rows whose kind has no icon on a board use the closest one
// from the boards: Conflicts and Removed from merge queue the × of Checks
// failed, Mergeable the ✓, Closed the × in the closed colors, and a Review
// requested row that is no longer to do the dashed circle.

import Foundation

public enum IconElement: Equatable {
    case circle(cx: Double, cy: Double, r: Double, dash: [Double]?)
    case rect(x: Double, y: Double, width: Double, height: Double, radius: Double)
    case path(String)
}

public struct BoardIcon: Equatable {
    public var elements: [IconElement]
    public var lineWidth: Double
    /// Round line caps.
    public var roundCaps: Bool
    public var roundJoins: Bool

    public init(_ elements: [IconElement], lineWidth: Double, roundCaps: Bool = false, roundJoins: Bool = false) {
        self.elements = elements
        self.lineWidth = lineWidth
        self.roundCaps = roundCaps
        self.roundJoins = roundJoins
    }
}

public enum BoardIcons {
    // Menu bar (MenuBarIcon.html).
    public static let organization = BoardIcon(
        [.path("M2.5 13.5V5l5.5-2.5L13.5 5v8.5z"), .path("M6 13.5V9h4v4.5")],
        lineWidth: 1.5, roundJoins: true
    )
    public static let person = BoardIcon(
        [.circle(cx: 8, cy: 5.5, r: 3, dash: nil), .path("M2.5 14c.8-3 3-4.5 5.5-4.5s4.7 1.5 5.5 4.5")],
        lineWidth: 1.5, roundCaps: true
    )
    public static let globe = BoardIcon(
        [.circle(cx: 8, cy: 8, r: 6.5, dash: nil), .path("M1.5 8h13M8 1.5c2.2 2 2.2 11 0 13M8 1.5c-2.2 2-2.2 11 0 13")],
        lineWidth: 1.5
    )
    /// The menu bar icon while no scope icon shows: the Merged glyph of the
    /// rows, a pull request, so it is not mistaken for a scope.
    public static let app = BoardIcon(
        [
            .circle(cx: 4, cy: 3.5, r: 1.8, dash: nil), .circle(cx: 4, cy: 12.5, r: 1.8, dash: nil),
            .circle(cx: 12, cy: 8, r: 1.8, dash: nil), .path("M4 5.3v5.4M4 7c0 1.5 2.5 1.5 6.2 1"),
        ],
        lineWidth: 1.5, roundCaps: true
    )
    public static let warning = BoardIcon(
        [.path("M8 2l6.5 11.5h-13z"), .path("M8 6.5v3M8 11.6v.1")],
        lineWidth: 1.5, roundJoins: true
    )

    // Popover header (Main.html).
    public static let window = BoardIcon(
        [.rect(x: 2, y: 3, width: 12, height: 10, radius: 1.5), .path("M2 6h12")],
        lineWidth: 1.5, roundJoins: true
    )
    public static let gear = BoardIcon(
        [.circle(cx: 8, cy: 8, r: 2.2, dash: nil), .path("M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4")],
        lineWidth: 1.5
    )
    public static let chevron = BoardIcon([.path("M4 6l4 4 4-4")], lineWidth: 1.5, roundCaps: true, roundJoins: true)
    public static let clock = BoardIcon(
        [.circle(cx: 8, cy: 8, r: 6, dash: nil), .path("M8 4.5V8l2.5 1.5")],
        lineWidth: 1.6, roundCaps: true
    )

    // Status icons: drawn filled by the app, with a white mark.
    public static let checkMark = BoardIcon([.path("M4.8 8.3l2.2 2.2 4.4-4.8")], lineWidth: 1.9, roundCaps: true, roundJoins: true)
    public static let crossMark = BoardIcon([.path("M5.5 5.5l5 5M10.5 5.5l-5 5")], lineWidth: 1.9, roundCaps: true)
    public static let dashedCircle = BoardIcon([.circle(cx: 8, cy: 8, r: 6.5, dash: [2.5, 2.2])], lineWidth: 1.6, roundCaps: true)

    // Row icons, 11 points in an 18 point tile.
    public static let rowCross = BoardIcon([.path("M4.5 4.5l7 7M11.5 4.5l-7 7")], lineWidth: 1.8, roundCaps: true)
    public static let rowCheck = BoardIcon([.path("M3.5 8.5l3 3 6-7")], lineWidth: 1.8, roundCaps: true, roundJoins: true)
    public static let bot = BoardIcon(
        [.rect(x: 3, y: 5, width: 10, height: 8, radius: 2), .path("M8 2.5V5M6 9h.1M10 9h.1")],
        lineWidth: 1.6
    )
    public static let mergeQueue = BoardIcon([.path("M3 4h10M3 8h6M3 12h4M12 8v5M10 11l2 2 2-2")], lineWidth: 1.6, roundCaps: true)
    public static let reaction = BoardIcon(
        [.circle(cx: 8, cy: 8, r: 6, dash: nil), .path("M5.5 9.5s1 1.5 2.5 1.5 2.5-1.5 2.5-1.5M6 6.3h.1M10 6.3h.1")],
        lineWidth: 1.6, roundCaps: true
    )
    public static let merged = BoardIcon(
        [
            .circle(cx: 4, cy: 3.5, r: 1.8, dash: nil), .circle(cx: 4, cy: 12.5, r: 1.8, dash: nil),
            .circle(cx: 12, cy: 8, r: 1.8, dash: nil), .path("M4 5.3v5.4M4 7c0 1.5 2.5 1.5 6.2 1"),
        ],
        lineWidth: 1.6, roundCaps: true
    )
    public static let reviewRequest = BoardIcon([.circle(cx: 8, cy: 8, r: 5.5, dash: [2.2, 1.9])], lineWidth: 1.6, roundCaps: true)
    /// The Done checkbox mark.
    public static let checkbox = BoardIcon([.path("M3.5 8.5l3 3 6-7")], lineWidth: 2.2, roundCaps: true, roundJoins: true)
}

public enum RowIconTone: Equatable { case action, info, ok, bot, merged, closed }

public struct RowIcon: Equatable {
    public var icon: BoardIcon
    public var tone: RowIconTone
}

extension BoardIcons {
    /// The icon tile of an event row (`.ico` on the board).
    public static func row(_ kind: Lenient<RowKind>) -> RowIcon {
        switch kind.value {
        case .checksFailed, .changesRequested, .conflicts, .removedFromMergeQueue:
            return RowIcon(icon: rowCross, tone: .action)
        case .mergeable:
            return RowIcon(icon: rowCheck, tone: .ok)
        case .botComment:
            return RowIcon(icon: bot, tone: .bot)
        case .addedToMergeQueue:
            return RowIcon(icon: mergeQueue, tone: .info)
        case .reaction:
            return RowIcon(icon: reaction, tone: .info)
        case .merged:
            return RowIcon(icon: merged, tone: .merged)
        case .closed:
            return RowIcon(icon: rowCross, tone: .closed)
        case .reviewRequested, .mentioned, .comment, .reply, .none:
            return RowIcon(icon: reviewRequest, tone: .info)
        }
    }

    /// The menu bar icon of a scope: its owner's type, the person while the
    /// type is not fetched yet (docs/tasks/M3.md, "Menu bar and popover").
    public static func scope(_ scope: Scope) -> BoardIcon {
        if scope.isPublic { return globe }
        return scope.kind?.value == .org ? organization : person
    }
}
