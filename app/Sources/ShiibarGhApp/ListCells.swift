// The lines of the list drawn by AppKit (docs/design/Main.html): section
// headings, cards with their rows, "+ N more PRs", the room of an empty
// section, the Dismissed cards and the text of an empty list.
//
// Why AppKit and not SwiftUI here (docs/tasks/M7.md, "Speed of operation"):
// measured in the reused table cells of ListTable.swift, SwiftUI took about
// 20 ms to make and lay out one card as it came into view, and as long again
// to measure one for its row height, so neither a scroll nor a tab switch
// could keep to 16 ms frames. Here a line's geometry is plain arithmetic on
// text widths (measured once per string and font and kept), the same
// geometry gives the row height and the frames, and a line draws itself in
// `draw(_:)`. Only the controls are views (the icon buttons, the tag,
// `Show less`, `more`/`less`, Restore).
//
// The sizes and colors are those of the SwiftUI views they replace (the
// boards' points at text size 12, times the text scale `k`).
//
// AppKit API used, as declared in the SDK headers: NSStringDrawing.h
// (`drawWithRect:options:context:` and `boundingRectWithSize:options:
// context:`; `NSStringDrawingTruncatesLastVisibleLine` "truncates and adds
// the ellipsis character to the last visible line if the text doesn't fit",
// only with `NSStringDrawingUsesLineFragmentOrigin`), NSView.h
// NSTrackingArea.h (hover, and the pointer's moves over a card for the
// tooltips of its drawn parts, which `QuickTip` shows: AppKit's
// `addToolTipRect:owner:userData:` has no setting for its delay).

import AppKit
import CoreText
import ShiibarGhCore

// MARK: - Text

/// Fonts and text sizes, measured once and kept.
@MainActor
enum Ink {
    private struct FontKey: Hashable {
        var size: CGFloat
        var weight: CGFloat
    }

    private struct TextKey: Hashable {
        var text: String
        var font: ObjectIdentifier
    }

    private struct LinesKey: Hashable {
        var text: TextKey
        var width: CGFloat
    }

    private static var fonts: [FontKey: NSFont] = [:]
    private static var widths: [TextKey: CGFloat] = [:]
    private static var lineHeights: [ObjectIdentifier: CGFloat] = [:]
    private static var lineCounts: [LinesKey: Int] = [:]

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let key = FontKey(size: size, weight: weight.rawValue)
        if let font = fonts[key] { return font }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        fonts[key] = font
        return font
    }

    /// Fonts come from `font(_:_:)`, which keeps each: the object is the
    /// key of its measurements.
    private static func key(_ font: NSFont) -> ObjectIdentifier {
        ObjectIdentifier(font)
    }

    /// The width of `text` on one line.
    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        let key = TextKey(text: text, font: key(font))
        if let width = widths[key] { return width }
        if widths.count > 20_000 { widths = [:] }
        let start = PerfMode.enabled ? CACurrentMediaTime() : 0
        defer { if PerfMode.enabled { PerfCounters.textMeasured(since: start) } }
        let size = (text as NSString).size(withAttributes: [.font: font])
        let width = (size.width * 2).rounded(.up) / 2
        widths[key] = width
        return width
    }

    private struct CharacterKey: Hashable {
        var character: Character
        var font: ObjectIdentifier
    }

    private static var advances: [CharacterKey: CGFloat] = [:]

    /// The width of `text` on one line if it was measured already.
    static func knownWidth(_ text: String, _ font: NSFont) -> CGFloat? {
        widths[TextKey(text: text, font: key(font))]
    }

    /// About the width of `text`: the sum of its characters' widths, each
    /// measured once (no kerning), for a decision far from its threshold
    /// without measuring a new text (the times change every minute).
    static func estimatedWidth(_ text: String, _ font: NSFont) -> CGFloat {
        let fontKey = key(font)
        var total: CGFloat = 0
        for character in text {
            let key = CharacterKey(character: character, font: fontKey)
            if let advance = advances[key] {
                total += advance
            } else {
                let advance = (String(character) as NSString).size(withAttributes: [.font: font]).width
                advances[key] = advance
                total += advance
            }
        }
        return total
    }

    /// The height of one line of `font`: its line fragment, rounded up to
    /// whole points as SwiftUI's `Text` was (the 0.4 list measured 14 for 11
    /// points and 15 for 12).
    static func lineHeight(_ font: NSFont) -> CGFloat {
        height(font, lines: 1)
    }

    /// The height of `lines` lines of `font`: the line fragments, with the
    /// first line at least the ascender and the descender each rounded up
    /// to whole points, as SwiftUI's `Text` measured in the 0.4 list (14 for
    /// one line of 11 points, whose line fragment is 13).
    static func height(_ font: NSFont, lines: Int) -> CGFloat {
        let fragment = fragmentHeight(font)
        let first = max(fragment, font.ascender.rounded(.up) + (-font.descender).rounded(.up))
        return (first + fragment * CGFloat(max(0, lines - 1))).rounded(.up)
    }

    private static func fragmentHeight(_ font: NSFont) -> CGFloat {
        let key = key(font)
        if let height = lineHeights[key] { return height }
        let height = ("Xg" as NSString).boundingRect(
            with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil
        ).height
        lineHeights[key] = height
        return height
    }

    /// The number of lines `text` takes at `width`, wrapped at words (as
    /// `draw(_:_:_:in:lines:)` wraps it).
    static func lines(_ text: String, _ font: NSFont, width: CGFloat) -> Int {
        let key = LinesKey(text: TextKey(text: text, font: key(font)), width: width)
        if let lines = lineCounts[key] { return lines }
        if lineCounts.count > 5_000 { lineCounts = [:] }
        let start = PerfMode.enabled ? CACurrentMediaTime() : 0
        defer { if PerfMode.enabled { PerfCounters.textMeasured(since: start) } }
        let lines = max(1, breaks(text, font, width: width).count)
        lineCounts[key] = lines
        return lines
    }

    /// Where CoreText breaks `text` into lines at `width`.
    private static func breaks(_ text: String, _ font: NSFont, width: CGFloat) -> [CFRange] {
        let string = attributed(text, font)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var ranges: [CFRange] = []
        var start = 0
        while start < string.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
            guard count > 0 else { break }
            ranges.append(CFRange(location: start, length: count))
            start += count
        }
        return ranges
    }

    private static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = .center
        return style
    }()

    private struct CutKey: Hashable {
        var text: TextKey
        var width: CGFloat
    }

    /// Typeset lines (CoreText), by text and font, and cut ones by width as
    /// well. Typesetting is most of the cost of drawing a line, and the same
    /// texts are drawn again as the list scrolls. The color is not in them:
    /// they take the context's fill color
    /// (`kCTForegroundColorFromContextAttributeName`, CTStringAttributes.h),
    /// so a line serves both appearances.
    private static var typeset: [TextKey: CTLine] = [:]
    private static var cutLines: [CutKey: CTLine] = [:]
    private static var ellipses: [ObjectIdentifier: CTLine] = [:]

    private static func attributed(_ text: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
    }

    private static func line(_ text: String, _ font: NSFont, width: CGFloat) -> CTLine {
        let key = TextKey(text: text, font: key(font))
        let full: CTLine
        if let line = typeset[key] {
            full = line
        } else {
            if typeset.count > 5_000 { typeset = [:] }
            if PerfMode.enabled { PerfCounters.frame.typeset += 1 }
            full = CTLineCreateWithAttributedString(attributed(text, font))
            typeset[key] = full
        }
        guard self.width(text, font) > width + 0.5 else { return full }
        let cutKey = CutKey(text: key, width: width)
        if let line = cutLines[cutKey] { return line }
        if cutLines.count > 5_000 { cutLines = [:] }
        let cut = CTLineCreateTruncatedLine(full, Double(max(0, width)), .end, ellipsis(font)) ?? ellipsis(font)
        cutLines[cutKey] = cut
        return cut
    }

    private struct WrapKey: Hashable {
        var text: TextKey
        var width: CGFloat
        var lines: Int
    }

    private static var wrapped: [WrapKey: [(CTLine, Range<Int>)]] = [:]

    /// `text` wrapped at `width` into at most `limit` lines, the last cut
    /// with "…" when text is left over; each line with the UTF-16 range of
    /// `text` it shows.
    private static func wrappedLines(_ text: String, _ font: NSFont, width: CGFloat, limit: Int) -> [(CTLine, Range<Int>)] {
        let key = WrapKey(text: TextKey(text: text, font: key(font)), width: width, lines: limit)
        if let lines = wrapped[key] { return lines }
        if wrapped.count > 2_000 { wrapped = [:] }
        if PerfMode.enabled { PerfCounters.frame.typeset += 1 }
        let string = attributed(text, font)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let ranges = breaks(text, font, width: width)
        var lines: [(CTLine, Range<Int>)] = []
        for (i, range) in ranges.prefix(limit).enumerated() {
            if i == limit - 1 && ranges.count > limit {
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: string.length - range.location))
                let cut = CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis(font))
                lines.append(cut.map { ($0, range.location..<shownEnd(cut: $0, from: range.location)) } ?? (rest, range.location..<string.length))
            } else {
                lines.append((CTTypesetterCreateLine(typesetter, range), range.location..<(range.location + range.length)))
            }
        }
        wrapped[key] = lines
        return lines
    }

    /// Where the text a line cut with "…" shows ends: the "…" is its last
    /// glyph run, whose string range starts at the first character it
    /// stands for (CTLineCreateTruncatedLine; checked by laying out a cut
    /// line: the runs before it keep the characters' own offsets and
    /// positions).
    private static func shownEnd(cut line: CTLine, from start: Int) -> Int {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let last = runs.last else { return start }
        return max(start, CTRunGetStringRange(last).location)
    }

    /// The lines `draw(_:_:_:in:lines:)` draws for `text` in `width`, each
    /// with the UTF-16 range of `text` it shows.
    private static func laidOut(_ text: String, _ font: NSFont, width: CGFloat, lines: Int) -> [(CTLine, Range<Int>)] {
        if lines != 1 { return wrappedLines(text, font, width: width, limit: lines) }
        let drawn = line(text, font, width: width)
        let length = (text as NSString).length
        let cut = self.width(text, font) > width + 0.5
        return [(drawn, 0..<(cut ? min(length, shownEnd(cut: drawn, from: 0)) : length))]
    }

    /// The UTF-16 offset where the text `draw(_:_:_:in:lines:)` shows of
    /// `text` ends, nil when it shows all of it.
    static func shownEnd(_ text: String, _ font: NSFont, width: CGFloat, lines: Int = 1) -> Int? {
        guard width > 0 else { return 0 }
        let end = laidOut(text, font, width: width, lines: lines).last?.1.upperBound ?? 0
        return end < (text as NSString).length ? end : nil
    }

    /// The yellow background of the search's matches (DESIGN.md, "Showing
    /// what matched") under `text` as `draw(_:_:_:in:lines:)` lays it out
    /// in `rect`: `ranges` are UTF-16 offsets of `text`; what is not shown
    /// (after a "…") gets none. Drawn before the text.
    static func drawMatches(_ text: String, _ font: NSFont, _ ranges: [Range<Int>], in rect: CGRect, lines: Int = 1) {
        guard !ranges.isEmpty, rect.width > 0 else { return }
        let fragment = fragmentHeight(font)
        var baseline = rect.minY + (lineHeight(font) - fragment) / 2 + font.ascender
        Palette.searchMatchColor.setFill()
        for (line, shown) in laidOut(text, font, width: rect.width, lines: lines) {
            for range in ranges {
                let start = max(range.lowerBound, shown.lowerBound)
                let end = min(range.upperBound, shown.upperBound)
                guard start < end else { continue }
                let x1 = CTLineGetOffsetForStringIndex(line, start, nil)
                let x2 = CTLineGetOffsetForStringIndex(line, end, nil)
                CGRect(x: rect.minX + x1, y: baseline - font.ascender, width: max(0, x2 - x1), height: font.ascender - font.descender).fill()
            }
            baseline += fragment
        }
    }

    /// The yellow background under the "…" of `text` as `draw(_:_:_:in:
    /// lines:)` lays it out in `rect` (a match is in the part it cuts off):
    /// the "…" is the cut line's last glyph run (`shownEnd(cut:from:)`).
    static func drawEllipsisMark(_ text: String, _ font: NSFont, in rect: CGRect, lines: Int = 1) {
        guard rect.width > 0 else { return }
        let laid = laidOut(text, font, width: rect.width, lines: lines)
        guard let (line, shown) = laid.last, shown.upperBound < (text as NSString).length,
              let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.last, CTRunGetGlyphCount(run) > 0 else { return }
        var origin = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &origin)
        let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
        let fragment = fragmentHeight(font)
        let baseline = rect.minY + (lineHeight(font) - fragment) / 2 + font.ascender + fragment * CGFloat(laid.count - 1)
        Palette.searchMatchColor.setFill()
        CGRect(x: rect.minX + origin.x, y: baseline - font.ascender, width: width, height: font.ascender - font.descender).fill()
    }

    /// The matches of a one-line text and the background of its "…".
    static func drawMarks(_ text: String, _ font: NSFont, _ marks: Highlight.TextMarks, in rect: CGRect) {
        drawMatches(text, font, marks.found, in: rect)
        if marks.ellipsis { drawEllipsisMark(text, font, in: rect) }
    }

    /// `drawMatches` for `drawLine(_:_:_:in:)`.
    static func drawLineMatches(_ text: String, _ font: NSFont, _ ranges: [Range<Int>], in rect: CGRect) {
        let height = lineHeight(font)
        drawMatches(text, font, ranges, in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
    }

    private static func ellipsis(_ font: NSFont) -> CTLine {
        if let line = ellipses[ObjectIdentifier(font)] { return line }
        let line = CTLineCreateWithAttributedString(attributed("\u{2026}", font))
        ellipses[ObjectIdentifier(font)] = line
        return line
    }

    /// Draws CoreText lines from the top of `rect`, one line height apart.
    private static func drawLines(_ lines: [CTLine], _ font: NSFont, _ color: NSColor, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext, NSGraphicsContext.current?.isFlipped ?? true else { return }
        let fragment = fragmentHeight(font)
        var baseline = rect.minY + (lineHeight(font) - fragment) / 2 + font.ascender
        context.saveGState()
        // The views are flipped (y down); CoreText draws y up.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setFillColor(color.cgColor)
        for line in lines {
            context.textPosition = CGPoint(x: rect.minX, y: baseline)
            CTLineDraw(line, context)
            baseline += fragment
        }
        context.restoreGState()
    }

    /// Draws `text` from the top of `rect`: one line cut with "…", or up to
    /// `lines` wrapped lines, the last cut with "…".
    static func draw(_ text: String, _ font: NSFont, _ color: NSColor, in rect: CGRect, lines: Int = 1, center: Bool = false) {
        guard rect.width > 0 else { return }
        if !center {
            let typeset = lines == 1 ? [line(text, font, width: rect.width)] : wrappedLines(text, font, width: rect.width, limit: lines).map(\.0)
            drawLines(typeset, font, color, in: rect)
            return
        }
        // Centered text (the text of an empty list): drawn by AppKit.
        let fragments = fragmentHeight(font) * CGFloat(lines)
        let top = rect.minY + (Ink.height(font, lines: lines) - fragments) / 2
        (text as NSString).draw(
            with: CGRect(x: rect.minX, y: top, width: rect.width, height: fragments + 1),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: centered], context: nil
        )
    }

    /// Draws one line of `text` centered vertically in `rect`.
    static func drawLine(_ text: String, _ font: NSFont, _ color: NSColor, in rect: CGRect) {
        let height = lineHeight(font)
        draw(text, font, color, in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
    }
}

