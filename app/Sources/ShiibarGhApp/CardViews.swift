// The list of a popover or window (docs/design/Main.html): section and group
// headings, cards, rows, "+ N more PRs", the Dismissed list, dragging a card
// by its grip and dropping it, and the clicks of DESIGN.md, "What a press
// does".

import AppKit
import ShiibarGhCore
import SwiftUI

struct ListArea: View {
    @ObservedObject var model: SurfaceListModel
    @ObservedObject var avatars: AvatarStore
    var now: Int64

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    if let empty = model.emptyText {
                        EmptyList(text: empty)
                    }
                    if model.showingDismissed {
                        ForEach(model.dismissedCards) { card in
                            DismissedCardView(card: card, model: model, avatars: avatars, now: now)
                        }
                    } else {
                        sections
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: model.selection) { _, selection in
                if let selection {
                    withAnimation(.easeOut(duration: 0.1)) { reader.scrollTo(selection.id) }
                }
            }
        }
    }

    @ViewBuilder
    var sections: some View {
        let allTab = model.tab == .all
        ForEach(model.sections) { section in
            let line = model.dropTarget.flatMap { $0.section == section.key ? CardDrop.lineAbove($0, in: section) ?? "" : nil }
            if section.showsHeader {
                SectionHeaderView(section: section, model: model)
            }
            ForEach(section.cards) { card in
                let drop: VerticalEdge? = line == card.id ? .top : (line == "" && card.id == section.cards.last?.id ? .bottom : nil)
                CardView(
                    card: card, showsGrip: section.accepts && card.canDrag, showsTag: allTab, indented: section.level == 2,
                    dropLine: drop, model: model, avatars: avatars, now: now
                )
            }
            if section.accepts, section.matching.isEmpty, !section.collapsed {
                EmptySection(section: section.key, over: model.dropTarget?.section == section.key, model: model)
            }
            if let text = section.foldLine {
                FoldLine(text: text, mark: section.more > 0 ? section.moreMark : .none, section: section.key, model: model)
            }
        }
    }
}

/// A section heading: a band (Main.html `.band`) for Review and Mine
/// sections and the first level of All; a small indented heading
/// (`.grp2`) for the second level. Pressing it folds the section.
struct SectionHeaderView: View {
    var section: SectionLayout
    @ObservedObject var model: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        let selected = model.selection == .section(section.key)
        Group {
            if section.level == 1 {
                band(selected: selected)
            } else {
                small(selected: selected)
            }
        }
        .cardDrop({ _ in .header(section.key) }, model: model)
        .id(SelectionItem.section(section.key).id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title), \(section.detail)")
        .accessibilityValue(section.collapsed ? "Collapsed" : "Expanded")
    }

    var chevron: some View {
        IconView(icon: section.collapsed ? BoardIcons.sectionClosed : BoardIcons.sectionOpen, size: 12 * k, color: Palette.faded.color)
            .frame(width: 14 * k, height: 14 * k)
    }

    func band(selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.system(size: 12 * k, weight: .semibold))
                .foregroundColor(section.collapsed ? Palette.secondary.color : Palette.text.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if section.showLess {
                Button { model.perform(.toggleMore(section.key)) } label: {
                    Text("Show less").font(.system(size: 11 * k)).foregroundColor(Palette.settingsTabSelected.color)
                }
                .buttonStyle(.plain)
            }
            Text(section.detail).font(.system(size: 11 * k)).foregroundColor(Palette.secondary.color)
            chevron
        }
        .padding(EdgeInsets(top: 4 * k, leading: 10, bottom: 4 * k, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection.color : Palette.band.color))
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
        .contentShape(Rectangle())
        .onTapGesture { press() }
    }

    func small(selected: Bool) -> some View {
        HStack(spacing: 6) {
            chevron
            Text(section.title)
                .font(.system(size: 11 * k, weight: .semibold))
                .foregroundColor(Palette.strongText.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if section.showLess {
                Button { model.perform(.toggleMore(section.key)) } label: {
                    Text("Show less").font(.system(size: 11 * k)).foregroundColor(Palette.settingsTabSelected.color)
                }
                .buttonStyle(.plain)
            }
            Text(section.detail).font(.system(size: 11 * k)).foregroundColor(Palette.waiting.color)
        }
        .padding(EdgeInsets(top: 2 * k, leading: 22, bottom: 2 * k, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection.color : .clear))
        .padding(EdgeInsets(top: 2, leading: 12, bottom: 4, trailing: 12))
        .contentShape(Rectangle())
        .onTapGesture { press() }
    }

    func press() {
        model.select(.section(section.key))
        model.perform(.toggleSection(section.key))
    }
}

