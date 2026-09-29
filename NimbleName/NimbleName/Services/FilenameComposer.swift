import Foundation

/// Builds filenames from the template, sanitizes them, and recognizes / parses names that follow the template.
nonisolated enum FilenameComposer {
    static let placeholderNames = ["date", "vendor", "description", "currency", "amount"]

    static func value(of name: String, in fields: ExtractedFields) -> String? {
        switch name {
        case "date": fields.date
        case "vendor": fields.vendor
        case "description": fields.description
        case "currency": fields.currency
        case "amount": fields.amount
        default: nil
        }
    }

    static func placeholders(in text: String) -> [String] {
        placeholderNames.filter { text.contains("{\($0)}") }
    }

    /// Filename without extension. Parenthesized groups whose placeholders are all empty are dropped.
    static func compose(template: String, fields: ExtractedFields, maxLength: Int) -> String {
        var result = template
        if let groupRegex = try? Regex("\\s*\\(([^()]*)\\)") {
            result = result.replacing(groupRegex) { match in
                let whole = String(match.output[0].substring ?? "")
                let inner = String(match.output[1].substring ?? "")
                let names = placeholders(in: inner)
                let allEmpty = !names.isEmpty && names.allSatisfy { (value(of: $0, in: fields) ?? "").isEmpty }
                return allEmpty ? "" : whole
            }
        }
        for name in placeholderNames {
            result = result.replacingOccurrences(of: "{\(name)}", with: value(of: name, in: fields) ?? "")
        }
        return sanitize(collapseSeparators(result), maxLength: maxLength)
    }

    /// An empty field leaves a doubled separator ("2024-01-08 -  - Notes") or a dangling one; remove those.
    static func collapseSeparators(_ name: String) -> String {
        var result = name
        if let doubled = try? Regex("(\\s*-\\s+){2,}") {
            result = result.replacing(doubled, with: " - ")
        }
        if let leading = try? Regex("^\\s*-\\s+") {
            result = result.replacing(leading, with: "")
        }
        if let trailing = try? Regex("\\s+-\\s*$") {
            result = result.replacing(trailing, with: "")
        }
        return result
    }

    /// Removes characters that are illegal on macOS/Windows, collapses whitespace, trims, truncates.
    static func sanitize(_ name: String, maxLength: Int) -> String {
        var result = name
        for illegal in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"] {
            result = result.replacingOccurrences(of: illegal, with: " ")
        }
        result = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while result.hasPrefix(".") { result.removeFirst() }
        if maxLength > 0, result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        while let last = result.last, last == " " || last == "." { result.removeLast() }
        return result
    }

    // MARK: - Pattern matching

    /// Regex derived from the template: placeholders become named captures, parenthesized groups become optional.
    static func pattern(for template: String) -> Regex<AnyRegexOutput>? {
        var pattern = "^"
        var pendingSpace = false
        var index = template.startIndex

        func flushSpace() {
            if pendingSpace { pattern += "\\s+"; pendingSpace = false }
        }

        while index < template.endIndex {
            let char = template[index]
            if char == "{", let close = template[index...].firstIndex(of: "}") {
                let name = String(template[template.index(after: index)..<close])
                if let capture = capturePattern(for: name) {
                    flushSpace()
                    if name == "vendor" {
                        // Vendor may be absent from a name; make it optional together with the separator that follows it.
                        let afterPlaceholder = template.index(after: close)
                        let literalEnd = template[afterPlaceholder...].firstIndex { $0 == "{" || $0 == "(" } ?? template.endIndex
                        let literal = template[afterPlaceholder..<literalEnd]
                        pattern += "(?:" + capture + literalPattern(String(literal)) + ")?"
                        index = literalEnd
                    } else {
                        pattern += capture
                        index = template.index(after: close)
                    }
                    continue
                }
            }
            if char == "(" {
                pendingSpace = false
                pattern += "(?:\\s*\\("
            } else if char == ")" {
                pattern += "\\))?"
            } else if char.isWhitespace {
                pendingSpace = true
            } else if char.isLetter || char.isNumber {
                flushSpace()
                pattern.append(char)
            } else {
                flushSpace()
                pattern += "\\" + String(char)
            }
            index = template.index(after: index)
        }
        if pendingSpace { pattern += "\\s*" }
        pattern += "$"
        return try? Regex(pattern)
    }

    /// Regex for a literal template fragment: whitespace runs become \s+, punctuation is escaped.
    private static func literalPattern(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for char in text {
            if char.isWhitespace { pendingSpace = true; continue }
            if pendingSpace { out += "\\s+"; pendingSpace = false }
            out += (char.isLetter || char.isNumber) ? String(char) : "\\" + String(char)
        }
        if pendingSpace { out += "\\s+" }
        return out
    }

    private static func capturePattern(for name: String) -> String? {
        switch name {
        case "date": "(?<date>\\d{4}-\\d{2}-\\d{2}|Unknown)"
        case "vendor": "(?<vendor>[^()]+?)"
        case "description": "(?<description>[^()]+?)"
        case "currency": "(?<currency>[A-Za-z]{3})"
        case "amount": "(?<amount>[0-9][0-9.,'’ ]*)"
        default: nil
        }
    }

    /// True when the name already follows the template. Names carrying "Unknown" in any field
    /// (produced by older prompts) do not count: they still need a proper analysis.
    static func matches(_ name: String, template: String) -> Bool {
        guard let regex = pattern(for: template), let match = name.wholeMatch(of: regex) else { return false }
        for field in placeholderNames {
            if let value = match.output[field]?.substring,
               value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(ExtractedFields.unknown) == .orderedSame {
                return false
            }
        }
        return true
    }

    static func parse(_ name: String, template: String) -> ExtractedFields? {
        guard let regex = pattern(for: template), let match = name.wholeMatch(of: regex) else { return nil }
        var fields = ExtractedFields()
        fields.date = String(match.output["date"]?.substring ?? "")
        fields.vendor = String(match.output["vendor"]?.substring ?? "")
        fields.description = String(match.output["description"]?.substring ?? "")
        fields.currency = String(match.output["currency"]?.substring ?? "")
        fields.amount = String(match.output["amount"]?.substring ?? "")
        fields.normalize()
        return fields
    }
}
