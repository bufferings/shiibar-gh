// Sample accounts and cards shared by the tests of the popover.

import Foundation
@testable import ShiibarGhCore

/// bufferings-work with example-org (o2), acme-corp (o3) and Public (o4).
func sampleAccount(disabled: Set<String> = []) -> Account {
    Account(
        id: "3407303", login: "bufferings-work", color: .red, unread: true,
        owners: [
            Owner(id: "o2", name: "example-org", kind: .org, enabled: !disabled.contains("o2"), prCount: 4),
            Owner(id: "o3", name: "acme-corp", kind: .org, enabled: !disabled.contains("o3"), prCount: 1),
            Owner(id: "o4", name: "public", kind: .public, enabled: !disabled.contains("o4"), prCount: 0),
        ]
    )
}

func row(
    _ id: String, pr: String, owner: String = "o2", kind: RowKind = .comment, text: String? = nil, actor: String? = nil,
    unread: Bool = false, muted: Bool = false, at: Int64 = 0
) -> Row {
    Row(id: id, pr: pr, owner: owner, kind: kind, text: text, actor: actor, url: "https://github.com/c/\(id)", occurredAt: at, unread: unread, muted: muted)
}

func card(
    _ id: String, pr: String? = nil, owner: String = "o2", author: String = "al", authored: Bool = false, assigned: Bool = false,
    reviewRequested: Bool = false, state: StateLabel = .open, placement: Placement? = nil, muted: [MuteReason] = [],
    added: Int64 = T0, updated: Int64 = T0, rows: [Row] = [], dismissedAt: Int64? = nil, expires: Int64? = nil, older: Bool = false
) -> Card {
    let key = pr ?? "example-org/api#\(id)"
    return Card(
        id: id, pr: key, owner: owner, title: "Title \(id)", url: "https://github.com/p/\(id)", author: author,
        authoredByMe: authored, assignedToMe: assigned, reviewRequested: reviewRequested, stateLabel: state,
        addedAt: added, updatedAt: updated, rows: rows, placement: placement, muted: muted,
        dismissedAt: dismissedAt, dismissExpiresAt: expires, olderRows: older
    )
}

func review(_ section: PlacementSection, _ position: Int) -> Placement {
    Placement(tab: .review, section: section, position: position)
}

func mine(_ section: PlacementSection = .main, _ position: Int) -> Placement {
    Placement(tab: .mine, section: section, position: position)
}

/// The board's Review tab, Mine and All in small:
/// - Review: Doing R1; Todo T1–T5, then T6 and T7 muted (T7 has an unread
///   mention); Waiting W1; Done D1 (merged).
/// - Mine: M1 (authored, unread blue row), M2 (assigned), Done M3 (closed).
/// - All only: N1 (acme-corp, gray unread row by a muted user).
/// - Dismissed: X1 (older), X2 (newer, merged).
func sampleCards() -> [Card] {
    [
        card("R1", pr: "example-org/web#212", author: "mk", reviewRequested: true, placement: review(.doing, 0), updated: T0 - 100,
             rows: [row("r1", pr: "example-org/web#212", kind: .teamReviewRequested, text: "for frontend team")]),
        card("T1", pr: "example-org/api#407", author: "al", assigned: true, placement: review(.todo, 0), updated: T0 - 40, rows: [
            row("A", pr: "example-org/api#407", kind: .mentioned, text: "could you check the retry path?", actor: "al", unread: true),
            row("B", pr: "example-org/api#407", text: "pushed a fix", actor: "al"),
            row("C", pr: "example-org/api#407", kind: .reviewRequested, text: "for you"),
            row("D", pr: "example-org/api#407", kind: .reply, text: "keep the cursor", actor: "rk", unread: true),
            row("E", pr: "example-org/api#407", text: "split this?", actor: "jo"),
        ], older: true),
        card("T2", pr: "example-org/web#230", author: "ts", placement: review(.todo, 1), updated: T0 - 30),
        card("T3", pr: "example-org/docs#88", author: "jo", placement: review(.todo, 2), updated: T0 - 20),
        card("T4", pr: "example-org/api#415", author: "rk", placement: review(.todo, 3), updated: T0 - 10),
        card("T5", pr: "example-org/web#219", author: "jo", placement: review(.todo, 4), updated: T0 - 5),
        card("T6", pr: "example-org/web#241", author: "renovate", placement: review(.todo, 5), muted: [.author], updated: T0 - 4,
             rows: [row("t6", pr: "example-org/web#241", kind: .teamReviewRequested, text: "for frontend team", unread: true, muted: true)]),
        card("T7", pr: "example-org/api#402", author: "renovate", placement: review(.todo, 6), muted: [.author, .repo], updated: T0 - 3,
             rows: [row("t7", pr: "example-org/api#402", kind: .mentioned, text: "needs a manual step", actor: "renovate", unread: true)]),
        card("W1", pr: "acme-corp/infra#61", owner: "o3", author: "dz", placement: review(.waiting, 0), updated: T0 - 200),
        card("D1", pr: "acme-corp/infra#58", owner: "o3", author: "mk", state: .merged, placement: review(.done, 0), updated: T0 - 300),
        card("M1", pr: "example-org/api#421", author: "bufferings-work", authored: true, placement: mine(.main, 0), updated: T0 - 60,
             rows: [row("m1", pr: "example-org/api#421", kind: .checksPassed, unread: true)]),
        card("M2", pr: "acme-corp/web#77", owner: "o3", author: "mk", assigned: true, placement: mine(.main, 1), updated: T0 - 70),
        card("M3", pr: "example-org/api#390", author: "bufferings-work", authored: true, state: .closed, placement: mine(.done, 0), updated: T0 - 400),
        card("N1", pr: "acme-corp/web#80", owner: "o3", author: "zz", updated: T0 - 1,
             rows: [row("n1", pr: "acme-corp/web#80", owner: "o3", text: "noise", actor: "bot", unread: true, muted: true)]),
        card("X1", pr: "example-org/web#205", author: "ts", dismissedAt: T0 - 86_400, expires: T0 + 5 * 86_400),
        card("X2", pr: "acme-corp/infra#55", owner: "o3", author: "dz", state: .merged, placement: review(.done, 1),
             dismissedAt: T0 - 100, expires: T0 + 6 * 86_400 + 100),
    ]
}

func layout(
    _ tab: ListTab, options: ListOptions = ListOptions(), cards: [Card] = sampleCards(), orders: GroupOrders = [:],
    repositories: [String]? = nil, collapsed: Set<String> = [], expanded: Set<String> = [], search: String = "",
    account: Account = sampleAccount()
) -> [SectionLayout] {
    Listing.sections(
        tab: tab, cards: cards, account: account, options: options, orders: orders,
        repositories: repositories ?? Listing.knownRepositories([], cards: cards),
        folding: Listing.Folding(collapsed: collapsed, expanded: expanded, search: search)
    )
}

func view(_ tab: ListTab?, cards: [Card] = sampleCards(), options: ListOptions = ListOptions(), expandedRows: Set<String> = []) -> ListView {
    guard let tab else { return ListView(tab: nil, dismissed: Listing.dismissed(cards), expandedRows: expandedRows, cards: cards) }
    return ListView(tab: tab, sections: layout(tab, options: options, cards: cards), expandedRows: expandedRows, cards: cards)
}
