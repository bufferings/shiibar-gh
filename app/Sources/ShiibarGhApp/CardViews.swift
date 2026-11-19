// The values of the list of a popover or window (docs/design/Main.html):
// its lines (section and group headings, cards, "+ N more PRs", the
// Dismissed list) and what their views share; and the picture of a dragged
// card.
//
// Speed (DESIGN.md, "Speed of operation"; docs/tasks/M7.md):
// - The list is a table that reuses its lines' views (ListTable.swift):
//   only the lines in view are made and laid out.
// - The lines are AppKit views that draw their text (ListCells.swift):
//   nothing can be selected (DESIGN.md, "What a press does").
// - A line view gets the values it shows; the selection or a drag draw
//   again only the line views whose item state changed.
// - Presses go to the line views (CardInput.swift), which know where their
//   rows and controls are.

import AppKit
import ShiibarGhCore
import SwiftUI

/// The values of a card line.
struct CardLine: Equatable {
    var card: Card
    var section: String
    /// The placement tag: All only.
    var showsTag: Bool
    /// Under a second-level group of All (Main.html `.card.in`).
    var indented: Bool
    var expanded: Bool
    var canDrag: Bool
    /// The card's rows whose body is expanded with `more`.
    var expandedBodies: Set<String> = []
    /// Compact (DESIGN.md, "Compact"): the heading only, with the card's
    /// unread mark at the left of line 1.
    var compact = false
    var unread: UnreadMark = .none
    /// The words of the search (`Search.words`): what matched gets a yellow
    /// background (DESIGN.md, "Showing what matched"). Part of what the
    /// card's image is drawn from, not of its geometry.
    var search: [String] = []
    /// `Show labels` (DESIGN.md, "Card", "GitHub labels"): the label line
    /// ends the heading of a card with labels.
    var showsLabels = false

    /// The my review mark (`MyReviewMark.of`), and the URL of the
    /// account's avatar while its image is loaded: without it the mark
    /// shows the sign alone and keeps no room for the avatar.
    var myReview: MyReviewMark?
    var myAvatar: String?

    /// The labels the heading shows: none while `Show labels` is off.
    var shownLabels: [PRLabel] { showsLabels ? card.labels : [] }
}

/// The values of a section heading, or of a repository of the Dismissed
/// list.
struct HeadingLine: Equatable {
    var key: String
    var title: String
    var detail: String
    var level: Int
    var collapsed: Bool
    var showLess: Bool
    /// `Dismiss all` shows (the Done of Review and Mine, with cards to
    /// dismiss, not collapsed). Part of the heading's image.
    var dismissAll = false
    /// The unread mark before the name of a collapsed heading (DESIGN.md,
    /// "Section size"). Part of the heading's image, so a change of what it
    /// shows draws the heading again.
    var mark: UnreadMark = .none
    /// A section heading: it folds, has its chevron and takes the
    /// selection. A repository of the Dismissed list does none of these
    /// (DESIGN.md, "Dismissed list").
    var folds = true
    /// The room above the band: less under the Dismissed list's note
    /// (Main.html `.dhead + .dnote + .band`).
    var gap: CGFloat = 8

    init(_ section: SectionLayout) {
        key = section.key
        title = section.title
        detail = section.detail
        level = section.level
        collapsed = section.collapsed
        showLess = section.showLess
        dismissAll = section.dismissAllCards != nil
        mark = section.foldMark
    }

    /// The band of a repository of the Dismissed list; `first` right under
    /// the list's note.
    init(_ group: DismissedGroup, first: Bool) {
        key = "dismissed|" + group.repository
        title = group.repository
        detail = group.detail
        level = 1
        collapsed = false
        showLess = false
        folds = false
        gap = first ? 2 : 8
    }
}

/// The values of a "+ N more PRs" or `Show less` line.
struct FoldValues: Equatable {
    var key: String
    var text: String
    var mark: UnreadMark
}

/// One line of the list (ListTable.swift): one table row.
enum ListEntry: Equatable {
    /// The text of an empty list, above everything.
    case message(String)
    case heading(HeadingLine)
    case card(CardLine)
    /// The room under the heading of an empty Review or Mine section.
    case empty(String)
    case fold(FoldValues)
    /// A card of the Dismissed list, with the words of its search.
    case dismissed(Card, search: [String])
    /// The space under the last line.
    case end

    var id: String {
        switch self {
        case .message: return "message"
        case .heading(let heading): return "section:" + heading.key
        case .card(let line): return "card:" + line.card.id
        case .dismissed(let card, _): return "card:" + card.id
        case .empty(let key): return "empty:" + key
        case .fold(let fold): return "more:" + fold.key
        case .end: return "end"
        }
    }

    /// The entry without its search words: the geometry does not depend
    /// on them, so typing in the search field works none out again.
    var withoutSearch: ListEntry {
        switch self {
        case .card(var line):
            line.search = []
            return .card(line)
        case .dismissed(let card, _): return .dismissed(card, search: [])
        default: return self
        }
    }

    /// The line of a selected item.
    static func id(of item: SelectionItem) -> String {
        switch item {
        case .section(let key): return "section:" + key
        case .more(let key): return "more:" + key
        case .header(let card), .row(_, let card), .moreRows(let card), .olderActivity(let card), .lessRows(let card):
            return "card:" + card
        }
    }
}