/// The blue dot, the gray ring, or the room for them.
struct UnreadDot: View {
    var mark: UnreadMark
    @Environment(\.textScale) var k

    var body: some View {
        Group {
            switch mark {
            case .blue: Circle().fill(Palette.blueDot.color)
            case .ring: Circle().strokeBorder(Palette.mutedText.color, lineWidth: 1.5)
            case .none: Color.clear
            }
        }
        .frame(width: 7 * k, height: 7 * k)
        .accessibilityLabel(mark == .none ? "" : (mark == .blue ? "Unread" : "Unread, muted"))
    }
}

/// "+ 2 more PRs" or "Show less" (Main.html `.more`).
struct FoldLine: View {
    var text: String
    var mark: UnreadMark
    var section: String
    @ObservedObject var model: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        let selected = model.selection == .more(section)
        HStack(spacing: 8) {
            UnreadDot(mark: mark)
            Text(text).font(.system(size: 12 * k)).foregroundColor(Palette.secondary.color)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 2 * k, leading: 16, bottom: 2 * k, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection.color : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(.more(section))
            model.perform(.toggleMore(section))
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
        .cardDrop({ _ in .more(section) }, model: model)
        .id(SelectionItem.more(section).id)
        .accessibilityAddTraits(.isButton)
    }
}

/// The room under the heading of an empty Review section: where a dragged
/// card lands.
struct EmptySection: View {
    var section: String
    var over: Bool
    @ObservedObject var model: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        Text("No pull requests")
            .font(.system(size: 11 * k))
            .foregroundColor(Palette.faded.color)
            .frame(maxWidth: .infinity)
            .frame(height: 30 * k)
            .background(RoundedRectangle(cornerRadius: 10).fill(over ? Palette.selection.color : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(over ? Palette.blueDot.color : Palette.border.color, style: StrokeStyle(lineWidth: over ? 2 : 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
            .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
            .cardDrop({ _ in .header(section) }, model: model)
    }
}

struct EmptyList: View {
    var text: String
    @Environment(\.textScale) var k

    var body: some View {
        Text(text)
            .font(.system(size: 12 * k))
            .foregroundColor(Palette.faded.color)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 18 * k, leading: 12, bottom: 22 * k, trailing: 12))
    }
}

extension View {
    /// Click selects, right-click selects and shows the menu (DESIGN.md,
    /// "What a press does"); there is no double-click open. Buttons inside
    /// (the status icons, the open icon, the ×, the tag) keep their own
    /// click, and selectable text selects the item itself when pressed.
    func pressable(_ item: SelectionItem, model: SurfaceListModel) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture { model.select(item) }
            .overlay(RightClickArea(
                menu: { model.rightClick(item) },
                perform: { model.perform($0) }
            ))
    }

    /// Takes a card dragged by its grip; `zone` turns the pointer, in this
    /// view's coordinates, into what it is over.
    func cardDrop(_ zone: @escaping (CGPoint) -> DropZone, model: SurfaceListModel) -> some View {
        onDrop(of: [CardDrop.type], delegate: CardDropDelegate(zone: zone, model: model))
    }
}

/// The drop side of moving a card (DESIGN.md, "What a press does"): the
/// line while the card is over a place it can land, the forbidden cursor
/// where it cannot, and the move on release.
struct CardDropDelegate: DropDelegate {
    var zone: (CGPoint) -> DropZone
    var model: SurfaceListModel

