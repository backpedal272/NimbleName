import Foundation

/// The structured answer returned by the model for one document.
nonisolated struct ExtractedFields: Codable, Sendable, Equatable, Hashable {
    static let unknown = "Unknown"

    var date = ""
    var vendor = ""
    var description = ""
    var currency = ""
    var amount = ""

    /// True when the description is missing: a name cannot be built without it.
    /// An empty vendor is legitimate (handwritten notes); an empty date is filled with the file's creation date.
    var isIncomplete: Bool { description.isEmpty }

    /// Trims values, turns "Unknown" into empty strings, uppercases the currency.
    mutating func normalize() {
        date = Self.clean(date)
        vendor = Self.clean(vendor)
        description = Self.clean(description)
        currency = Self.clean(currency).uppercased()
        amount = Self.clean(amount)

        if currency.isEmpty && amount.isEmpty { return }
        // Model sometimes puts "CHF 89.00" into amount; split it.
        if currency.isEmpty, let split = Self.splitAmount(amount) {
            currency = split.currency
            amount = split.amount
        }
    }

    /// "CHF 89.00" → ("CHF", "89.00")
    static func splitAmount(_ text: String) -> (currency: String, amount: String)? {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].count == 3, parts[0].allSatisfy(\.isLetter) {
            return (parts[0].uppercased(), parts[1])
        }
        if parts[1].count == 3, parts[1].allSatisfy(\.isLetter) {
            return (parts[1].uppercased(), parts[0])
        }
        return nil
    }

    /// Value shown in the single "Amount" column: "CHF 89.00" or "".
    var amountText: String {
        get { [currency, amount].filter { !$0.isEmpty }.joined(separator: " ") }
        set {
            let trimmed = Self.clean(newValue)
            if trimmed.isEmpty {
                currency = ""; amount = ""
            } else if let split = Self.splitAmount(trimmed) {
                currency = split.currency; amount = split.amount
            } else {
                amount = trimmed
            }
        }
    }

    private static func clean(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Older prompts and some models answer "Unknown"/"N/A"; treat those as empty.
        if ["unknown", "n/a", "none", "null", "-"].contains(trimmed.lowercased()) { return "" }
        return trimmed
    }
}
