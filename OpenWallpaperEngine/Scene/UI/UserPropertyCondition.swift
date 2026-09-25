import Foundation

/// A project.json property `condition` such as `clock.value == 1` or
/// `style.value == "cycle" && mode.value != "dual"`. WE evaluates these as JavaScript expressions
/// over the other properties; this supports the subset authors actually use: `name.value`,
/// string/number/bool literals, `== != === !== < <= > >=`, `! && ||` and parentheses.
///
/// Values come from the sidebar store, where everything is a string ("true", "0.5", "valueA").
/// Comparison is numeric when both sides read as numbers (bools count as 1/0, which is what
/// JavaScript's loose `==` does for `clock.value == 1`), and string comparison otherwise.
struct UserPropertyCondition {
    private indirect enum Node {
        case literal(String)
        case property(String)
        case not(Node)
        case and(Node, Node)
        case or(Node, Node)
        case compare(String, Node, Node)
    }

    private let root: Node?

    /// Nil for an empty condition. An unparseable one also yields a condition that is always true,
    /// so a property is never hidden because of syntax this parser doesn't know.
    init?(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parser = Parser(tokens: Self.tokenize(trimmed))
        if let node = parser.parseOr(), parser.atEnd {
            root = node
        } else {
            root = nil
        }
    }

    /// Whether the property should be shown for the given values.
    func evaluate(_ values: [String: String]) -> Bool {
        guard let root else { return true }
        return Self.truthy(Self.eval(root, values))
    }

    // MARK: Evaluation

    private static func eval(_ node: Node, _ values: [String: String]) -> String {
        switch node {
        case .literal(let value): return value
        case .property(let name): return values[name] ?? ""
        case .not(let inner): return truthy(eval(inner, values)) ? "false" : "true"
        case .and(let lhs, let rhs):
            return truthy(eval(lhs, values)) && truthy(eval(rhs, values)) ? "true" : "false"
        case .or(let lhs, let rhs):
            return truthy(eval(lhs, values)) || truthy(eval(rhs, values)) ? "true" : "false"
        case .compare(let op, let lhs, let rhs):
            return compare(op, eval(lhs, values), eval(rhs, values)) ? "true" : "false"
        }
    }

    private static func number(_ value: String) -> Double? {
        switch value.lowercased() {
        case "true": return 1
        case "false": return 0
        default: return Double(value.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func compare(_ op: String, _ lhs: String, _ rhs: String) -> Bool {
        if let l = number(lhs), let r = number(rhs) {
            switch op {
            case "==", "===": return l == r
            case "!=", "!==": return l != r
            case "<": return l < r
            case "<=": return l <= r
            case ">": return l > r
            case ">=": return l >= r
            default: return false
            }
        }
        switch op {
        case "==", "===": return lhs == rhs
        case "!=", "!==": return lhs != rhs
        case "<": return lhs < rhs
        case "<=": return lhs <= rhs
        case ">": return lhs > rhs
        case ">=": return lhs >= rhs
        default: return false
        }
    }

    private static func truthy(_ value: String) -> Bool {
        if let number = number(value) { return number != 0 }
        return !value.isEmpty
    }

    // MARK: Parsing

    private enum Token: Equatable {
        case identifier(String)
        case string(String)
        case number(String)
        case op(String)
    }

    private static func tokenize(_ source: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var index = 0
        let operators = ["===", "!==", "==", "!=", "<=", ">=", "&&", "||", "<", ">", "!", "(", ")"]
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace { index += 1; continue }
            if c == "\"" || c == "'" {
                var end = index + 1
                var text = ""
                while end < chars.count, chars[end] != c {
                    if chars[end] == "\\", end + 1 < chars.count { end += 1 }
                    text.append(chars[end]); end += 1
                }
                tokens.append(.string(text))
                index = end + 1
                continue
            }
            if c.isNumber || (c == "-" && index + 1 < chars.count && chars[index + 1].isNumber) {
                var end = index + 1
                while end < chars.count, chars[end].isNumber || chars[end] == "." { end += 1 }
                tokens.append(.number(String(chars[index..<end])))
                index = end
                continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var end = index + 1
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" || chars[end] == "." || chars[end] == "$" {
                    end += 1
                }
                tokens.append(.identifier(String(chars[index..<end])))
                index = end
                continue
            }
            if let op = operators.first(where: { op in
                index + op.count <= chars.count && String(chars[index..<(index + op.count)]) == op
            }) {
                tokens.append(.op(op))
                index += op.count
                continue
            }
            // Unknown character: emit it so parsing fails and the condition falls back to "shown".
            tokens.append(.op(String(c)))
            index += 1
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0

        var atEnd: Bool { position == tokens.count }

        private func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        private mutating func accept(_ op: String) -> Bool {
            if peek() == .op(op) { position += 1; return true }
            return false
        }

        mutating func parseOr() -> Node? {
            guard var lhs = parseAnd() else { return nil }
            while accept("||") {
                guard let rhs = parseAnd() else { return nil }
                lhs = .or(lhs, rhs)
            }
            return lhs
        }

        mutating func parseAnd() -> Node? {
            guard var lhs = parseUnary() else { return nil }
            while accept("&&") {
                guard let rhs = parseUnary() else { return nil }
                lhs = .and(lhs, rhs)
            }
            return lhs
        }

        mutating func parseUnary() -> Node? {
            if accept("!") { return parseUnary().map { .not($0) } }
            return parseComparison()
        }

        mutating func parseComparison() -> Node? {
            guard let lhs = parsePrimary() else { return nil }
            for op in ["===", "!==", "==", "!=", "<=", ">=", "<", ">"] where accept(op) {
                guard let rhs = parsePrimary() else { return nil }
                return .compare(op, lhs, rhs)
            }
            return lhs
        }

        mutating func parsePrimary() -> Node? {
            guard let token = peek() else { return nil }
            position += 1
            switch token {
            case .string(let text): return .literal(text)
            case .number(let text): return .literal(text)
            case .identifier(let name):
                if name == "true" || name == "false" { return .literal(name) }
                let base = name.hasSuffix(".value") ? String(name.dropLast(".value".count)) : name
                return .property(base)
            case .op("("):
                guard let inner = parseOr(), accept(")") else { return nil }
                return inner
            case .op("!"):
                return parseUnary().map { .not($0) }
            default:
                return nil
            }
        }
    }
}