// MARK: - Shapes

@MainActor
enum Shapes {
    static func icon(_ icon: BoardIcon, in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
        context.saveGState()
        context.addPath(IconPath.cgPath(icon, in: square, flipY: false))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(icon.lineWidth * size / 16)
        context.setLineCap(icon.roundCaps ? .round : .butt)
        context.setLineJoin(icon.roundJoins ? .round : .miter)
        context.strokePath()
        context.restoreGState()
    }

    static func rounded(_ rect: CGRect, radius: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil, lineWidth: CGFloat = 1, inset: Bool = false, dash: [CGFloat]? = nil) {
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        if let stroke {
            let r = inset ? rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2) : rect
            let path = NSBezierPath(roundedRect: r, xRadius: max(0, radius - (inset ? lineWidth / 2 : 0)), yRadius: max(0, radius - (inset ? lineWidth / 2 : 0)))
            path.lineWidth = lineWidth
            if let dash { path.setLineDash(dash, count: dash.count, phase: 0) }
            stroke.setStroke()
            path.stroke()
        }
    }

    /// The blue dot, the gray ring, or nothing (7k across).
    static func dot(_ mark: UnreadMark, in rect: CGRect) {
        switch mark {
        case .blue:
            Palette.blueDot.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .ring:
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            path.lineWidth = 1.5
            Palette.mutedText.nsColor.setStroke()
            path.stroke()
        case .none:
            break
        }
    }

    /// The status icons (DESIGN.md, "The three status icons"), 14 points
    /// scaled by `k`, centered in `rect`: a green disc with ✓, a red disc
    /// with ×, a gray clock while waiting, a light-gray dash for None.
    static func status(_ look: StatusLook, in rect: CGRect, k: CGFloat) {
        let size = 14 * k
        let box = CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
        let circle = 12.25 * k
        let disc = CGRect(x: rect.midX - circle / 2, y: rect.midY - circle / 2, width: circle, height: circle)
        switch look {
        case .ok:
            Palette.green.nsColor.setFill()
            NSBezierPath(ovalIn: disc).fill()
            icon(BoardIcons.checkMark, in: box, color: Palette.onColor.nsColor)
        case .bad:
            Palette.badge.nsColor.setFill()
            NSBezierPath(ovalIn: disc).fill()
            icon(BoardIcons.crossMark, in: box, color: Palette.onColor.nsColor)
        case .waiting:
            icon(BoardIcons.statusClock, in: box, color: Palette.statusClock.nsColor)
        case .empty:
            icon(BoardIcons.statusNone, in: box, color: Palette.statusNone.nsColor)
        }
    }

    static func stateColor(_ label: Lenient<StateLabel>) -> NSColor? {
        switch label.value {
        case .mergeable: return Palette.green.nsColor
        case .draft: return Palette.gray.nsColor
        case .merged: return Palette.purple.nsColor
        case .closed: return Palette.badge.nsColor
        default: return nil
        }
    }
}

enum StatusLook { case ok, bad, waiting, empty }

/// The state label (Main.html `.st`): text, background, text color.
struct StateStyle {
    var text: String
    var background: Shade
    var foreground: Shade

    static func of(_ label: Lenient<StateLabel>) -> StateStyle? {
        switch label.value {
        case .mergeable: return StateStyle(text: "Mergeable", background: Palette.green, foreground: Palette.onColor)
        case .draft: return StateStyle(text: "Draft", background: Palette.tint, foreground: Palette.draftText)
        case .merged: return StateStyle(text: "Merged", background: Palette.purpleBackground, foreground: Palette.purpleText)
        case .closed: return StateStyle(text: "Closed", background: Palette.orangeIconBackground, foreground: Palette.orangeText)
        case .open, nil: return nil
        }
    }
}

// MARK: - Controls

/// A control in a line: an icon with a hover background (the board's
/// `.op`), a status icon, a text button, the placement tag or Restore.
final class ListButton: NSView {
    enum Look: Equatable {
        case icon(BoardIcon, size: CGFloat, color: Shade)
        case status(StatusLook)
        /// Plain text in the settings blue (`Show less`, `more`, `less`);
        /// `marked`: on the yellow background of a search match (a `more`
        /// that hides a match of its row body).
        case text(String, size: CGFloat, marked: Bool = false)
        /// The placement tag of All (Main.html `.tag`).
        case tag(String)
        /// The board's `.btn.sm`.
        case restore
    }

    var look: Look = .text("", size: 11) { didSet { if look != oldValue { needsDisplay = true } } }
    /// Whether the line under the control draws its look when the control
    /// is idle (the icons of a card): the control then draws only while
    /// hovered, pressed or showing the check, and has no image otherwise.
    var lineDrawsIdle = false { didSet { if lineDrawsIdle != oldValue { needsDisplay = true } } }
    var k: CGFloat = 1 { didSet { if k != oldValue { needsDisplay = true } } }
    var action: () -> Void = {}
    /// The tooltip, shown by `QuickTip` (sooner than AppKit's `toolTip`).
    var help: String?
    private let tipOwner = QuickTip.Owner()
    /// The chain icon's check after a copy, until this time.
    private var flashUntil: Date? { didSet { activeChanged() } }
    private var hovering = false { didSet { activeChanged() } }
    private var pressed = false { didSet { activeChanged() } }

    /// Hovered, pressed or showing the check: the control draws its whole
    /// look itself, and the line leaves it out of its image.
    var isActive: Bool { hovering || pressed || flashUntil != nil }

    private var wasActive = false

    private func activeChanged() {
        let active = isActive
        guard active != wasActive else { return }
        wasActive = active
        needsDisplay = true
        if lineDrawsIdle { superview?.needsDisplay = true }
    }

