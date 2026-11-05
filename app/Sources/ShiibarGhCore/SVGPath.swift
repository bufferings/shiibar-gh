// The `d` attribute of the boards' SVG icons, read into absolute segments so
// the app draws the same shapes in the menu bar and the popover. Supports
// the commands the boards use: M, L, H, V, C, S and Z, each also relative.

import Foundation

public struct Point: Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

public enum PathSegment: Equatable {
    case move(Point)
    case line(Point)
    case curve(Point, Point, Point)
    case close
}

public enum SVGPath {
    public static func parse(_ d: String) -> [PathSegment] {
        var tokens = tokenize(d)[...]
        var segments: [PathSegment] = []
        var current = Point(0, 0)
        var start = Point(0, 0)
        var lastControl: Point?
        var command: Character = "M"

        func number() -> Double? {
            guard case .number(let value)? = tokens.first else { return nil }
            tokens.removeFirst()
            return value
        }

        while !tokens.isEmpty {
            if case .command(let c) = tokens.first! {
                command = c
                tokens.removeFirst()
            }
            let relative = command.isLowercase
            let base = relative ? current : Point(0, 0)
            switch command.uppercased().first! {
            case "M":
                guard let x = number(), let y = number() else { return segments }
                current = Point(base.x + x, base.y + y)
                start = current
                segments.append(.move(current))
                lastControl = nil
                // Pairs after a move are lines.
                command = relative ? "l" : "L"
            case "L":
                guard let x = number(), let y = number() else { return segments }
                current = Point(base.x + x, base.y + y)
                segments.append(.line(current))
                lastControl = nil
            case "H":
                guard let x = number() else { return segments }
                current = Point((relative ? current.x : 0) + x, current.y)
                segments.append(.line(current))
                lastControl = nil
            case "V":
                guard let y = number() else { return segments }
                current = Point(current.x, (relative ? current.y : 0) + y)
                segments.append(.line(current))
                lastControl = nil
            case "C":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return segments }
                let c1 = Point(base.x + x1, base.y + y1)
                let c2 = Point(base.x + x2, base.y + y2)
                current = Point(base.x + x, base.y + y)
                segments.append(.curve(c1, c2, current))
                lastControl = c2
            case "S":
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return segments }
                let c1 = lastControl.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let c2 = Point(base.x + x2, base.y + y2)
                current = Point(base.x + x, base.y + y)
                segments.append(.curve(c1, c2, current))
                lastControl = c2
            case "Z":
                segments.append(.close)
                current = start
                lastControl = nil
                // A command letter has to follow.
                if case .number? = tokens.first { tokens.removeFirst() }
            default:
                return segments
            }
        }
        return segments
    }

    enum Token: Equatable {
        case command(Character)
        case number(Double)
    }

    static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        func flush() {
            if !text.isEmpty, let value = Double(text) { tokens.append(.number(value)) }
            text = ""
        }
        for character in d {
            if character.isLetter && character != "e" && character != "E" {
                flush()
                tokens.append(.command(character))
            } else if character == "-" {
                // A minus starts a new number unless it follows an exponent.
                if let last = text.last, last == "e" || last == "E" {
                    text.append(character)
                } else {
                    flush()
                    text.append(character)
                }
            } else if character == "." {
                // A second point starts a new number: ".5.5" is two numbers.
                if text.contains(".") && !text.contains("e") {
                    flush()
                }
                text.append(character)
            } else if character == "," || character.isWhitespace {
                flush()
            } else {
                text.append(character)
            }
        }
        flush()
        return tokens
    }
}