    func validateDrop(info: DropInfo) -> Bool {
        model.dragging != nil && info.hasItemsConforming(to: [CardDrop.type])
    }

    func dropEntered(info: DropInfo) {
        model.dragOver(zone(info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: model.dragOver(zone(info.location)) == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        model.dragExited(zone(info.location))
    }

    func performDrop(info: DropInfo) -> Bool {
        model.drop(zone(info.location))
    }
}

/// The insertion line (Main.html `.dropline`).
struct DropLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(Palette.blueDot.color, lineWidth: 2)
                .background(Circle().fill(Palette.background.color))
                .frame(width: 8, height: 8)
            Rectangle().fill(Palette.blueDot.color).frame(height: 2)
        }
        .frame(height: 8)
        .padding(.leading, -3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The grip ⋮⋮ (Main.html `.grip`): the only place a card drag starts.
struct Grip: View {
    var card: Card
    /// The width of the card, for the picture that follows the pointer.
    var cardWidth: CGFloat
    @ObservedObject var model: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        Text("\u{22EE}\u{22EE}")
            .font(.system(size: 11 * k, weight: .bold))
            .tracking(-1 * k)
            .fixedSize()
            .foregroundColor(Palette.grip.color)
            .frame(width: 10 * k, height: 16 * k, alignment: .leading)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .accessibilityLabel("Drag to reorder")
            .grabCursor()
            .onDrag {
                model.beginDrag(card.id)
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: CardDrop.type.identifier, visibility: .ownProcess) { done in
                    done(Data(card.id.utf8), nil)
                    return nil
                }
                return provider
            } preview: {
                // The picture is centered on the pointer, so clear room on
                // the left and above puts the picture's grip under it: the
                // card stays where it was grabbed.
                let width = max(cardWidth, 200)
                let grip = CGPoint(x: 12 + 5 * k, y: 14 * k)
                let picture = CardDragPreview(card: card, width: width, k: k)
                HStack(spacing: 0) {
                    Color.clear.frame(width: width - 2 * grip.x, height: 1)
                    VStack(spacing: 0) {
                        picture.hidden().padding(.top, -2 * grip.y)
                        picture
                    }
                }
            }
    }
}

