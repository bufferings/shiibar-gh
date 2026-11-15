// The Mute decision of DESIGN.md, "Mute", as the app applies it to the
// cards on screen before the daemon answers a mute or an unmute ("Showing
// what an operation did": the cards and rows the mute targets follow the
// rule, every other card keeps what the daemon sent). The daemon's own
// decision (`mute_reasons` and `row_muted` in shiibar-ghd's engine.rs) is
// the same rule; the wire carries its result as `muted`, `pr_mute` and the
// rows' `muted`.

import Foundation

extension Mutes {
    /// What the account's mutes must be, read off the cards, while the list
    /// itself was not read yet: a repository or author a card is muted for,
    /// and every PR whose own setting is Mute.
    public static func inferred(from cards: [Card]) -> Mutes {
        var repos: [String] = []
        var users: [String] = []
        var prs: [String] = []
        func add(_ name: String, _ list: inout [String]) {
            if !list.contains(where: { $0.lowercased() == name.lowercased() }) { list.append(name) }
        }
        for card in cards {
            if card.isMuted(for: .repo) { add(Listing.repository(card.pr), &repos) }
            if card.isMuted(for: .author), !card.author.isEmpty { add(card.author, &users) }
            if card.prMute.value == .mute { add(card.pr, &prs) }
        }
        return Mutes(repos: repos, users: users, prs: prs)
    }

    /// The lists with `name` added (`on`) or taken out.
    public func changing(_ kind: MuteKind, _ name: String, on: Bool) -> Mutes {
        var next = self
        let lowered = name.lowercased()
        func change(_ list: inout [String]) {
            list.removeAll { $0.lowercased() == lowered }
            if on { list.append(name) }
        }
        switch kind {
        case .repo: change(&next.repos)
        case .user: change(&next.users)
        case .pr: change(&next.prs)
        }
        return next
    }
}

public enum MuteRules {
    /// Rows a user mute leaves alone: state changes and reactions carry no
    /// actor of their own (DESIGN.md, "Mute").
    static let actorless: Set<RowKind> = [.changesRequested, .checksFailed, .checksPassed, .conflicts, .mergeable, .reaction]

    /// The repository and author Mute that apply to a card whose own
    /// setting is none: never to your own PR.
    static func othersMute(_ card: Card, _ mutes: Mutes) -> [MuteReason] {
        guard !card.authoredByMe else { return [] }
        var out: [MuteReason] = []
        if mutes.contains(.repo, Listing.repository(card.pr)) { out.append(.repo) }
        if !card.author.isEmpty, mutes.contains(.user, card.author) { out.append(.author) }
        return out
    }

    /// Why the card is muted (DESIGN.md, "Mute", the decision): its own
    /// Mute, or, with its own setting none, its repository or author unless
    /// you authored it. Unmute: never.
    public static func reasons(_ card: Card, prMute: PrMute, _ mutes: Mutes) -> [MuteReason] {
        switch prMute {
        case .unmute: return []
        case .mute: return [.pr] + othersMute(card, mutes)
        case .none: return othersMute(card, mutes)
        }
    }

    /// A row is muted when its card is, or when a muted user caused it,
    /// except on a PR whose own setting is Unmute; mentions of you and your
    /// team never are.
    public static func rowMuted(_ row: Row, cardMuted: Bool, prMute: PrMute, _ mutes: Mutes) -> Bool {
        guard let kind = row.kind.value else { return row.muted }
        if row.isMention { return false }
        if cardMuted { return true }
        guard prMute != .unmute, !actorless.contains(kind), let actor = row.actor, !actor.isEmpty else { return false }
        return mutes.contains(.user, actor)
    }

    /// Whether the mute names the card: the PR itself, a PR of the
    /// repository, or a PR the user authored.
    static func targets(_ card: Card, kind: MuteKind, name: String) -> Bool {
        let name = name.lowercased()
        switch kind {
        case .pr: return card.pr.lowercased() == name
        case .repo: return Listing.repository(card.pr).lowercased() == name
        case .user: return card.author.lowercased() == name
        }
    }

    /// The PR's own setting after `Mute this pull request` (Mute) or
    /// `Unmute this pull request` and the − of Settings: none, or Unmute
    /// when its repository or author would still mute it (DESIGN.md, "Wire
    /// format", `unmute`).
    static func prMute(after on: Bool, _ card: Card, _ mutes: Mutes) -> PrMute {
        if on { return .mute }
        // Already Unmute: no change.
        if card.prMute.value == .unmute { return .unmute }
        return othersMute(card, mutes).isEmpty ? .none : .unmute
    }

    /// The cards after a mute (`on`) or unmute of `name`, with `mutes` as
    /// they are after it. Only the cards the mute names change (their
    /// reasons, own setting and rows) and, for a user, the rows that user
    /// caused in other cards.
    public static func apply(_ cards: [Card], kind: MuteKind, name: String, on: Bool, mutes: Mutes) -> [Card] {
        let lowered = name.lowercased()
        return cards.map { card in
            let targeted = targets(card, kind: kind, name: name)
            let byActor = kind == .user && card.rows.contains { $0.actor?.lowercased() == lowered }
            guard targeted || byActor else { return card }
            var card = card
            var own = card.prMute.value ?? .none
            if targeted {
                if kind == .pr { own = prMute(after: on, card, mutes) }
                card.prMute = .known(own)
                card.muted = reasons(card, prMute: own, mutes).map(Lenient.known)
            }
            let cardMuted = card.isMuted
            card.rows = card.rows.map { row in
                guard targeted || row.actor?.lowercased() == lowered else { return row }
                var row = row
                row.muted = rowMuted(row, cardMuted: cardMuted, prMute: own, mutes)
                return row
            }
            return card
        }
    }
}