/// The values of an item state.
struct ItemSnapshot: Equatable {
    var selected: SelectionItem?
    /// One of several selected cards.
    var marked: Bool
    var dragged: Bool
    var over: Bool

    @MainActor init(_ state: ItemState) {
        selected = state.selected
        marked = state.marked
        dragged = state.dragged
        over = state.over
    }

    init(selected: SelectionItem?, marked: Bool, dragged: Bool, over: Bool) {
        self.selected = selected
        self.marked = marked
        self.dragged = dragged
        self.over = over
    }

    /// Nothing selected or dragged: what a line is measured with.
    static let none = ItemSnapshot(selected: nil, marked: false, dragged: false, over: false)
}

extension SelectionItem {
    /// The item if it is in `card` (its heading, a row, "+ N more" or
    /// `Older activity on GitHub`).
    func inCard(_ card: String) -> SelectionItem? {
        switch self {
        case .header(let id), .row(_, let id), .moreRows(let id), .olderActivity(let id), .lessRows(let id):
            return id == card ? self : nil
        case .section, .more:
            return nil
        }
    }
}

/// What the views of a surface's list share without observing it: the
/// surface (for actions), the avatars and the drag.
@MainActor
final class CardContext {
    unowned let list: SurfaceListModel
    let avatars: AvatarStore
    let drag: CardDragController
    let content: ListContent

    private init(list: SurfaceListModel, avatars: AvatarStore) {
        self.list = list
        self.avatars = avatars
        drag = CardDragController.of(list)
        content = ListContent(list: list)
        content.drag = drag
        content.context = self
    }

    private static var contexts: [ObjectIdentifier: CardContext] = [:]

    static func of(_ list: SurfaceListModel, avatars: AvatarStore) -> CardContext {
        if let context = contexts[ObjectIdentifier(list)] { return context }
        let context = CardContext(list: list, avatars: avatars)
        contexts[ObjectIdentifier(list)] = context
        return context
    }
}

/// The card under the pointer while it is dragged: the heading lines of
/// the card at the card's width, without its buttons and rows; with the
/// number of cards when the selected ones move together.
struct CardDragPreview: View {
    var card: Card
    var count: Int
    var width: CGFloat
    var k: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                StateLabelView(label: card.stateLabel)
                Text(Warnings.prLabel(card.pr))
                    .font(.system(size: 11 * k))
                    .foregroundColor(Palette.secondary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 11 * k, weight: .bold))
                        .foregroundColor(Palette.onColor.color)
                        .padding(.horizontal, 6 * k)
                        .frame(height: 16 * k)
                        .background(Capsule().fill(Palette.accent.color))
                }
            }
            Text(card.title)
                .font(.system(size: 12 * k, weight: .semibold))
                .foregroundColor(Palette.text.color)
                .lineLimit(1)
                .padding(.top, 3 * k)
            Text("\(card.base) \u{2190} \(card.head)")
                .font(.system(size: 11 * k))
                .foregroundColor(Palette.secondary.color)
                .lineLimit(1)
                .padding(.top, 5 * k)
        }
        .environment(\.textScale, k)
        .padding(EdgeInsets(top: 6 * k, leading: 12, bottom: 6 * k, trailing: 10))
        .frame(width: width, alignment: .leading)
        .background(Palette.surface.color)
        .overlay(alignment: .leading) {
            if let bar = stateBar(card.stateLabel) { Rectangle().fill(bar).frame(width: 4) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.color, lineWidth: 1))
    }
}

/// How long the chain icon shows its check (DESIGN.md, "Constants").
enum LinkCopy {
    static let checkSeconds: TimeInterval = 1
}

/// The colored line at the left edge of a card, the color of its state
/// label.
func stateBar(_ label: Lenient<StateLabel>) -> Color? {
    switch label.value {
    case .mergeable: return Palette.green.color
    case .draft: return Palette.gray.color
    case .merged: return Palette.purple.color
    case .closed: return Palette.badge.color
    default: return nil
    }
}

struct StateLabelView: View {
    var label: Lenient<StateLabel>
    @Environment(\.textScale) var k

    var body: some View {
        let style: (String, Color, Color)? = {
            switch label.value {
            case .mergeable: return ("Mergeable", Palette.green.color, Palette.onColor.color)
            case .draft: return ("Draft", Palette.draftBackground.color, Palette.draftText.color)
            case .merged: return ("Merged", Palette.purpleBackground.color, Palette.purpleText.color)
            case .closed: return ("Closed", Palette.orangeIconBackground.color, Palette.orangeText.color)
            case .open, nil: return nil
            }
        }()
        if let (text, background, foreground) = style {
            Text(text)
                .font(.system(size: 10 * k, weight: .semibold))
                .foregroundColor(foreground)
                .padding(.horizontal, 6 * k)
                .frame(height: 16 * k)
                .background(RoundedRectangle(cornerRadius: 4).fill(background))
                .fixedSize()
        }
    }
}

/// Decoded avatar images: each image is decoded once and kept
/// (docs/tasks/M7.md, "Speed of operation", suspect 4).
@MainActor
enum DecodedAvatars {
    private static var images: [String: NSImage] = [:]

    static func image(_ url: String?, data: Data?) -> NSImage? {
        guard let url, let data else { return nil }
        if let image = images[url] { return image }
        guard let image = NSImage(data: data) else { return nil }
        images[url] = image
        return image
    }
}
