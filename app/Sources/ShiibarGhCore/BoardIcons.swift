// The icons of the boards on their 16 by 16 grid, copied from the SVG in
// docs/design/. Rows whose kind has no icon on a board use the closest one
// from the boards: Conflicts and Removed from merge queue the × of Checks
// failed, Mergeable the ✓.

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
    /// The Dismissed tab of Settings and the Dismissed button of the tab row
    /// (Settings.html, Main.html `.dbtn`): a box.
    public static let dismissedBox = BoardIcon(
        [.rect(x: 1.8, y: 2.8, width: 12.4, height: 3.2, radius: 1), .path("M3 6v7h10V6M6.5 8.8h3")],
        lineWidth: 1.4, roundCaps: true, roundJoins: true
    )
    /// A section header: expanded (down) and collapsed (right).
    public static let sectionOpen = BoardIcon([.path("M4 6l4 4 4-4")], lineWidth: 1.8, roundCaps: true, roundJoins: true)
    public static let sectionClosed = BoardIcon([.path("M6 4l4 4-4 4")], lineWidth: 1.8, roundCaps: true, roundJoins: true)
    public static let chevron = BoardIcon([.path("M4 6l4 4 4-4")], lineWidth: 1.5, roundCaps: true, roundJoins: true)
    /// The operation failure band (Main.html `.fail`).
    public static let failure = BoardIcon(
        [.circle(cx: 8, cy: 8, r: 6.5, dash: nil), .path("M8 4.5v4.2M8 11.2v.1")], lineWidth: 1.5, roundCaps: true
    )
    /// The quarter arc of Refresh in progress (Main.html `.iconbtn.busy`),
    /// drawn over a gray circle.
    public static let progressArc = BoardIcon([.arc(cx: 8, cy: 8, r: 5.5, start: -90, end: 0)], lineWidth: 2, roundCaps: true)
    public static let progressTrack = BoardIcon([.circle(cx: 8, cy: 8, r: 5.5, dash: nil)], lineWidth: 2)

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

    // Row kind icons of Main.html (`.ki`, 14 points, no tile). The mention's two arcs are `.arc` elements: `a1.5 1.5 0 0 0 3 0`
    // from (11, 9.5) is the lower half of the circle around (12.5, 9.5), and
    // `a6 6 0 1 0-2.3 4.7` from (14, 8) the large arc of the circle around
    // (8, 8) through the top to (11.7, 12.7), at 51.8°.
    public static let kindReviewRequest = BoardIcon(
        [.circle(cx: 6, cy: 5, r: 2.5, dash: nil), .path("M1.5 13c0-2.5 2-4 4.5-4s4.5 1.5 4.5 4M10.5 6.5h4M12.5 4.5l2 2-2 2")],
        lineWidth: 1.4, roundCaps: true, roundJoins: true
    )
    public static let kindMention = BoardIcon(
        [
            .circle(cx: 8, cy: 8, r: 3, dash: nil), .path("M11 8v1.5"),
            .arc(cx: 12.5, cy: 9.5, r: 1.5, start: 180, end: 0), .path("M14 9.5V8"),
            .arc(cx: 8, cy: 8, r: 6, start: 0, end: -308.2),
        ],
        lineWidth: 1.4, roundCaps: true
    )
    public static let kindComment = BoardIcon([.path("M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z")], lineWidth: 1.4, roundJoins: true)
    public static let kindChangesRequested = BoardIcon(
        [.circle(cx: 8, cy: 8, r: 6.5, dash: nil), .path("M5.5 5.5l5 5M10.5 5.5l-5 5")],
        lineWidth: 1.4, roundCaps: true
    )
    public static let kindMerged = BoardIcon([.path("M3 8h10M9 4l4 4-4 4")], lineWidth: 1.4, roundCaps: true, roundJoins: true)
    /// Approved and Checks passed: a ✓ in a circle.
    public static let kindPassed = BoardIcon(
        [.circle(cx: 8, cy: 8, r: 6.5, dash: nil), .path("M5 8.3l2 2 4-4.3")], lineWidth: 1.4, roundCaps: true, roundJoins: true
    )
    /// Reopened: `M3.2 9.5A5 5 0 1 0 4.6 4.4` is the large arc of the circle
    /// of radius 5 around (8, 8) from (3.2, 9.5), at 162.6°, with the angle
    /// falling (sweep flag 0) through the bottom, the right and the top to
    /// (4.6, 4.4), at -133.4°; and `M3.5 1.8v3h3` the arrowhead.
    public static let kindReopened = BoardIcon(
        [.arc(cx: 8, cy: 8, r: 5, start: 162.6, end: -133.4), .path("M3.5 1.8v3h3")],
        lineWidth: 1.4, roundCaps: true, roundJoins: true
    )

    /// Keep on top (Main.html `.pin`): filled while on, outlined while off.
    public static let pin = BoardIcon(
        [.path("M9.5 1.5l5 5-1.4 1.4-.7-.7-3 3 .4 2.6-1.2 1.2L5.7 11 2.5 14.2 1.3 13l3.2-3.2L1.6 6.9l1.2-1.2 2.6.4 3-3-.7-.7z")],
        lineWidth: 1.2, roundJoins: true
    )
    /// The open icon of card headers and rows (Main.html `.op`).
    public static let open = BoardIcon(
        [.path("M9 2.5h4.5V7M13.5 2.5L7.5 8.5M11.5 9.5v4h-9v-9h4")], lineWidth: 1.6, roundCaps: true, roundJoins: true
    )
    /// The × that dismisses a card (Main.html `.iz`).
    public static let dismiss = BoardIcon([.path("M4.5 4.5l7 7M11.5 4.5l-7 7")], lineWidth: 1.7, roundCaps: true)
    /// The search field's magnifier (Main.html `.search`).
    public static let search = BoardIcon([.circle(cx: 7, cy: 7, r: 4.5, dash: nil), .path("M10.5 10.5L14 14")], lineWidth: 1.6, roundCaps: true)
}

