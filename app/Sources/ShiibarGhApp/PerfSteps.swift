// The version-specific steps of the measurement mode (Perf.swift).

import AppKit
import ShiibarGhCore

enum PerfSteps {
    /// 0.5: ⌘-click, and a drag held in the list's bottom band.
    @MainActor static let current = PerfRunner.Steps(
        toggle: { list, card in list.click(card: card, extent: .toggle) },
        autoScroll: { list, _ in
            let card = list.sections.filter(\.accepts).flatMap(\.cards).first { $0.canDrag }
            if let card { CardDragController.of(list).hoverForMeasurement(card: card.id) }
        },
        stopAutoScroll: { list in CardDragController.of(list).endMeasurement() },
        prepare: nil,
        inView: { list, card in CardDragController.of(list).isVisible(.header(card: card)) },
        describe: { list in
            let table = CardDragController.of(list).scrollView?.documentView as? NSTableView
            let size = table.map { "table flipped \($0.isFlipped), width \(Int($0.frame.width)), rows \($0.numberOfRows), " } ?? ""
            return size + CardDragController.of(list).debugDescription
        }
    )
}