/// The card under the pointer while it is dragged: the heading lines of
/// the card at the card's width, without its buttons and rows.
struct CardDragPreview: View {
    var card: Card
    var width: CGFloat
    var k: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * k) {
            HStack(spacing: 7) {
                Text("\u{22EE}\u{22EE}")
                    .font(.system(size: 11 * k, weight: .bold))
                    .tracking(-1 * k)
                    .fixedSize()
                    .foregroundColor(Palette.grip.color)
                    .frame(width: 10 * k, height: 16 * k, alignment: .leading)
                    .padding(.trailing, -6)
                StateLabelView(label: card.stateLabel)
                Text(Warnings.prLabel(card.pr))
                    .font(.system(size: 11 * k))
                    .foregroundColor(Palette.secondary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(card.title)
                .font(.system(size: 12 * k, weight: .semibold))
                .foregroundColor(Palette.text.color)
                .lineLimit(1)
            Text("\(card.base) \u{2190} \(card.head)")
                .font(.system(size: 11 * k))
                .foregroundColor(Palette.secondary.color)
                .lineLimit(1)
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

extension View {
    /// The open hand over the grip (NSCursor.openHand; `pointerStyle` from
    /// macOS 15, which also holds while the view redraws).
    @ViewBuilder
    func grabCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.grabIdle)
        } else {
            onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

/// The open icon at the right end of a card header and of a row (Main.html
/// `.op`), always shown.
struct OpenIcon: View {
    var action: () -> Void
    @Environment(\.textScale) var k

    var body: some View {
        Button(action: action) {
            IconView(icon: BoardIcons.open, size: 12 * k, color: Palette.faded.color)
                .frame(width: 18 * k, height: 18 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help("Open on GitHub")
        .accessibilityLabel("Open on GitHub")
    }
}

/// The outlined `Assigned` and `Muted` marks (Main.html `.mk`).
struct OutlinedMark: View {
    var text: String
    @Environment(\.textScale) var k

    var body: some View {
        Text(text)
            .font(.system(size: 10 * k, weight: .semibold))
            .foregroundColor(Palette.secondary.color)
            .padding(.horizontal, 5 * k)
            .frame(height: 14 * k)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.markBorder.color, lineWidth: 1))
            .fixedSize()
    }
}

/// The placement tag of All (Main.html `.tag`): opens the tab with the card.
struct PlacementTag: View {
    var text: String
    var press: () -> Void
    @Environment(\.textScale) var k

    var body: some View {
        Button(action: press) {
            Text(text)
                .font(.system(size: 10 * k, weight: .semibold))
                .foregroundColor(Palette.tagText.color)
                .padding(.horizontal, 6 * k)
                .frame(height: 14 * k)
                .background(Capsule().fill(Palette.tagBackground.color))
                .overlay(Capsule().stroke(Palette.tagBorder.color, lineWidth: 1))
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in its tab")
    }
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

struct CardView: View {
    var card: Card
    /// The grip ⋮⋮: Review and Mine, Done included, not muted.
    var showsGrip: Bool
    /// The placement tag: All only.
    var showsTag: Bool
    /// Under a second-level group of All (Main.html `.card.in`).
    var indented: Bool
    /// The insertion line in the gap above or below the card, drawn over
    /// the gap so that the cards do not move under the pointer.
    var dropLine: VerticalEdge?
    @ObservedObject var model: SurfaceListModel
    @ObservedObject var avatars: AvatarStore
    var now: Int64
    @Environment(\.textScale) var k
    @State private var height: CGFloat = 0
    @State private var width: CGFloat = 0

    var body: some View {
        let item = SelectionItem.header(card: card.id)
        let selected = model.selection == item
        let muted = card.isMuted
        let expanded = model.expandedRows.contains(card.id)
        let coordinator = TextSelectionCoordinator.of(model)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3 * k) {
                HStack(spacing: 7) {
                    if showsGrip {
                        Grip(card: card, cardWidth: width, model: model).padding(.trailing, -6)
                    }
                    StateLabelView(label: card.stateLabel)
                    SelectableText(
                        text: Warnings.prLabel(card.pr), font: .board(11 * k),
                        color: muted ? Palette.mutedText.nsColor : Palette.secondary.nsColor,
                        lineLimit: 1, coordinator: coordinator
                    ) { model.select(item) }
                    .layoutPriority(-1)
                    if card.awaitingReview { ReviewRequestedMark() }
                    if card.assignedToMe { OutlinedMark(text: "Assigned") }
                    if muted { OutlinedMark(text: "Muted") }
                    Spacer(minLength: 0)
                    if !card.isFinished {
                        StatusIcons(card: card, model: model)
                    }
                    OpenIcon { model.perform(.open(card.url, read: nil)) }
                }
                HStack(spacing: 6) {
                    Avatar(data: avatars.image(for: card.authorAvatarUrl), login: card.author)
                        .opacity(muted ? 0.6 : 1)
                        .onAppear { avatars.request(card.authorAvatarUrl) }
                    SelectableText(
                        text: card.title, font: .board(12 * k, muted ? .regular : .semibold),
                        color: muted ? Palette.mutedTitle.nsColor : Palette.text.nsColor,
                        lineLimit: 1, coordinator: coordinator
                    ) { model.select(item) }
                    Spacer(minLength: 0)
                }
                // Line 3; the times wrap to a fourth line rather than shorten.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        left
                        Spacer(minLength: 0)
                        right
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        left
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            right
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 6 * k, leading: 12, bottom: 5 * k, trailing: 10))
            .background(selected ? Palette.selection.color : .clear)
            .pressable(item, model: model)
            .id(item.id)
            VStack(spacing: 0) {
                ForEach(Listing.visibleRows(card, expanded: expanded)) { row in
                    RowView(row: row, cardMuted: muted, model: model, now: now, card: card.id)
                }
                if let more = Listing.moreRows(card, expanded: expanded) {
                    CardFootLine(
                        item: .moreRows(card: card.id), text: Listing.moreRowsText(more), mark: Listing.moreRowsMark(card),
                        opens: false, model: model
                    ) { model.perform(.expandRows(card: card.id)) }
                }
                if Listing.showsOlderActivity(card, expanded: expanded) {
                    CardFootLine(
                        item: .olderActivity(card: card.id), text: "Older activity on GitHub", mark: .none, opens: true, model: model
                    ) { model.perform(.open(card.url, read: nil)) }
                }
            }
        }
        .background(Palette.surface.color)
        .overlay(alignment: .leading) {
            if let bar = stateBar(card.stateLabel) { Rectangle().fill(bar).frame(width: 4) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.color, lineWidth: 1))
        .overlay(alignment: .top) { if dropLine == .top { DropLine().offset(y: -8) } }
        .overlay(alignment: .bottom) { if dropLine == .bottom { DropLine().offset(y: 8) } }
        .opacity(model.dragging == card.id ? 0.35 : 1)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .padding(EdgeInsets(top: 0, leading: indented ? 24 : 12, bottom: 8, trailing: 12))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height = $0 })
        .cardDrop({ [height] point in .card(card.id, lowerHalf: point.y > height / 2) }, model: model)
    }

    var left: some View {
        HStack(spacing: 6) {
            if showsTag, let tag = card.placementTag {
                PlacementTag(text: tag) { model.perform(.showInTab(card: card.id)) }
            }
            SelectableText(
                text: "\(card.base) \u{2190} \(card.head)", font: .board(11 * k),
                color: card.isMuted ? Palette.mutedText.nsColor : Palette.secondary.nsColor,
                lineLimit: 1, coordinator: TextSelectionCoordinator.of(model)
            ) { model.select(.header(card: card.id)) }
        }
    }

    var right: some View {
        HStack(spacing: 4) {
            // `Dismissed in N days` (DESIGN.md, "Card header"): plain text,
            // left of the times.
            if let text = DismissedText.dismissedIn(card.autoDismissAt, now: now) {
                Text(text)
                    .font(.system(size: 11 * k))
                    .foregroundColor(Palette.faded.color)
                    .lineLimit(1)
                    .fixedSize()
                    .help(DismissedText.dismissedInHelp(
                        autoDismissDays: model.autoDismissDays, inDone: card.placement?.isDone == true
                    ))
                    .padding(.trailing, 4)
            }
            SelectableText(
                text: CardText.times(card, now: now), font: .board(11 * k),
                color: card.isMuted ? Palette.mutedText.nsColor : Palette.waiting.nsColor,
                lineLimit: 1, coordinator: TextSelectionCoordinator.of(model)
            ) { model.select(.header(card: card.id)) }
            .fixedSize()
            .help(CardText.exactTimes(card))
            Button { model.perform(.dismiss(card: card.id)) } label: {
                IconView(icon: BoardIcons.dismiss, size: 12 * k, color: Palette.faded.color)
                    .frame(width: 18 * k, height: 18 * k)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
    }
}

/// "+ N more" in a card, and `Older activity on GitHub` (Main.html
/// `.evm`): a click selects the line and does what ⏎ does.
struct CardFootLine: View {
    var item: SelectionItem
    var text: String
    var mark: UnreadMark
    var opens: Bool
    @ObservedObject var model: SurfaceListModel
    var action: () -> Void
    @Environment(\.textScale) var k

    var body: some View {
        let selected = model.selection == item
        HStack(spacing: 8) {
            UnreadDot(mark: mark)
            Text(text).font(.system(size: 12 * k)).foregroundColor(Palette.secondary.color)
            Spacer(minLength: 0)
            if opens { OpenIcon(action: action) }
        }
        .padding(EdgeInsets(top: 4 * k, leading: 14, bottom: 5 * k, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.selection.color : Palette.surface.color)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rowDivider.color).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(item)
            action()
        }
        .id(item.id)
        .accessibilityAddTraits(.isButton)
    }
}

/// A card of the Dismissed list (Main.html): the state label, owner/repo
/// #number, the open icon; the avatar and the title; the days left and
/// Restore. No rows, no status icons, no grip, no ×.
struct DismissedCardView: View {
    var card: Card
    @ObservedObject var model: SurfaceListModel
    @ObservedObject var avatars: AvatarStore
    var now: Int64
    @Environment(\.textScale) var k

    var body: some View {
        let item = SelectionItem.header(card: card.id)
        let selected = model.selection == item
        let coordinator = TextSelectionCoordinator.of(model)
        VStack(alignment: .leading, spacing: 3 * k) {
            HStack(spacing: 7) {
                StateLabelView(label: card.stateLabel)
                SelectableText(
                    text: Warnings.prLabel(card.pr), font: .board(11 * k), color: Palette.secondary.nsColor,
                    lineLimit: 1, coordinator: coordinator
                ) { model.select(item) }
                .layoutPriority(-1)
                Spacer(minLength: 0)
                OpenIcon { model.perform(.open(card.url, read: nil)) }
            }
            HStack(spacing: 6) {
                Avatar(data: avatars.image(for: card.authorAvatarUrl), login: card.author)
                    .onAppear { avatars.request(card.authorAvatarUrl) }
                SelectableText(
                    text: card.title, font: .board(12 * k, .semibold), color: Palette.text.nsColor,
                    lineLimit: 1, coordinator: coordinator
                ) { model.select(item) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(DismissedText.daysLeft(card.dismissExpiresAt, now: now))
                    .font(.system(size: 11 * k))
                    .foregroundColor(Palette.secondary.color)
                SettingsButton(title: "Restore", small: true) { model.perform(.restore(card: card.id)) }
            }
        }
        .padding(EdgeInsets(top: 6 * k, leading: 12, bottom: 5 * k, trailing: 10))
        .background(selected ? Palette.selection.color : .clear)
        .pressable(item, model: model)
        .background(Palette.surface.color)
        .overlay(alignment: .leading) {
            if let bar = stateBar(card.stateLabel) { Rectangle().fill(bar).frame(width: 4) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.color, lineWidth: 1))
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
        .id(item.id)
    }
}

/// `Review requested` (Main.html `.rq`): light orange with dark orange text,
/// while the PR waits for your review.
struct ReviewRequestedMark: View {
    @Environment(\.textScale) var k

    var body: some View {
        Text(CardText.reviewRequestedMark)
            .font(.system(size: 10 * k, weight: .bold))
            .foregroundColor(Palette.orangeText.color)
            .padding(.horizontal, 6 * k)
            .frame(height: 16 * k)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.reviewMark.color))
            .fixedSize()
    }
}