extension BoardIcons {
    /// The kind icon of a row (Main.html `.ki`). Kinds without an icon on a
    /// board use the closest one: ✓ for Mergeable, × for Checks failed,
    /// Conflicts and Removed from merge queue.
    public static func row(_ kind: Lenient<RowKind>) -> BoardIcon {
        switch kind.value {
        case .reviewRequested, .teamReviewRequested: return kindReviewRequest
        case .mentioned, .teamMentioned: return kindMention
        // Main.html draws Reaction with the comment icon too.
        case .comment, .commentOther, .reply, .replyMentioned, .reaction, nil: return kindComment
        case .changesRequested, .closed: return kindChangesRequested
        case .merged: return kindMerged
        case .approved, .checksPassed: return kindPassed
        case .reopened: return kindReopened
        case .checksFailed, .conflicts, .mergeQueueRemoved: return rowCross
        case .mergeable: return rowCheck
        case .mergeQueueAdded: return mergeQueue
        }
    }
}

/// The marks on an account's menu bar icon (DESIGN.md, "Screens";
/// MenuBarIcon.html): the blue dot top right and the triangle bottom left.
/// There is no number.
public struct MenuBarMarks: Equatable {
    public var dot: Bool
    public var triangle: Bool

    public init(dot: Bool, triangle: Bool) {
        self.dot = dot
        self.triangle = triangle
    }

    public init(_ account: Account) {
        self.init(dot: account.unread, triangle: Warnings.hasTriangle(account))
    }

    /// `shiibar-gh, <login>`, then `, unread` with the dot and `, needs
    /// attention` with the triangle (DESIGN.md, "Screens").
    public static func accessibilityLabel(_ account: Account) -> String {
        var text = "shiibar-gh, " + account.login
        if account.unread { text += ", unread" }
        if Warnings.hasTriangle(account) { text += ", needs attention" }
        return text
    }

    /// The shiibar-gh icon shown while there is no account.
    public static let noAccountsLabel = "shiibar-gh, no accounts"
}

/// What a status item shows. The image is set again only when this changes
/// (DESIGN.md, "UI": the appearance, the account color, the blue dot and the
/// triangle), and the label and tooltip only when they change: setting the
/// image of a status button redraws it and notifies its effective
/// appearance, which made 0.3.0 redraw in a loop.
public struct StatusItemLook: Equatable {
    public var dark: Bool
    public var color: AccountColor
    public var marks: MenuBarMarks
    public var accessibilityLabel: String
    public var toolTip: String

    public init(dark: Bool, color: AccountColor, marks: MenuBarMarks, accessibilityLabel: String, toolTip: String) {
        self.dark = dark
        self.color = color
        self.marks = marks
        self.accessibilityLabel = accessibilityLabel
        self.toolTip = toolTip
    }

    /// The parts of the look the image is drawn from.
    public func sameImage(as other: StatusItemLook?) -> Bool {
        guard let other else { return false }
        return dark == other.dark && color == other.color && marks == other.marks
    }
}

/// What to set on a status button for a new look, given the one set last.
public struct StatusItemUpdate: Equatable {
    public var image: Bool
    public var accessibilityLabel: Bool
    public var toolTip: Bool

    public init(from old: StatusItemLook?, to new: StatusItemLook) {
        image = !new.sameImage(as: old)
        accessibilityLabel = old?.accessibilityLabel != new.accessibilityLabel
        toolTip = old?.toolTip != new.toolTip
    }

    public var isEmpty: Bool { !image && !accessibilityLabel && !toolTip }

    /// The same update with the label and the tooltip as given (tests).
    func with(label: Bool, tip: Bool) -> StatusItemUpdate {
        var update = self
        update.accessibilityLabel = label
        update.toolTip = tip
        return update
    }
}
