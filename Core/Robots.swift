// MODULR – kerne: robots.txt-regler. Kun Foundation.

import Foundation

struct RobotsRules: Equatable {
    struct Rule: Equatable {
        var allow: Bool
        var pattern: String
    }

    var rules: [Rule] = []

    static let allowAll = RobotsRules(rules: [])

    /// Læser reglerne for vores user-agent (eller "*" hvis vi ikke er nævnt).
    static func parse(_ text: String, userAgent: String = "MODULR") -> RobotsRules {
        var groups: [(agents: [String], rules: [Rule])] = []
        var currentAgents: [String] = []
        var currentRules: [Rule] = []
        var lastWasAgent = false

        func flush() {
            if !currentAgents.isEmpty { groups.append((currentAgents, currentRules)) }
            currentAgents = []
            currentRules = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "user-agent":
                if !lastWasAgent { flush() }
                currentAgents.append(value.lowercased())
                lastWasAgent = true
            case "allow", "disallow":
                lastWasAgent = false
                if currentAgents.isEmpty { continue }
                if key == "disallow" && value.isEmpty { continue } // tom Disallow = alt tilladt
                currentRules.append(Rule(allow: key == "allow", pattern: value))
            default:
                lastWasAgent = false
            }
        }
        flush()

        let ua = userAgent.lowercased()
        if let specific = groups.first(where: { g in g.agents.contains { $0 != "*" && ua.contains($0) } }) {
            return RobotsRules(rules: specific.rules)
        }
        if let star = groups.first(where: { $0.agents.contains("*") }) {
            return RobotsRules(rules: star.rules)
        }
        return .allowAll
    }

    static func matches(pattern: String, path: String) -> Bool {
        var p = NSRegularExpression.escapedPattern(for: pattern)
        p = p.replacingOccurrences(of: "\\*", with: ".*")
        if p.hasSuffix("\\$") { p = String(p.dropLast(2)) + "$" }
        return path.range(of: "^" + p, options: .regularExpression) != nil
    }

    /// Længste matchende regel vinder; ved lige lange vinder Allow.
    func isAllowed(_ path: String) -> Bool {
        var best: Rule?
        for r in rules where RobotsRules.matches(pattern: r.pattern, path: path) {
            if let b = best {
                if r.pattern.count > b.pattern.count || (r.pattern.count == b.pattern.count && r.allow) { best = r }
            } else {
                best = r
            }
        }
        return best?.allow ?? true
    }
}