    private var area: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        if let help { QuickTip.schedule(help, owner: tipOwner, appearance: effectiveAppearance) }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        QuickTip.cancel(owner: tipOwner)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { QuickTip.cancel(owner: tipOwner) }
    }

    override func mouseDown(with event: NSEvent) {
        QuickTip.cancel(owner: tipOwner)
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed {
            pressed = inside
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    /// The chain icon after a copy: a check for a second, and `Copied` in
    /// a small bubble next to it (DESIGN.md, "Card").
    func showCopied() {
        flashCopied(seconds: LinkCopy.checkSeconds)
        if let window {
            let rect = window.convertToScreen(convert(bounds, to: nil))
            QuickTip.bubble("Copied", beside: rect, seconds: LinkCopy.checkSeconds, appearance: effectiveAppearance)
        }
    }

    /// Shows the copied check for `seconds` (the chain icon).
    func flashCopied(seconds: TimeInterval) {
        flashUntil = Date().addingTimeInterval(seconds)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            // A later copy keeps its own second.
            guard let self, let until = self.flashUntil, until <= Date().addingTimeInterval(0.05) else { return }
            self.flashUntil = nil
            self.needsDisplay = true
        }
    }

    /// A reused view starts without the check.
    func reset() {
        QuickTip.cancel(owner: tipOwner)
        if flashUntil != nil { needsDisplay = true }
        flashUntil = nil
        pressed = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if lineDrawsIdle && !isActive {
            layer?.contents = nil
        } else {
            LayerImage.apply(self) { draw($0) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ListButton.drawLook(look, in: bounds, k: k, hovering: hovering || pressed, copied: flashUntil != nil)
    }

    /// Draws a control's look (also used by the line views, which draw
    /// their idle controls themselves).
    static func drawLook(_ look: Look, in bounds: CGRect, k: CGFloat, hovering: Bool = false, copied: Bool = false) {
        switch look {
        case .icon(let icon, let size, let color):
            if hovering { Shapes.rounded(bounds, radius: 6, fill: Palette.tint.nsColor) }
            let box = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
            if copied {
                Shapes.icon(BoardIcons.copied, in: box, color: Palette.green.nsColor)
            } else {
                Shapes.icon(icon, in: box, color: color.nsColor)
            }
        case .status(let look):
            if hovering { Shapes.rounded(bounds, radius: 6, fill: Palette.tint.nsColor) }
            Shapes.status(look, in: bounds, k: k)
        case .text(let text, let size, let marked):
            let font = Ink.font(size)
            if marked { Ink.drawLineMatches(text, font, [0..<(text as NSString).length], in: bounds) }
            Ink.drawLine(text, font, Palette.settingsTabSelected.nsColor, in: bounds)
        case .tag(let text):
            let capsule = bounds.insetBy(dx: 0.5, dy: 0.5)
            Shapes.rounded(capsule, radius: capsule.height / 2, fill: Palette.tagBackground.nsColor, stroke: Palette.tagBorder.nsColor)
            let font = Ink.font(10 * k, .semibold)
            Ink.drawLine(text, font, Palette.tagText.nsColor, in: bounds.insetBy(dx: 6 * k, dy: 0))
        case .restore:
            let box = bounds.insetBy(dx: 0.5, dy: 0.5)
            Shapes.rounded(box, radius: 6, fill: Palette.surface.nsColor, stroke: Palette.controlBorder.nsColor)
            Ink.drawLine("Restore", Ink.font(11), Palette.text.nsColor, in: bounds.insetBy(dx: 8, dy: 0))
        }
    }

    /// Sizes of the text controls.
    @MainActor static func textSize(_ text: String, size: CGFloat) -> CGSize {
        let font = Ink.font(size)
        return CGSize(width: Ink.width(text, font), height: Ink.lineHeight(font))
    }

    @MainActor static func tagSize(_ text: String, k: CGFloat) -> CGSize {
        CGSize(width: Ink.width(text, Ink.font(10 * k, .semibold)) + 12 * k, height: 14 * k)
    }

    @MainActor static var restoreSize: CGSize {
        CGSize(width: Ink.width("Restore", Ink.font(11)) + 16, height: Ink.lineHeight(Ink.font(11)) + 4)
    }
}

// MARK: - Geometry

/// Where everything of a card is, in the card's own coordinates (top left,
/// y down), for one width and text scale.
struct CardGeometry {
    struct RowFrame {
        var id: String
        var frame: CGRect
        var dot: CGRect
        var icon: CGRect
        var label: CGRect
        var counts: CGRect?
        var meta: CGRect
        var body: CGRect?
        var bodyLines: Int
        var toggle: CGRect?
        var chain: CGRect
    }

    struct FootFrame {
        var item: SelectionItem
        var text: String
        var mark: UnreadMark
        var frame: CGRect
    }

    var size: CGSize
    var header: CGRect
    var stateLabel: CGRect?
    var prLabel: CGRect
    var marks: [(String, CGRect, Bool)]
    var status: [CGRect]
    var chain: CGRect
    var dismiss: CGRect
    var avatar: CGRect
    var title: CGRect
    var tag: CGRect?
    var baseHead: CGRect
    /// The band of line 3 the times end at its right (with `Dismissed in N
    /// days` before them): on line 3, or on a line of their own.
    var timesBand: CGRect
    var line3Fits: Bool
    var rows: [RowFrame]

    /// Where the times and `Dismissed in N days` are now. Worked out when
    /// drawn, from the time, so a minute passing does not work the whole
    /// card out again (only whether line 3 wraps is part of the geometry).
    @MainActor func timeParts(_ card: Card, k: CGFloat, now: Int64) -> (dismissedIn: CGRect?, times: CGRect) {
        let f11 = Ink.font(11 * k)
        let lh11 = Ink.lineHeight(f11)
        let y = LineLayout.center(lh11, in: timesBand)
        let timesWidth = Ink.width(CardText.times(card, now: now), f11)
        let times = CGRect(x: timesBand.maxX - timesWidth, y: y, width: timesWidth, height: lh11)
        guard let text = DismissedText.dismissedIn(card.autoDismissAt, now: now) else { return (nil, times) }
        let width = Ink.width(text, f11)
        return (CGRect(x: times.minX - 8 - width, y: y, width: width, height: lh11), times)
    }
    var feet: [FootFrame]
    /// Compact: the card's unread mark at the left of line 1.
    var unreadDot: CGRect?
}

struct DismissedGeometry {
    var size: CGSize
    var stateLabel: CGRect?
    var prLabel: CGRect
    var chain: CGRect
    var avatar: CGRect
    var title: CGRect
    var daysLeft: CGRect
    var restore: CGRect
}

/// The geometry of each kind of line. A cell is the line's full width; the
/// card or band inside it has the margins of the SwiftUI views.
@MainActor
enum LineLayout {
    static func center(_ height: CGFloat, in line: CGRect) -> CGFloat {
        line.minY + (line.height - height) / 2
    }

    // MARK: Card

    static func card(_ line: CardLine, width cellWidth: CGFloat, k: CGFloat, now: Int64) -> CardGeometry {
        let card = line.card
        let width = max(80, cellWidth - (line.indented ? 24 : 12) - 12)
        let left: CGFloat = 12
        let right = width - 10
        let f11 = Ink.font(11 * k)
        let f12 = Ink.font(12 * k)
        let lh11 = Ink.lineHeight(f11)
        let lh12 = Ink.lineHeight(f12)

        // Line 1: the state label, owner/repo #number with the chain icon
        // right after it, the marks; at the right end the status icons and
        // ×.
        let state = StateStyle.of(card.stateLabel)
        let stateWidth = state.map { Ink.width($0.text, Ink.font(10 * k, .semibold)) + 12 * k }
        var marks: [(String, CGFloat, Bool)] = []
        if card.awaitingReview { marks.append((CardText.reviewRequestedMark, Ink.width(CardText.reviewRequestedMark, Ink.font(10 * k, .bold)) + 12 * k, true)) }
        if card.assignedToMe { marks.append(("Assigned", Ink.width("Assigned", Ink.font(10 * k, .semibold)) + 10 * k, false)) }
        if card.isMuted { marks.append(("Muted", Ink.width("Muted", Ink.font(10 * k, .semibold)) + 10 * k, false)) }
        let finished = card.isFinished
        let slot = 20 * k
        let op = 18 * k
        let groupWidth = finished ? 0 : 3 * slot + 2 * 2
        var line1 = max(lh11, op)
        if state != nil || card.awaitingReview { line1 = max(line1, 16 * k) }
        if !marks.isEmpty { line1 = max(line1, 14 * k) }
        if !finished { line1 = max(line1, slot) }
        let top1 = 6 * k
        let row1 = CGRect(x: 0, y: top1, width: width, height: line1)
        let dismiss = CGRect(x: right - op, y: center(op, in: row1), width: op, height: op)
        let groupRight = dismiss.minX - 12
        var status: [CGRect] = []
        if !finished {
            var x = groupRight - groupWidth
            for _ in 0..<3 {
                status.append(CGRect(x: x, y: center(slot, in: row1), width: slot, height: slot))
                x += slot + 2
            }
        }
        let rightLimit = finished ? groupRight : groupRight - groupWidth - 7
        var x = left
        // Compact: the card's unread mark first (Main.html `.l1 > .dot`).
        var unreadDot: CGRect?
        if line.compact, line.unread != .none {
            unreadDot = CGRect(x: x, y: center(7 * k, in: row1), width: 7 * k, height: 7 * k)
            x += 7 * k + 5
        }
        var stateRect: CGRect?
        if let stateWidth {
            stateRect = CGRect(x: x, y: center(16 * k, in: row1), width: stateWidth, height: 16 * k)
            x += stateWidth + 7
        }
        let marksWidth = marks.reduce(0) { $0 + $1.1 + 7 }
        let chainGap: CGFloat = 2
        let prRoom = max(0, rightLimit - marksWidth - op - chainGap - x)
        let prWidth = min(Ink.width(Warnings.prLabel(card.pr), f11), prRoom)
        let prLabel = CGRect(x: x, y: center(lh11, in: row1), width: prWidth, height: lh11)
        x += prWidth + chainGap
        let chain = CGRect(x: x, y: center(op, in: row1), width: op, height: op)
        x += op + 7
        var markRects: [(String, CGRect, Bool)] = []
        for (text, w, filled) in marks {
            let h = filled ? 16 * k : 14 * k
            markRects.append((text, CGRect(x: x, y: center(h, in: row1), width: w, height: h), filled))
            x += w + 7
        }

        // Line 2.
        let line2 = max(16 * k, lh12)
        let row2 = CGRect(x: 0, y: row1.maxY + 3 * k, width: width, height: line2)
        let avatar = CGRect(x: left, y: center(16 * k, in: row2), width: 16 * k, height: 16 * k)
        let titleX = avatar.maxX + 6
        let title = CGRect(x: titleX, y: center(lh12, in: row2), width: max(0, right - 6 - titleX), height: lh12)

        // Line 3: the times wrap to a line of their own rather than shorten.
        let tagText = line.showsTag ? card.placementTag : nil
        let tagSize = tagText.map { ListButton.tagSize($0, k: k) }
        let baseHeadWidth = Ink.width("\(card.base) \u{2190} \(card.head)", f11)
        let leftHeight = max(tagSize?.height ?? 0, lh11)
        let room3 = right - left
        let fits = line3Fits(line, width: cellWidth, k: k, now: now)
        let top3 = row2.maxY + 3 * k
        let line3: CGFloat
        let leftRow: CGRect
        let rightRow: CGRect
        if fits {
            line3 = max(leftHeight, lh11)
            leftRow = CGRect(x: left, y: top3, width: room3, height: line3)
            rightRow = CGRect(x: left, y: top3, width: room3, height: line3)
        } else {
            line3 = leftHeight + 2 + lh11
            leftRow = CGRect(x: left, y: top3, width: room3, height: leftHeight)
            rightRow = CGRect(x: left, y: top3 + leftHeight + 2, width: room3, height: lh11)
        }
        var lx = leftRow.minX
        var tag: CGRect?
        if let tagSize {
            tag = CGRect(x: lx, y: center(tagSize.height, in: leftRow), width: tagSize.width, height: tagSize.height)
            lx += tagSize.width + 6
        }
        let baseHead = CGRect(x: lx, y: center(lh11, in: leftRow), width: max(0, min(baseHeadWidth, leftRow.maxX - lx)), height: lh11)
        let headerHeight = top3 + line3 + 5 * k
        let header = CGRect(x: 0, y: 0, width: width, height: headerHeight)

        // Rows.
        var y = headerHeight
        var rows: [CardGeometry.RowFrame] = []
        let f11b = Ink.font(11 * k, .semibold)
        // Compact: no rows and no footers (DESIGN.md, "Compact").
        for row in line.compact ? [] : Listing.visibleRows(card, expanded: line.expanded) {
            let p = RowPresentation(row, now: now, cardMuted: card.isMuted, expanded: line.expandedBodies.contains(row.id))
            let rowLeft: CGFloat = 14
            let rowRight = width - 10
            let textX = rowLeft + 7 * k + 8 + 14 * k + 8
            let textWidth = max(0, rowRight - textX)
            var lineA = max(Ink.lineHeight(f11b), lh11)
            if p.counts != nil { lineA = max(lineA, lh12) }
            let labelWidth = Ink.width(p.label, f11b)
            let labelRect = CGRect(x: textX, y: 0, width: min(labelWidth, textWidth), height: lineA)
            var mx = labelRect.maxX + 6
            var countsRect: CGRect?
            if let counts = p.counts {
                let w = min(Ink.width(counts, f12), max(0, textX + textWidth - mx))
                countsRect = CGRect(x: mx, y: 0, width: w, height: lineA)
                mx += w + 6
            }
            // The chain icon follows the time (worked out when drawn, as the
            // time changes): its room is kept at the end of the line.
            let metaRect = CGRect(x: mx, y: 0, width: max(0, textX + textWidth - mx - 2 - op), height: lineA)
            var content = lineA
            var bodyRect: CGRect?
            var toggleRect: CGRect?
            var bodyLines = 0
            if let body = p.body {
                let toggleSize = ListButton.textSize(p.expanded ? "less" : "more", size: 11 * k)
                let fullLines = Ink.lines(body, f12, width: textWidth)
                let show = p.expanded || fullLines > p.collapsedLines
                let bodyWidth = show ? max(0, textWidth - toggleSize.width - 6) : textWidth
                bodyLines = min(Ink.lines(body, f12, width: bodyWidth), p.bodyLines)
                let textHeight = Ink.height(f12, lines: bodyLines)
                let toggleHeight = toggleSize.height + 1
                let bodyTop = lineA + 1
                bodyRect = CGRect(x: textX, y: bodyTop, width: bodyWidth, height: textHeight)
                if show {
                    toggleRect = CGRect(x: textX + textWidth - toggleSize.width, y: bodyTop + 1, width: toggleSize.width, height: toggleSize.height)
                }
                content = lineA + 1 + (show ? max(textHeight, toggleHeight) : textHeight)
            }
            let inner = max(6 * k + 7 * k, 2 * k + 14 * k, content, op)
            let rowHeight = 5 * k + inner + 6 * k
            let top = 5 * k
            func shift(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: y + top) }
            rows.append(CardGeometry.RowFrame(
                id: row.id,
                frame: CGRect(x: 0, y: y, width: width, height: rowHeight),
                dot: shift(CGRect(x: rowLeft, y: 6 * k, width: 7 * k, height: 7 * k)),
                icon: shift(CGRect(x: rowLeft + 7 * k + 8, y: 2 * k, width: 14 * k, height: 14 * k)),
                label: shift(labelRect), counts: countsRect.map(shift), meta: shift(metaRect),
                body: bodyRect.map(shift), bodyLines: bodyLines, toggle: toggleRect.map(shift),
                chain: shift(CGRect(x: metaRect.maxX + 2, y: (lineA - op) / 2, width: op, height: op))
            ))
            y += rowHeight
        }
        // "+ N more", `Older activity on GitHub`, `Show less`.
        var feet: [CardGeometry.FootFrame] = []
        let footHeight = 4 * k + max(7 * k, lh12) + 5 * k
        func foot(_ item: SelectionItem, _ text: String, _ mark: UnreadMark) {
            feet.append(CardGeometry.FootFrame(item: item, text: text, mark: mark, frame: CGRect(x: 0, y: y, width: width, height: footHeight)))
            y += footHeight
        }
        if !line.compact {
            if let more = Listing.moreRows(card, expanded: line.expanded) {
                foot(.moreRows(card: card.id), Listing.moreRowsText(more), Listing.moreRowsMark(card))
            }
            if Listing.showsOlderActivity(card, expanded: line.expanded) {
                foot(.olderActivity(card: card.id), "Older activity on GitHub", .none)
            }
            if Listing.showsLessRows(card, expanded: line.expanded) {
                foot(.lessRows(card: card.id), "Show less", .none)
            }
        }
        return CardGeometry(
            size: CGSize(width: width, height: y), header: header, stateLabel: stateRect, prLabel: prLabel,
            marks: markRects, status: status, chain: chain, dismiss: dismiss, avatar: avatar, title: title, tag: tag,
            baseHead: baseHead, timesBand: rightRow, line3Fits: fits, rows: rows, feet: feet, unreadDot: unreadDot
        )
    }

    /// Whether line 3 of a card holds its left part and the times (else the
    /// times go to a line of their own).
    static func line3Fits(_ line: CardLine, width cellWidth: CGFloat, k: CGFloat, now: Int64) -> Bool {
        let card = line.card
        let f11 = Ink.font(11 * k)
        let width = max(80, cellWidth - (line.indented ? 24 : 12) - 12)
        let room = width - 10 - 12
        let tag = (line.showsTag ? card.placementTag : nil).map { ListButton.tagSize($0, k: k).width + 6 } ?? 0
        let left = tag + Ink.width("\(card.base) \u{2190} \(card.head)", f11)
        let dismissedText = DismissedText.dismissedIn(card.autoDismissAt, now: now)
        let timesText = CardText.times(card, now: now)
        // The times change every minute, for every card: measured exactly
        // only when the answer is close (a new text measured costs about
        // 0.1 ms, and a minute passing measured about a hundred of them in
        // one frame of a scroll).
        func measure(_ exact: Bool) -> CGFloat {
            let width = { (text: String) in
                exact ? Ink.width(text, f11) : (Ink.knownWidth(text, f11) ?? Ink.estimatedWidth(text, f11))
            }
            return left + 8 + (dismissedText.map { width($0) + 8 } ?? 0) + width(timesText)
        }
        let estimate = measure(false)
        if abs(estimate - room) > 8 { return estimate <= room }
        return measure(true) <= room
    }

    // MARK: Dismissed card

    static func dismissed(_ card: Card, width cellWidth: CGFloat, k: CGFloat, now: Int64) -> DismissedGeometry {
        let width = max(80, cellWidth - 24)
        let left: CGFloat = 12
        let right = width - 10
        let f11 = Ink.font(11 * k)
        let lh11 = Ink.lineHeight(f11)
        let lh12 = Ink.lineHeight(Ink.font(12 * k))
        let op = 18 * k
        let state = StateStyle.of(card.stateLabel)
        let line1 = max(lh11, op, state == nil ? 0 : 16 * k)
        let row1 = CGRect(x: 0, y: 6 * k, width: width, height: line1)
        var x = left
        var stateRect: CGRect?
        if let state {
            let w = Ink.width(state.text, Ink.font(10 * k, .semibold)) + 12 * k
            stateRect = CGRect(x: x, y: center(16 * k, in: row1), width: w, height: 16 * k)
            x += w + 7
        }
        let prLabel = CGRect(x: x, y: center(lh11, in: row1), width: max(0, min(Ink.width(Warnings.prLabel(card.pr), f11), right - op - 2 - x)), height: lh11)
        // The chain icon right after owner/repo #number.
        let chain = CGRect(x: prLabel.maxX + 2, y: center(op, in: row1), width: op, height: op)
        let row2 = CGRect(x: 0, y: row1.maxY + 3 * k, width: width, height: max(16 * k, lh12))
        let avatar = CGRect(x: left, y: center(16 * k, in: row2), width: 16 * k, height: 16 * k)
        let title = CGRect(x: avatar.maxX + 6, y: center(lh12, in: row2), width: max(0, right - 6 - avatar.maxX - 6), height: lh12)
        let restoreSize = ListButton.restoreSize
        let row3 = CGRect(x: 0, y: row2.maxY + 3 * k, width: width, height: max(lh11, restoreSize.height))
        let restore = CGRect(x: right - restoreSize.width, y: center(restoreSize.height, in: row3), width: restoreSize.width, height: restoreSize.height)
        let daysWidth = Ink.width(DismissedText.daysLeft(card.dismissExpiresAt, now: now), f11)
        let daysLeft = CGRect(x: restore.minX - 8 - daysWidth, y: center(lh11, in: row3), width: daysWidth, height: lh11)
        return DismissedGeometry(
            size: CGSize(width: width, height: row3.maxY + 5 * k), stateLabel: stateRect, prLabel: prLabel, chain: chain,
            avatar: avatar, title: title, daysLeft: daysLeft, restore: restore
        )
    }

    // MARK: Other lines

    /// A band heading (level 1) or a small one (level 2): the press frame
    /// in the cell and the cell's height.
    static func heading(_ heading: HeadingLine, width: CGFloat, k: CGFloat) -> (frame: CGRect, height: CGFloat) {
        if heading.level == 1 {
            let inner = max(Ink.lineHeight(Ink.font(12 * k, .semibold)), Ink.lineHeight(Ink.font(11 * k)), 14 * k)
            let band = CGRect(x: 12, y: 8, width: max(0, width - 24), height: 4 * k + inner + 4 * k)
            return (band, band.maxY + 6)
        }
        let inner = max(Ink.lineHeight(Ink.font(11 * k, .semibold)), Ink.lineHeight(Ink.font(11 * k)), 14 * k)
        let band = CGRect(x: 12, y: 2, width: max(0, width - 24), height: 2 * k + inner + 2 * k)
        return (band, band.maxY + 4)
    }

    static func fold(width: CGFloat, k: CGFloat) -> (frame: CGRect, height: CGFloat) {
        let inner = max(7 * k, Ink.lineHeight(Ink.font(12 * k)))
        let frame = CGRect(x: 12, y: 0, width: max(0, width - 24), height: 2 * k + inner + 2 * k)
        return (frame, frame.maxY + 8)
    }

    static func empty(width: CGFloat, k: CGFloat) -> (frame: CGRect, height: CGFloat) {
        let frame = CGRect(x: 12, y: 0, width: max(0, width - 24), height: 30 * k)
        return (frame, frame.maxY + 8)
    }

    static func message(_ text: String, width: CGFloat, k: CGFloat) -> CGFloat {
        let font = Ink.font(12 * k)
        let lines = Ink.lines(text, font, width: max(1, width - 24))
        return 18 * k + Ink.height(font, lines: lines) + 22 * k
    }
}

// MARK: - Layer contents

/// Draws a view's whole content into one image for its layer.
///
/// AppKit draws a layer-backed view in a scroll view only in the part that
/// is visible, and again for each part that scrolls into view: a card
/// scrolling in 25 points a frame was drawn eight times or more, each time
/// with the cost of replaying the drawing into the layer. A line view gives
/// its layer an image of all of it instead (NSView.h, `wantsUpdateLayer`
/// and `updateLayer`: "it is faster to directly set the layer.contents"),
/// drawn once when the line is configured or its state changes.
/// A value of any equatable type, compared with another of the same type.
struct AnyEquatable: Equatable {
    private let value: Any
    private let equals: (Any) -> Bool

    init<T: Equatable>(_ value: T) {
        self.value = value
        equals = { ($0 as? T) == value }
    }

    static func == (lhs: AnyEquatable, rhs: AnyEquatable) -> Bool {
        lhs.equals(rhs.value)
    }
}

@MainActor
enum LayerImage {
    static func render(_ view: NSView, draw: (CGRect) -> Void) -> CGImage? {
        let size = view.bounds.size
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let space = view.window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        // Points, y down, as the flipped view draws.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            draw(CGRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func apply(_ view: NSView, draw: (CGRect) -> Void) {
        guard let layer = view.layer else { return }
        let start = PerfMode.enabled ? CACurrentMediaTime() : 0
        layer.contents = render(view, draw: draw)
        if PerfMode.enabled {
            PerfCounters.frame.images += 1
            PerfCounters.frame.imageMs += PerfCounters.since(start)
            if view is CardLineView { PerfCounters.frame.cardImages += 1 }
        }
        layer.contentsScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // The image stays at the view's top edge while the layer's height
        // differs from the image's (a card's height animation). The views
        // are flipped (`contentsAreFlipped`), where Core Animation's
        // "bottom" is the edge seen at the top (the measurement mode's
        // check "card image at the top").
        layer.contentsGravity = .bottomLeft
    }
}

// MARK: - Line views

/// What a line view needs from the list.
@MainActor
struct LineEnvironment {
    var k: CGFloat
    var now: Int64
    var autoDismissDays: Int64
    var context: CardContext
}

/// The base of the line views: a press view (CardInput.swift) bound to one
/// item state, drawn again when the state changes.
class LineView: PressView {
    private(set) weak var state: ItemState?
    var env: LineEnvironment?
    /// The control views, by their control id.
    private var controls: [String: ListButton] = [:]
    private var used: Set<String> = []

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    /// The card's own shape, drawn by its layer (a rounded rectangle in the
    /// surface color with a 1-point border), not in its image: filling and
    /// stroking a rounded shape was most of the cost of drawing a card.
    var cardShape = false


    /// Everything the layer's image was drawn from (`DrawKey`). AppKit asks
    /// a line in a scroll view to display again for each part that scrolls
    /// into view: when nothing the drawing reads has changed, the image,
    /// drawn whole, is kept. Drawing it again each time was what made a
    /// scroll frame slow (the measurement mode's slow frames had four or
    /// five card images, 12 to 14 ms, drawn again for cards drawn frames
    /// before). The key is compared when AppKit asks, so no change can be
    /// missed. A flag set from `needsDisplay` (the first version of this)
    /// missed the changes made while the table reuses a line, outside the
    /// window: a heading configured from Todo to Waiting there recorded no
    /// `needsDisplay`, and its Todo image was kept (the measurement mode's
    /// trace; cards of another repository appeared under a heading).
    private(set) var drawnKey: DrawKey?

    /// What the drawing of this line reads, besides the item state, the
    /// size, the scale, the appearance and the controls' idle looks (which
    /// every line's key has). nil: drawn every time.
    func drawInputs() -> AnyEquatable? { nil }

    struct DrawKey: Equatable {
        var content: AnyEquatable?
        var state: ItemSnapshot
        var size: CGSize
        var scale: CGFloat
        var appearance: String
        var idleControls: [ControlLook]
    }

    struct ControlLook: Equatable {
        var look: ListButton.Look
        var frame: CGRect
    }

    /// The key of the image the line would draw now.
    func currentDrawKey() -> DrawKey {
        DrawKey(
            content: drawInputs(), state: snapshot, size: bounds.size, scale: window?.backingScaleFactor ?? 0,
            appearance: effectiveAppearance.name.rawValue,
            idleControls: controls.sorted { $0.key < $1.key }.compactMap { _, button in
                !button.isHidden && button.lineDrawsIdle && !button.isActive ? ControlLook(look: button.look, frame: button.frame) : nil
            }
        )
    }

    /// The line's image drawn now (also the measurement mode's check, which
    /// compares it with the layer's).
    func renderImage() -> CGImage? {
        LayerImage.render(self) { rect in
            draw(rect)
            // The idle icons of the controls (ListButton, `lineDrawsIdle`).
            for button in controls.values where !button.isHidden && button.lineDrawsIdle && !button.isActive {
                ListButton.drawLook(button.look, in: button.frame, k: env?.k ?? 1)
            }
        }
    }


    override func updateLayer() {
        if cardShape, let layer {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer.backgroundColor = Palette.surface.nsColor.cgColor
                layer.borderColor = Palette.border.nsColor.cgColor
            }
            layer.cornerRadius = 10
            layer.borderWidth = 1
            layer.masksToBounds = true
        }
        let key = currentDrawKey()
        if key.content != nil, key == drawnKey, layer?.contents != nil { return }
        drawnKey = key
        LayerImage.apply(self) { rect in
            draw(rect)
            // The idle icons of the controls (ListButton, `lineDrawsIdle`).
            for button in controls.values where !button.isHidden && button.lineDrawsIdle && !button.isActive {
                ListButton.drawLook(button.look, in: button.frame, k: env?.k ?? 1)
            }
        }
    }

    func bind(_ state: ItemState?) {
        if self.state !== state {
            if let old = self.state, old.view === self { old.view = nil }
            self.state = state
        }
        state?.view = self
    }

    /// The item state changed: selected, one of several selected, dragged,
    /// under a drag.
    func stateChanged() {
        needsDisplay = true
        needsLayout = true
    }

    /// The item started or stopped fading (a card `Unread only` kept).
    func fadingChanged() {}

    var snapshot: ItemSnapshot {
        guard let state else { return .none }
        return ItemSnapshot(state)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A display of another scale: the image is drawn again for it.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// The layer's image is the view's size (it is not redrawn on resize
    /// by itself, `wantsUpdateLayer`).
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    // MARK: Controls

    /// Starts a configuration: the controls not asked for again are hidden.
    func beginControls() {
        used = []
        regions.controls = [:]
    }

    @discardableResult
    func control(_ id: String, _ look: ListButton.Look, frame: CGRect, help: String?, label: String?, action: @escaping () -> Void) -> ListButton {
        let button: ListButton
        if let existing = controls[id] {
            button = existing
        } else {
            button = ListButton(frame: frame)
            addSubview(button)
            controls[id] = button
        }
        if button.isHidden { button.isHidden = false }
        if button.frame != frame { button.frame = frame }
        button.look = look
        button.k = env?.k ?? 1
        switch look {
        case .icon, .status: button.lineDrawsIdle = true
        default: button.lineDrawsIdle = false
        }
        button.action = action
        button.help = help
        button.setAccessibilityHelp(help)
        button.setAccessibilityLabel(label ?? help)
        used.insert(id)
        regions.controls[id] = frame
        return button
    }

    func endControls() {
        for (id, button) in controls where !used.contains(id) {
            if !button.isHidden {
                button.isHidden = true
                button.reset()
            }
        }
    }

    func button(_ id: String) -> ListButton? {
        controls[id]
    }

    // MARK: Tooltips of the drawn parts

    /// Whether the line has tooltips over parts it draws (the avatar, the
    /// times): only then does it follow the pointer.
    var hasTips: Bool { false }

    /// The tooltip over `point`, nil where there is none.
    func tip(at point: CGPoint) -> String? { nil }

    private var tipArea: NSTrackingArea?
    private let tipOwner = QuickTip.Owner()
    /// The tooltip asked for under the pointer now.
    private var tipAsked: String?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hasTips else { return }
        if PerfMode.enabled { PerfCounters.frame.tracking += 1 }
        if let tipArea { removeTrackingArea(tipArea) }
        // `inVisibleRect`: the area follows the visible part by itself, so
        // a scroll does not make new ones.
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tipArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        followTip(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        followTip(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideTip()
    }

    private func followTip(_ event: NSEvent) {
        let text = tip(at: convert(event.locationInWindow, from: nil))
        guard text != tipAsked else { return }
        tipAsked = text
        if let text {
            QuickTip.schedule(text, owner: tipOwner, appearance: effectiveAppearance)
        } else {
            QuickTip.cancel(owner: tipOwner)
        }
    }

    /// Hides this line's tooltip (the pointer left, or the view shows
    /// another line or leaves the window).
    func hideTip() {
        tipAsked = nil
        QuickTip.cancel(owner: tipOwner)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideTip() }
    }

    /// Forgets the state of the controls of the line this view showed
    /// before (the chain icon's check).
    func resetControls() {
        for button in controls.values { button.reset() }
    }
}

/// A section heading: a band (Main.html `.band`) or a small indented
/// heading (`.grp2`). Pressing it folds the section.
final class HeadingLineView: LineView {
    var heading: HeadingLine?

    private struct Inputs: Equatable {
        var heading: HeadingLine?
        var k: CGFloat
    }

    override func drawInputs() -> AnyEquatable? {
        AnyEquatable(Inputs(heading: heading, k: env?.k ?? 1))
    }

    func configure(_ heading: HeadingLine, env: LineEnvironment, state: ItemState) {
        let changed = self.heading != heading
        self.heading = heading
        self.env = env
        kind = .heading(heading.key)
        context = env.context
        bind(state)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(heading.title), \(heading.detail)")
        setAccessibilityValue(heading.collapsed ? "Collapsed" : "Expanded")
        layoutControls()
        if changed { needsDisplay = true }
    }

    private var k: CGFloat { env?.k ?? 1 }

    private var chevronIcon: BoardIcon {
        heading?.collapsed == true ? BoardIcons.sectionClosed : BoardIcons.sectionOpen
    }

    private struct Parts {
        var chevron: CGRect
        var title: CGRect
        var showLess: CGRect?
        var detail: CGRect
    }

    private func parts() -> Parts? {
        guard let heading else { return nil }
        let level1 = heading.level == 1
        let titleFont = Ink.font((level1 ? 12 : 11) * k, .semibold)
        let detailFont = Ink.font(11 * k)
        let left: CGFloat = level1 ? 10 : 22
        let right = bounds.width - 8
        let spacing: CGFloat = level1 ? 8 : 6
        let line = CGRect(x: 0, y: (level1 ? 4 : 2) * k, width: bounds.width, height: bounds.height - (level1 ? 8 : 4) * k)
        let chevronSize = 14 * k
        let detailWidth = Ink.width(heading.detail, detailFont)
        let lessSize = heading.showLess ? ListButton.textSize("Show less", size: 11 * k) : nil
        if level1 {
            let chevron = CGRect(x: right - chevronSize, y: LineLayout.center(chevronSize, in: line), width: chevronSize, height: chevronSize)
            let detail = CGRect(x: chevron.minX - spacing - detailWidth, y: LineLayout.center(Ink.lineHeight(detailFont), in: line), width: detailWidth, height: Ink.lineHeight(detailFont))
            var titleRight = detail.minX - spacing
            var less: CGRect?
            if let lessSize {
                less = CGRect(x: titleRight - lessSize.width, y: LineLayout.center(lessSize.height, in: line), width: lessSize.width, height: lessSize.height)
                titleRight = less!.minX - spacing
            }
            let title = CGRect(x: left, y: LineLayout.center(Ink.lineHeight(titleFont), in: line), width: max(0, titleRight - left), height: Ink.lineHeight(titleFont))
            return Parts(chevron: chevron, title: title, showLess: less, detail: detail)
        }
        let chevron = CGRect(x: left, y: LineLayout.center(chevronSize, in: line), width: chevronSize, height: chevronSize)
        let detail = CGRect(x: right - detailWidth, y: LineLayout.center(Ink.lineHeight(detailFont), in: line), width: detailWidth, height: Ink.lineHeight(detailFont))
        var titleRight = detail.minX - spacing
        var less: CGRect?
        if let lessSize {
            less = CGRect(x: titleRight - lessSize.width, y: LineLayout.center(lessSize.height, in: line), width: lessSize.width, height: lessSize.height)
            titleRight = less!.minX - spacing
        }
        let titleX = chevron.maxX + spacing
        let title = CGRect(x: titleX, y: LineLayout.center(Ink.lineHeight(titleFont), in: line), width: max(0, titleRight - titleX), height: Ink.lineHeight(titleFont))
        return Parts(chevron: chevron, title: title, showLess: less, detail: detail)
    }

    private func layoutControls() {
        beginControls()
        if let heading, let less = parts()?.showLess {
            let key = heading.key
            control("show-less", .text("Show less", size: 11 * k), frame: less, help: nil, label: "Show less") { [weak self] in
                self?.context?.list.perform(.toggleMore(key))
            }
        }
        endControls()
    }

    override func layout() {
        super.layout()
        layoutControls()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let heading, let parts = parts() else { return }
        let state = snapshot
        let highlighted = state.selected != nil || state.over
        if heading.level == 1 {
            Shapes.rounded(bounds, radius: 6, fill: highlighted ? Palette.selection.nsColor : Palette.band.nsColor)
            if state.over { Shapes.rounded(bounds.insetBy(dx: 1, dy: 1), radius: 6, stroke: Palette.blueDot.nsColor, lineWidth: 2) }
            Ink.draw(heading.title, Ink.font(12 * k, .semibold), heading.collapsed ? Palette.secondary.nsColor : Palette.text.nsColor, in: parts.title)
            Ink.draw(heading.detail, Ink.font(11 * k), Palette.secondary.nsColor, in: parts.detail)
        } else {
            if highlighted { Shapes.rounded(bounds, radius: 6, fill: Palette.selection.nsColor) }
            Ink.draw(heading.title, Ink.font(11 * k, .semibold), Palette.strongText.nsColor, in: parts.title)
            Ink.draw(heading.detail, Ink.font(11 * k), Palette.waiting.nsColor, in: parts.detail)
        }
        let icon = CGRect(x: parts.chevron.midX - 6 * k, y: parts.chevron.midY - 6 * k, width: 12 * k, height: 12 * k)
        Shapes.icon(chevronIcon, in: icon, color: Palette.faded.nsColor)
    }
}

/// "+ 2 more PRs" or "Show less" of a section (Main.html `.more`).
final class FoldLineView: LineView {
    var fold: FoldValues?

    private struct Inputs: Equatable {
        var fold: FoldValues?
        var k: CGFloat
    }

    override func drawInputs() -> AnyEquatable? {
        AnyEquatable(Inputs(fold: fold, k: env?.k ?? 1))
    }

    func configure(_ fold: FoldValues, env: LineEnvironment, state: ItemState) {
        if self.fold != fold { needsDisplay = true }
        self.fold = fold
        self.env = env
        kind = .fold(fold.key)
        context = env.context
        bind(state)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(fold.text)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fold else { return }
        let k = env?.k ?? 1
        if snapshot.selected != nil { Shapes.rounded(bounds, radius: 6, fill: Palette.selection.nsColor) }
        let line = CGRect(x: 0, y: 2 * k, width: bounds.width, height: bounds.height - 4 * k)
        Shapes.dot(fold.mark, in: CGRect(x: 16, y: LineLayout.center(7 * k, in: line), width: 7 * k, height: 7 * k))
        let x = 16 + 7 * k + 8
        Ink.drawLine(fold.text, Ink.font(12 * k), Palette.secondary.nsColor, in: CGRect(x: x, y: line.minY, width: max(0, bounds.width - 12 - x), height: line.height))
    }
}

/// The room under the heading of an empty Review or Mine section: where a
/// dragged card lands.
final class EmptyLineView: LineView {
    override func drawInputs() -> AnyEquatable? {
        AnyEquatable(env?.k ?? 1)
    }

    func configure(_ key: String, env: LineEnvironment, state: ItemState) {
        self.env = env
        kind = .empty(key)
        context = env.context
        bind(state)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let k = env?.k ?? 1
        let over = snapshot.over
        let box = bounds
        if over { Shapes.rounded(box, radius: 10, fill: Palette.selection.nsColor) }
        Shapes.rounded(
            box, radius: 10, stroke: over ? Palette.blueDot.nsColor : Palette.border.nsColor, lineWidth: over ? 2 : 1, inset: true, dash: [4, 3]
        )
        let font = Ink.font(11 * k)
        let width = Ink.width("No pull requests", font)
        Ink.drawLine("No pull requests", font, Palette.faded.nsColor, in: CGRect(x: box.midX - width / 2, y: box.minY, width: width + 1, height: box.height))
    }
}

/// A card (Main.html `.card`): the heading lines, the rows and the lines
/// under them.
final class CardLineView: LineView {
    private(set) var line: CardLine?
    private var geometry: CardGeometry?
    /// What the search matched in the card (DESIGN.md, "Showing what
    /// matched"), worked out from `line` and the geometry when configured;
    /// nil without search text.
    private var matches: Highlight.CardMarks?

    /// The marks of `line` laid out in `geometry`: the texts cut with "…"
    /// are measured as they are drawn.
    static func marks(_ line: CardLine, _ geometry: CardGeometry, k: CGFloat, now: Int64) -> Highlight.CardMarks {
        let f11 = Ink.font(11 * k)
        let titleFont = Ink.font(12 * k, line.card.isMuted ? .regular : .semibold)
        return Highlight.card(
            line.card, words: line.search, now: now, expanded: line.expanded, expandedBodies: line.expandedBodies, compact: line.compact
        ) { cut, text in
            switch cut {
            case .prLabel: return Ink.shownEnd(text, f11, width: geometry.prLabel.width)
            case .title: return Ink.shownEnd(text, titleFont, width: geometry.title.width)
            case .baseHead: return Ink.shownEnd(text, f11, width: geometry.baseHead.width)
            case .body(let id):
                guard let frame = geometry.rows.first(where: { $0.id == id }), let rect = frame.body, frame.bodyLines > 0 else { return 0 }
                return Ink.shownEnd(text, Ink.font(12 * k), width: rect.width, lines: frame.bodyLines)
            }
        }
    }

    private struct Inputs: Equatable {
        var line: CardLine?
        var size: CGSize?
        var line3Fits: Bool?
        var k: CGFloat
        var now: Int64
        var avatar: Bool
    }

    override func drawInputs() -> AnyEquatable? {
        let url = line?.card.authorAvatarUrl
        return AnyEquatable(Inputs(
            line: line, size: geometry?.size, line3Fits: geometry?.line3Fits, k: env?.k ?? 1, now: env?.now ?? 0,
            avatar: env?.context.avatars.image(for: url) != nil
        ))
    }

    func configure(_ line: CardLine, geometry: CardGeometry, env: LineEnvironment, state: ItemState) {
        PerfCounters.row()
        cardShape = true
        if self.line?.card.id != line.card.id {
            resetControls()
            hideTip()
        }
        self.line = line
        self.geometry = geometry
        self.env = env
        matches = line.search.isEmpty ? nil : Self.marks(line, geometry, k: env.k, now: env.now)
        kind = .card(line.card, section: line.section, canDrag: line.canDrag)
        context = env.context
        bind(state)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(Warnings.prLabel(line.card.pr)), \(line.card.title)")
        setAccessibilityValue(line.card.isMuted ? "Muted" : nil)
        env.context.avatars.request(line.card.authorAvatarUrl)
        layoutContent()
        needsDisplay = true
    }

    private var k: CGFloat { env?.k ?? 1 }

    private func layoutContent() {
        guard let line, let geometry, let env else { return }
        let card = line.card
        let list = env.context.list
        // The rows and the lines under them, for the press view.
        regions.items = [:]
        for row in geometry.rows { regions.items[.row(row.id)] = row.frame }
        for foot in geometry.feet { regions.items[.footer(foot.item)] = foot.frame }

        beginControls()
        let id = card.id
        if !card.isFinished {
            let slots: [(String, StatusLook, String, String)] = [
                ("Review", reviewLook(card).0, reviewLook(card).1, card.links.review),
                ("Checks", checksLook(card).0, checksLook(card).1, card.links.checks),
                ("Base", baseLook(card).0, baseLook(card).1, card.links.base),
            ]
            for (i, (axis, look, text, url)) in slots.enumerated() where i < geometry.status.count {
                control("status-" + axis, .status(look), frame: geometry.status[i], help: "\(axis): \(text)", label: "\(axis): \(text)") { [weak list] in
                    list?.perform(.open(url, read: nil))
                }
            }
        }
        chainControl("chain", url: card.url, frame: geometry.chain)
        control("dismiss", .icon(BoardIcons.dismiss, size: 12 * k, color: Palette.faded), frame: geometry.dismiss, help: "Dismiss", label: "Dismiss") { [weak list] in
            list?.perform(.confirmDismiss(card: id))
        }
        if let tag = geometry.tag, let text = card.placementTag {
            control("tag", .tag(text), frame: tag, help: "Open in its tab", label: text) { [weak list] in
                list?.perform(.showInTab(card: id))
            }
        }
        // The controls of the rows go by the row's place in the card, so a
        // reused view keeps its buttons.
        for (i, row) in geometry.rows.enumerated() {
            let data = card.rows.first { $0.id == row.id }
            chainControl("chain:\(i)", url: data?.url ?? card.url, frame: rowChain(row, data, card: card, env: env))
            if let toggle = row.toggle {
                let expanded = line.expandedBodies.contains(row.id)
                let rowId = row.id
                // `more` hiding a match of the body.
                let marked = !expanded && matches?.rows[row.id]?.more == true
                control("body:\(i)", .text(expanded ? "less" : "more", size: 11 * k, marked: marked), frame: toggle, help: nil, label: expanded ? "less" : "more") { [weak list] in
                    list?.perform(.toggleBody(row: rowId))
                }
            }
        }
        endControls()
        updateAlpha(animated: false)
    }

    /// Dragged: faint. A card `Unread only` kept, in its last 0.3 seconds:
    /// it fades (Main.html `.card.fade`, 0.4). The opacity is the view's,
    /// not part of its image (`DrawKey`), so the image stays the one the
    /// card draws.
    private func updateAlpha(animated: Bool) {
        let alpha: CGFloat = snapshot.dragged ? 0.35 : (state?.fading == true ? Self.fadedAlpha : 1)
        guard alphaValue != alpha else { return }
        if animated && alpha == Self.fadedAlpha {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = UnreadLinger.fade
                animator().alphaValue = alpha
            }
        } else {
            alphaValue = alpha
        }
    }

    static let fadedAlpha: CGFloat = 0.4

    override func fadingChanged() {
        updateAlpha(animated: true)
    }

    // MARK: Accessibility

    /// The card's heading and each row and line under them as their own
    /// elements, with their texts: made only when an assistive app asks
    /// for the card's children.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard let line, let geometry, let env else { return children }
        for (role, text, rect) in Self.accessibilityParts(line, geometry, now: env.now) {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(role)
            element.setAccessibilityLabel(text)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect)
            children.append(element)
        }
        return children
    }

    /// The texts of a card's parts, in order: the heading, the rows, the
    /// lines under them (role, text, frame in the card).
    static func accessibilityParts(_ line: CardLine, _ geometry: CardGeometry, now: Int64) -> [(NSAccessibility.Role, String, CGRect)] {
        let card = line.card
        var heading: [String] = []
        if geometry.unreadDot != nil { heading.append("Unread") }
        if let state = StateStyle.of(card.stateLabel) { heading.append(state.text) }
        heading.append(Warnings.prLabel(card.pr))
        heading += geometry.marks.map(\.0)
        heading.append(card.title)
        if line.showsTag, let tag = card.placementTag { heading.append(tag) }
        heading.append("\(card.base) \u{2190} \(card.head)")
        if let text = DismissedText.dismissedIn(card.autoDismissAt, now: now) { heading.append(text) }
        heading.append(CardText.times(card, now: now))
        var parts: [(NSAccessibility.Role, String, CGRect)] = [(.group, heading.joined(separator: ", "), geometry.header)]
        for frame in geometry.rows {
            guard let row = card.rows.first(where: { $0.id == frame.id }) else { continue }
            let p = RowPresentation(row, now: now, cardMuted: card.isMuted, expanded: line.expandedBodies.contains(row.id))
            var text = [p.label]
            if let counts = p.counts { text.append(counts) }
            text.append(p.meta)
            if let body = p.body { text.append(body) }
            if p.mark != .none { text.append(p.mark == .blue ? "Unread" : "Unread, muted") }
            parts.append((.group, text.joined(separator: ", "), frame.frame))
        }
        for foot in geometry.feet {
            parts.append((.button, foot.text, foot.frame))
        }
        return parts
    }

    private func chainControl(_ id: String, url: String, frame: CGRect) {
        let list = env?.context.list
        let button = control(id, .icon(BoardIcons.link, size: 12 * k, color: Palette.faded), frame: frame, help: "Copy link", label: "Copy link") {}
        button.action = { [weak list, weak button] in
            list?.perform(.copyLink(url))
            button?.showCopied()
        }
    }

    /// A row's chain icon: right after its time (the end of the meta text,
    /// which changes with the time).
    private func rowChain(_ frame: CardGeometry.RowFrame, _ row: Row?, card: Card, env: LineEnvironment) -> CGRect {
        guard let row else { return frame.chain }
        let p = RowPresentation(row, now: env.now, cardMuted: card.isMuted, expanded: line?.expandedBodies.contains(row.id) == true)
        let width = min(Ink.width(p.meta, Ink.font(11 * env.k)), frame.meta.width)
        var rect = frame.chain
        rect.origin.x = frame.meta.minX + width + 2
        return rect
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override var hasTips: Bool { true }

    /// The avatar: the author; `Dismissed in N days`: when and why; the
    /// times: the exact times.
    override func tip(at point: CGPoint) -> String? {
        guard let line, let geometry, let env else { return nil }
        if geometry.avatar.contains(point) { return line.card.author }
        let parts = geometry.timeParts(line.card, k: env.k, now: env.now)
        if let rect = parts.dismissedIn, rect.contains(point) {
            return DismissedText.dismissedInHelp(autoDismissDays: env.autoDismissDays, inDone: line.card.placement?.isDone == true)
        }
        if parts.times.contains(point) { return CardText.exactTimes(line.card) }
        return nil
    }

    private func reviewLook(_ card: Card) -> (StatusLook, String) {
        switch card.review.value {
        case .approved: return (.ok, "Approved")
        case .reviewRequired: return (.waiting, "Review required")
        case .changesRequested: return (.bad, "Changes requested")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    private func checksLook(_ card: Card) -> (StatusLook, String) {
        switch card.checks.value {
        case .passed: return (.ok, "Passed")
        case .inProgress: return (.waiting, "In progress")
        case .failed: return (.bad, "Failed")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    private func baseLook(_ card: Card) -> (StatusLook, String) {
        switch card.baseStatus.value {
        case .upToDate: return (.ok, "Up to date")
        case .behind: return (.waiting, "Behind")
        case .conflicts: return (.bad, "Conflicts")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let geometry, let env else { return }
        let _ = PerfCounters.card()
        // AppKit draws a line in parts as it scrolls into view (the part
        // that has become visible): only what meets `dirtyRect` is drawn.
        let dirty = dirtyRect.insetBy(dx: -1, dy: -1)
        let card = line.card
        let k = env.k
        let now = env.now
        let state = snapshot
        let muted = card.isMuted
        // The rounded corners and the border are the layer's
        // (`cardShape`); a plain fill under the text keeps the text drawn
        // as on an opaque card.
        Palette.surface.nsColor.setFill()
        bounds.intersection(dirty).fill()
        // The selected heading, or one of several selected cards.
        if state.selected == .header(card: card.id) || state.marked {
            Palette.selection.nsColor.setFill()
            geometry.header.intersection(dirty).fill()
        }
        if geometry.header.intersects(dirty) {
            if let rect = geometry.unreadDot { Shapes.dot(line.unread, in: rect) }
            drawHeader(card, geometry, k: k, now: now, muted: muted)
        }

        // Rows.
        let f11 = Ink.font(11 * k)
        let f11b = Ink.font(11 * k, .semibold)
        let f12 = Ink.font(12 * k)
        for frame in geometry.rows where frame.frame.intersects(dirty) {
            guard let row = card.rows.first(where: { $0.id == frame.id }) else { continue }
            let p = RowPresentation(row, now: now, cardMuted: muted, expanded: line.expandedBodies.contains(row.id))
            // The card is filled with the surface color already.
            if state.selected == .row(id: row.id, card: card.id) {
                Palette.selection.nsColor.setFill()
                frame.frame.fill()
            }
            Palette.rowDivider.nsColor.setFill()
            CGRect(x: frame.frame.minX, y: frame.frame.minY, width: frame.frame.width, height: 1).fill()
            Shapes.dot(p.mark, in: frame.dot)
            Shapes.icon(BoardIcons.row(row.kind), in: frame.icon, color: p.gray ? Palette.mutedIcon.nsColor : Palette.botIcon.nsColor)
            Ink.drawLine(p.label, f11b, p.gray ? Palette.mutedText.nsColor : Palette.strongText.nsColor, in: frame.label)
            if let counts = p.counts, let rect = frame.counts {
                Ink.drawLine(counts, f12, Palette.text.nsColor, in: rect)
            }
            let found = matches?.rows[row.id]
            if let found { Ink.drawLineMatches(p.meta, f11, found.meta, in: frame.meta) }
            Ink.drawLine(p.meta, f11, p.gray ? Palette.mutedText.nsColor : Palette.secondary.nsColor, in: frame.meta)
            if let body = p.body, let rect = frame.body, frame.bodyLines > 0 {
                if let found {
                    Ink.drawMatches(body, f12, found.body.found, in: rect, lines: frame.bodyLines)
                    if found.body.ellipsis { Ink.drawEllipsisMark(body, f12, in: rect, lines: frame.bodyLines) }
                }
                Ink.draw(body, f12, p.gray ? Palette.mutedText.nsColor : Palette.text.nsColor, in: rect, lines: frame.bodyLines)
            }
        }
        for foot in geometry.feet where foot.frame.intersects(dirty) {
            if state.selected == foot.item {
                Palette.selection.nsColor.setFill()
                foot.frame.fill()
            }
            Palette.rowDivider.nsColor.setFill()
            CGRect(x: foot.frame.minX, y: foot.frame.minY, width: foot.frame.width, height: 1).fill()
            let line = CGRect(x: 0, y: foot.frame.minY + 4 * k, width: foot.frame.width, height: foot.frame.height - 9 * k)
            Shapes.dot(foot.mark, in: CGRect(x: 14, y: LineLayout.center(7 * k, in: line), width: 7 * k, height: 7 * k))
            let x = 14 + 7 * k + 8
            let textRect = CGRect(x: x, y: line.minY, width: max(0, foot.frame.width - 10 - x), height: line.height)
            // "+ N more" folding rows that match.
            if case .moreRows = foot.item, matches?.moreRows == true {
                Ink.drawLineMatches(foot.text, f12, [0..<(foot.text as NSString).length], in: textRect)
            }
            Ink.drawLine(foot.text, f12, Palette.secondary.nsColor, in: textRect)
        }

        if let bar = Shapes.stateColor(card.stateLabel) {
            bar.setFill()
            CGRect(x: 0, y: 0, width: 4, height: bounds.height).intersection(dirty).fill()
        }
    }

    /// The three lines above the rows.
    private func drawHeader(_ card: Card, _ geometry: CardGeometry, k: CGFloat, now: Int64, muted: Bool) {
        // Line 1.
        if let rect = geometry.stateLabel, let style = StateStyle.of(card.stateLabel) {
            Shapes.rounded(rect, radius: 4, fill: style.background.nsColor)
            Ink.drawLine(style.text, Ink.font(10 * k, .semibold), style.foreground.nsColor, in: rect.insetBy(dx: 6 * k, dy: 0))
        }
        let f11 = Ink.font(11 * k)
        if let matches { Ink.drawMarks(Warnings.prLabel(card.pr), f11, matches.prLabel, in: geometry.prLabel) }
        Ink.draw(Warnings.prLabel(card.pr), f11, muted ? Palette.mutedText.nsColor : Palette.secondary.nsColor, in: geometry.prLabel)
        for (text, rect, filled) in geometry.marks {
            if filled {
                Shapes.rounded(rect, radius: 4, fill: Palette.reviewMark.nsColor)
                Ink.drawLine(text, Ink.font(10 * k, .bold), Palette.orangeText.nsColor, in: rect.insetBy(dx: 6 * k, dy: 0))
            } else {
                Shapes.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: 4, stroke: Palette.markBorder.nsColor)
                Ink.drawLine(text, Ink.font(10 * k, .semibold), Palette.secondary.nsColor, in: rect.insetBy(dx: 5 * k, dy: 0))
            }
        }

        // Line 2.
        drawAvatar(card, in: geometry.avatar, muted: muted)
        let titleFont = Ink.font(12 * k, muted ? .regular : .semibold)
        if let matches { Ink.drawMarks(card.title, titleFont, matches.title, in: geometry.title) }
        Ink.draw(card.title, titleFont, muted ? Palette.mutedTitle.nsColor : Palette.text.nsColor, in: geometry.title)

        // Line 3.
        let baseHead = "\(card.base) \u{2190} \(card.head)"
        if let matches { Ink.drawMarks(baseHead, f11, matches.baseHead, in: geometry.baseHead) }
        Ink.draw(baseHead, f11, muted ? Palette.mutedText.nsColor : Palette.secondary.nsColor, in: geometry.baseHead)
        let parts = geometry.timeParts(card, k: k, now: now)
        if let rect = parts.dismissedIn, let text = DismissedText.dismissedIn(card.autoDismissAt, now: now) {
            Ink.draw(text, f11, Palette.faded.nsColor, in: rect)
        }
        let times = CardText.times(card, now: now)
        let timesRect = parts.times.insetBy(dx: -1, dy: 0)
        if let matches { Ink.drawMatches(times, f11, matches.author, in: timesRect) }
        Ink.draw(times, f11, muted ? Palette.mutedText.nsColor : Palette.waiting.nsColor, in: timesRect)
    }

    private func drawAvatar(_ card: Card, in rect: CGRect, muted: Bool) {
        guard let avatars = env?.context.avatars else { return }
        if let image = DecodedAvatars.image(card.authorAvatarUrl, data: avatars.image(for: card.authorAvatarUrl)) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: muted ? 0.6 : 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Palette.avatarFill.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            Palette.avatarBorder.nsColor.setStroke()
            ring.stroke()
        }
    }
}

/// A card of the Dismissed list (Main.html): the state label, owner/repo
/// #number, the chain icon; the avatar and the title; the days left and
/// Restore. No rows, no status icons, no ×.
final class DismissedLineView: LineView {
    private var card: Card?
    private var search: [String] = []
    private var geometry: DismissedGeometry?

    private struct Inputs: Equatable {
        var card: Card?
        var search: [String]
        var size: CGSize?
        var k: CGFloat
        var now: Int64
        var avatar: Bool
    }

    override func drawInputs() -> AnyEquatable? {
        AnyEquatable(Inputs(
            card: card, search: search, size: geometry?.size, k: env?.k ?? 1, now: env?.now ?? 0,
            avatar: env?.context.avatars.image(for: card?.authorAvatarUrl) != nil
        ))
    }

    func configure(_ card: Card, search: [String], geometry: DismissedGeometry, env: LineEnvironment, state: ItemState) {
        cardShape = true
        if self.card?.id != card.id {
            resetControls()
            hideTip()
        }
        self.card = card
        self.search = search
        self.geometry = geometry
        self.env = env
        kind = .card(card, section: nil, canDrag: false)
        context = env.context
        bind(state)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(Warnings.prLabel(card.pr)), \(card.title)")
        env.context.avatars.request(card.authorAvatarUrl)
        layoutContent()
        needsDisplay = true
    }

    private func layoutContent() {
        guard let card, let geometry, let env else { return }
        let list = env.context.list
        let id = card.id
        let k = env.k
        regions.items = [:]
        beginControls()
        let chain = control("chain", .icon(BoardIcons.link, size: 12 * k, color: Palette.faded), frame: geometry.chain, help: "Copy link", label: "Copy link") {}
        let url = card.url
        chain.action = { [weak list, weak chain] in
            list?.perform(.copyLink(url))
            chain?.flashCopied(seconds: LinkCopy.checkSeconds)
        }
        control("restore", .restore, frame: geometry.restore, help: nil, label: "Restore") { [weak list] in
            list?.perform(.restore(card: id))
        }
        endControls()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override var hasTips: Bool { true }

    override func tip(at point: CGPoint) -> String? {
        guard let card, let geometry, geometry.avatar.contains(point) else { return nil }
        return card.author
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let card, let geometry, let env else { return }
        let k = env.k
        (snapshot.selected != nil ? Palette.selection.nsColor : Palette.surface.nsColor).setFill()
        bounds.fill()
        if let rect = geometry.stateLabel, let style = StateStyle.of(card.stateLabel) {
            Shapes.rounded(rect, radius: 4, fill: style.background.nsColor)
            Ink.drawLine(style.text, Ink.font(10 * k, .semibold), style.foreground.nsColor, in: rect.insetBy(dx: 6 * k, dy: 0))
        }
        let f11 = Ink.font(11 * k)
        if !search.isEmpty {
            let label = Warnings.prLabel(card.pr)
            let marks = Highlight.TextMarks(Highlight.prLabel(search, pr: card.pr)) { Ink.shownEnd(label, f11, width: geometry.prLabel.width) }
            Ink.drawMarks(label, f11, marks, in: geometry.prLabel)
        }
        Ink.draw(Warnings.prLabel(card.pr), f11, Palette.secondary.nsColor, in: geometry.prLabel)
        if let image = DecodedAvatars.image(card.authorAvatarUrl, data: env.context.avatars.image(for: card.authorAvatarUrl)) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: geometry.avatar).addClip()
            image.draw(in: geometry.avatar, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Palette.avatarFill.nsColor.setFill()
            NSBezierPath(ovalIn: geometry.avatar).fill()
        }
        if !search.isEmpty {
            let font = Ink.font(12 * k, .semibold)
            let marks = Highlight.TextMarks(Highlight.ranges(search, in: card.title)) { Ink.shownEnd(card.title, font, width: geometry.title.width) }
            Ink.drawMarks(card.title, font, marks, in: geometry.title)
        }
        Ink.draw(card.title, Ink.font(12 * k, .semibold), Palette.text.nsColor, in: geometry.title)
        Ink.draw(DismissedText.daysLeft(card.dismissExpiresAt, now: env.now), f11, Palette.secondary.nsColor, in: geometry.daysLeft)
        if let bar = Shapes.stateColor(card.stateLabel) {
            bar.setFill()
            CGRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
        }
    }
}

/// The text of an empty list.
final class MessageLineView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var k: CGFloat = 1 { didSet { if k != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = Ink.font(12 * k)
        let lines = Ink.lines(text, font, width: max(1, bounds.width - 24))
        Ink.draw(text, font, Palette.faded.nsColor, in: CGRect(x: 12, y: 18 * k, width: max(0, bounds.width - 24), height: 0), lines: lines, center: true)
    }
}

/// A table cell: the line view inside it at the line's frame (the card or
/// band without the margins around it).
final class LineCell: NSView {
    let content: NSView
    /// The id of the list line this cell was last configured for (the
    /// measurement mode's consistency check).
    var lineID: String?
    var contentFrame: CGRect = .zero {
        didSet { if content.frame != contentFrame { content.frame = contentFrame } }
    }

    /// A card's height after `more`, `less`, "+ N more" or `Show less`
    /// (DESIGN.md, "Row body"): the frame is the new one at once (drawn once
    /// at its new size, which the checks see); Core Animation shows its
    /// layer's height going there (the image is drawn from the top and the
    /// layer clips it, `cardShape`), as the row views move.
    func animateContentFrame(to frame: CGRect, duration: TimeInterval, timing: CAMediaTimingFunction) {
        let old = content.frame.height
        contentFrame = frame
        guard let layer = content.layer, old != frame.height else { return }
        let animation = CABasicAnimation(keyPath: "bounds.size.height")
        animation.fromValue = old
        animation.toValue = frame.height
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "height")
    }

    init(_ content: NSView, identifier: NSUserInterfaceItemIdentifier) {
        self.content = content
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
}
