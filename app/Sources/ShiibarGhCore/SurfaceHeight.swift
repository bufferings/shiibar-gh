// The height of a popover or window (DESIGN.md, "Screens", "Filter"): the
// one the user set, raised to the least height the content needs. The
// Filter's options keep their full height and the list keeps its minimum,
// so the least height is what is above the list with the options open, the
// list's minimum and what is below it, never under 300 points: one value
// per text size, whether the options are open or not, so opening or
// closing them never changes the height. A larger text size raises it; a
// smaller one lets the surface go back to the height the user set, which
// is the one kept.

import CoreGraphics
import Foundation

public struct SurfaceHeight: Equatable {
    /// The smallest height of a popover or window (DESIGN.md, "Constants").
    public static let floor: CGFloat = 300
    /// The list's minimum at text size 12, multiplied by the text scale.
    public static let listMinimum: CGFloat = 100

    /// The least height for the parts above and below the list at the text
    /// scale `k`.
    public static func minimum(above: CGFloat, below: CGFloat, k: CGFloat) -> CGFloat {
        max(floor, (above + listMinimum * k + below).rounded(.up))
    }

    /// The height the user set (dragging, the window's frame), or the one
    /// the surface opened with.
    public private(set) var user: CGFloat
    /// What the content needs now.
    public private(set) var minimum: CGFloat = SurfaceHeight.floor

    public init(user: CGFloat) {
        self.user = max(Self.floor, user)
    }

    /// The height to show: the user's, raised to the minimum, within
    /// `room` (the screen's) when there is less: then the room, and the
    /// list gets what is left.
    public func shown(room: CGFloat? = nil) -> CGFloat {
        let wanted = max(user, minimum)
        guard let room else { return wanted }
        return min(wanted, max(Self.floor, room))
    }

    /// The content needs `value`; true when it changed.
    @discardableResult
    public mutating func setMinimum(_ value: CGFloat) -> Bool {
        let value = max(Self.floor, value)
        guard abs(value - minimum) >= 0.5 else { return false }
        minimum = value
        return true
    }

    /// The height `minimum` raises this one to, within `room`.
    public func raised(to minimum: CGFloat, room: CGFloat?) -> CGFloat {
        var copy = self
        copy.setMinimum(minimum)
        return copy.shown(room: room)
    }

    /// The user set this height (a drag, a resize): kept as set.
    public mutating func setByUser(_ value: CGFloat) {
        user = max(Self.floor, value)
    }
}
