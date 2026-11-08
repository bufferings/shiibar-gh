// The icons of the boards on their 16 by 16 grid, copied from the SVG in
// docs/design/. Rows whose kind has no icon on a board use the closest one
// from the boards: Conflicts and Removed from merge queue the × of Checks
// failed, Mergeable and Approved the ✓, Closed the × in the closed colors.

import Foundation

public enum IconElement: Equatable, Sendable {
    case circle(cx: Double, cy: Double, r: Double, dash: [Double]?)
    case rect(x: Double, y: Double, width: Double, height: Double, radius: Double)
    case path(String)
    /// An arc on the circle around (cx, cy), from `start` to `end` degrees,
    /// angles growing clockwise on the board's y-down grid.
    case arc(cx: Double, cy: Double, r: Double, start: Double, end: Double)
}

public struct BoardIcon: Equatable, Sendable {
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
    /// The menu bar glyph of every account and of the shiibar-gh icon while
    /// there is no account: the placeholder of MenuBarIcon.html (a pull
    /// request), tinted with the account color. The final glyph is M5.
    public static let app = BoardIcon(
        [
            .circle(cx: 4, cy: 3.5, r: 1.8, dash: nil), .circle(cx: 4, cy: 12.5, r: 1.8, dash: nil),
            .circle(cx: 12, cy: 8, r: 1.8, dash: nil), .path("M4 5.3v5.4M4 7c0 1.5 2.5 1.5 6.2 1"),
        ],
        lineWidth: 1.5, roundCaps: true
    )
    public static let account = app
    public static let warning = BoardIcon(
        [.path("M8 2l6.5 11.5h-13z"), .path("M8 6.5v3M8 11.6v.1")],
        lineWidth: 1.5, roundJoins: true
    )

    // Popover header (Main.html).
    public static let window = BoardIcon(
        [.rect(x: 2, y: 3, width: 12, height: 10, radius: 1.5), .path("M2 6h12")],
        lineWidth: 1.5, roundJoins: true
    )
    /// The header's Settings button: a gear (Main.html since the owner's
    /// stage 6 review).
    public static let settings = BoardIcon(
        [
            .path("M8.00 1.40 L9.29 1.53 L9.88 3.47 L10.72 3.93 L12.67 3.33 L13.49 4.33 L12.53 6.12 L12.81 7.04 L14.60 8.00 L14.47 9.29 L12.53 9.88 L12.07 10.72 L12.67 12.67 L11.67 13.49 L9.88 12.53 L8.96 12.81 L8.00 14.60 L6.71 14.47 L6.12 12.53 L5.28 12.07 L3.33 12.67 L2.51 11.67 L3.47 9.88 L3.19 8.96 L1.40 8.00 L1.53 6.71 L3.47 6.12 L3.93 5.28 L3.33 3.33 L4.33 2.51 L6.12 3.47 L7.04 3.19Z"),
            .circle(cx: 8, cy: 8, r: 2.2, dash: nil),
        ],
        lineWidth: 1.3, roundJoins: true
    )
    /// The General tab of Settings (Settings.html).
    public static let gear = BoardIcon(
        [.circle(cx: 8, cy: 8, r: 2.2, dash: nil), .path("M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4")],
        lineWidth: 1.5
    )
    /// Refresh (Main.html): `M13.5 8a5.5 5.5 0 1 1-1.6-3.9` is the arc of
    /// the circle of radius 5.5 around (8, 8) from 0° clockwise to 315°,
    /// where (11.9, 4.1) lies, and `M13.5 2.5v3h-3` the arrowhead.
    public static let refresh = BoardIcon(
        [.arc(cx: 8, cy: 8, r: 5.5, start: 0, end: 315), .path("M13.5 2.5v3h-3")],
        lineWidth: 1.5, roundCaps: true
    )
    /// Settings tabs (Settings.html).
    public static let tabGeneral = BoardIcon([.circle(cx: 8, cy: 8, r: 2.2, dash: nil), .circle(cx: 8, cy: 8, r: 6, dash: nil)], lineWidth: 1.3)
    public static let tabAccounts = BoardIcon(
        [.circle(cx: 8, cy: 5.5, r: 3, dash: nil), .path("M2.5 14c.8-3 3-4.5 5.5-4.5s4.7 1.5 5.5 4.5")],
        lineWidth: 1.3, roundCaps: true
    )
    public static let tabWatching = BoardIcon([.circle(cx: 7, cy: 7, r: 4.5, dash: nil), .path("M10.5 10.5l3.5 3.5")], lineWidth: 1.3)
    /// A section header: expanded (down) and collapsed (right).
    public static let sectionOpen = BoardIcon([.path("M4 6l4 4 4-4")], lineWidth: 1.8, roundCaps: true, roundJoins: true)
    public static let sectionClosed = BoardIcon([.path("M6 4l4 4-4 4")], lineWidth: 1.8, roundCaps: true, roundJoins: true)
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

public enum RowIconTone: Equatable { case action, info, ok, merged, closed }

public struct RowIcon: Equatable {
    public var icon: BoardIcon
    public var tone: RowIconTone
}

extension BoardIcons {
    /// The icon tile of a row without a checkbox (`.ico` on the board).
    public static func row(_ kind: Lenient<RowKind>) -> RowIcon {
        switch kind.value {
        case .checksFailed, .changesRequested, .conflicts, .mergeQueueRemoved:
            return RowIcon(icon: rowCross, tone: .action)
        case .mergeable, .approved:
            return RowIcon(icon: rowCheck, tone: .ok)
        case .mergeQueueAdded:
            return RowIcon(icon: mergeQueue, tone: .info)
        case .reaction:
            return RowIcon(icon: reaction, tone: .info)
        case .merged:
            return RowIcon(icon: merged, tone: .merged)
        case .closed:
            return RowIcon(icon: rowCross, tone: .closed)
        case .reviewRequested, .teamReviewRequested, .mentioned, .teamMentioned, .comment, .reply, .replyMentioned, nil:
            return RowIcon(icon: reviewRequest, tone: .info)
        }
    }
}

/// The marks on an account's menu bar icon (DESIGN.md, "Screens";
/// MenuBarIcon.html): the blue dot top right, the Todo PR count bottom
/// right, the triangle bottom left.
public struct MenuBarMarks: Equatable {
    public var number: String?
    public var dot: Bool
    public var triangle: Bool

    public init(count: Int, dot: Bool, triangle: Bool) {
        number = count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
        self.dot = dot
        self.triangle = triangle
    }

    public init(_ account: Account) {
        self.init(count: account.todoCount, dot: account.unread, triangle: Warnings.hasTriangle(account))
    }
}