struct StateLabelView: View {
    var label: Lenient<StateLabel>
    @Environment(\.textScale) var k

    var body: some View {
        let style: (String, Color, Color)? = {
            switch label.value {
            case .mergeable: return ("Mergeable", Palette.green.color, Palette.onColor.color)
            case .draft: return ("Draft", Palette.tint.color, Palette.draftText.color)
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

struct StatusIcons: View {
    var card: Card
    var model: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 2) {
            slot(review, "Review", card.links.review)
            slot(checks, "Checks", card.links.checks)
            slot(base, "Base", card.links.base)
        }
    }

    var review: (StatusIcon.Look, String) {
        switch card.review.value {
        case .approved: return (.ok, "Approved")
        case .reviewRequired: return (.waiting, "Review required")
        case .changesRequested: return (.bad, "Changes requested")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    var checks: (StatusIcon.Look, String) {
        switch card.checks.value {
        case .passed: return (.ok, "Passed")
        case .inProgress: return (.waiting, "In progress")
        case .failed: return (.bad, "Failed")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    var base: (StatusIcon.Look, String) {
        switch card.baseStatus.value {
        case .upToDate: return (.ok, "Up to date")
        case .behind: return (.waiting, "Behind")
        case .conflicts: return (.bad, "Conflicts")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    func slot(_ value: (StatusIcon.Look, String), _ axis: String, _ url: String) -> some View {
        Button { model.perform(.open(url, read: nil)) } label: {
            StatusIcon(look: value.0)
                .scaleEffect(k)
                .frame(width: 20 * k, height: 20 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help("\(axis): \(value.1)")
        .accessibilityLabel("\(axis): \(value.1)")
    }
}

/// The author's avatar; hovering shows the login (DESIGN.md, "Card").
struct Avatar: View {
    var data: Data?
    var login: String
    @Environment(\.textScale) var k

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Circle().fill(Palette.avatarFill.color).overlay(Circle().stroke(Palette.avatarBorder.color, lineWidth: 1))
            }
        }
        .frame(width: 16 * k, height: 16 * k)
        .clipShape(Circle())
        .contentShape(Circle())
        .help(login)
        .accessibilityLabel(login)
    }
}

struct RowView: View {
    var row: Row
    var cardMuted: Bool
    @ObservedObject var model: SurfaceListModel
    var now: Int64
    var card: String
    @Environment(\.textScale) var k

    var body: some View {
        let p = RowPresentation(row, now: now, cardMuted: cardMuted)
        let item = SelectionItem.row(id: row.id, card: card)
        let selected = model.selection == item
        HStack(alignment: .top, spacing: 8) {
            UnreadDot(mark: p.mark)
                .padding(.top, 6 * k)
            IconView(icon: BoardIcons.row(row.kind), size: 14 * k, color: p.gray ? Palette.mutedIcon.color : Palette.botIcon.color)
                .padding(.top, 2 * k)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    SelectableText(
                        text: p.label, font: .board(11 * k, .semibold),
                        color: p.gray ? Palette.mutedText.nsColor : Palette.strongText.nsColor,
                        lineLimit: 1, coordinator: TextSelectionCoordinator.of(model)
                    ) { model.select(item) }
                    .fixedSize()
                    if let counts = p.counts {
                        Text(counts).font(.system(size: 12 * k))
                    }
                    SelectableText(
                        text: p.meta, font: .board(11 * k),
                        color: p.gray ? Palette.mutedText.nsColor : Palette.secondary.nsColor,
                        lineLimit: 1, coordinator: TextSelectionCoordinator.of(model)
                    ) { model.select(item) }
                }
                if let body = p.body {
                    SelectableText(
                        text: body, font: .board(12 * k), color: p.gray ? Palette.mutedText.nsColor : Palette.text.nsColor,
                        lineLimit: p.bodyLines, coordinator: TextSelectionCoordinator.of(model)
                    ) { model.select(item) }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            OpenIcon { model.perform(.open(row.url, read: row.id)) }
        }
        .padding(EdgeInsets(top: 5 * k, leading: 14, bottom: 6 * k, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.selection.color : Palette.surface.color)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rowDivider.color).frame(height: 1) }
        .pressable(item, model: model)
        .id(item.id)
    }
}

/// Catches the right click (and the Control click) over an item, and only
/// that: other clicks pass through to the SwiftUI views below (NSView
/// `hitTest(_:)`, which the window uses to find the view for a mouse-down).
/// The item is selected (a row read) before the menu shows.
struct RightClickArea: NSViewRepresentable {
    var menu: () -> [MenuEntry?]
    var perform: (PopoverAction) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handler = self
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handler = self
    }

    final class CatcherView: NSView {
        var handler: RightClickArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isMenuClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            show(event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show(event) } else { super.mouseDown(with: event) }
        }

        private func show(_ event: NSEvent) {
            guard let handler else { return }
            let entries = handler.menu()
            guard !entries.isEmpty else { return }
            let perform = handler.perform
            let items: [IconMenuItem?] = entries.map { entry in
                entry.map { entry in IconMenuItem(entry.title) { perform(entry.action) } }
            }
            NSMenu.popUpContextMenu(IconMenu.make(items), with: event, for: self)
        }
    }
}
