import Foundation
import Observation

/// All user-editable settings, persisted in UserDefaults (API key in the Keychain).
@Observable
final class AppSettings {
    static let defaultBaseURL = "http://127.0.0.1:8008/v1"
    static let defaultModelName = "Qwen3.8-27B-8bit"
    static let defaultTemplate = "{date} - {vendor} - {description} ({currency} {amount})"
    static let supportedExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "heic", "tiff", "tif", "webp"]

    static let defaultPrompt = """
    You are a document analysis assistant. Look at the provided document image and extract the following fields. Reply with a single JSON object and nothing else.

    {
      "date": "YYYY-MM-DD, or empty string if the document shows no date",
      "vendor": "issuing organisation or company exactly as printed, or empty string",
      "description": "concise English sentence-case phrase describing what the document is",
      "currency": "ISO 4217 code such as CHF, EUR, USD, or empty string",
      "amount": "total or amount due exactly as printed, digits with decimal point, or empty string"
    }

    Rules:
    - date: prefer the invoice/statement date. Leave empty if no date is printed. Never guess.
    - vendor: the sender/issuer (e.g. "SBB", "Swisscom", "Migros Genf"). Keep the printed capitalization. Do not normalize. Leave empty for documents without an issuing organisation, such as handwritten notes, personal letters or photos.
    - description: always in English, first word capitalized, rest lowercase, no jargon or repetition (e.g. "Mobile phone bill", "Handwritten meeting notes", "Rental contract"). Never leave it empty.
    - currency and amount: only if a total or amount due is clearly stated. Never invent a value. Leave both empty otherwise.
    - Never use colons, slashes or backslashes inside any value. Never write "Unknown"; use an empty string instead.
    """

    private enum Key {
        static let baseURL = "llm.baseURL"
        static let modelName = "llm.modelName"
        static let temperature = "llm.temperature"
        static let maxTokens = "llm.maxTokens"
        static let timeoutSeconds = "llm.timeoutSeconds"
        static let parallelRequests = "llm.parallelRequests"
        static let prompt = "prompt.text"
        static let appendNoThink = "prompt.appendNoThink"
        static let template = "naming.template"
        static let maxFilenameLength = "naming.maxLength"
        static let skipAlreadyNamed = "watch.skipAlreadyNamed"
        static let notifyWhenReady = "watch.notify"
        static let showMenuBar = "ui.showMenuBar"
        static let watchingEnabled = "watch.enabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var baseURL: String { didSet { defaults.set(baseURL, forKey: Key.baseURL) } }
    var modelName: String { didSet { defaults.set(modelName, forKey: Key.modelName) } }
    var temperature: Double { didSet { defaults.set(temperature, forKey: Key.temperature) } }
    var maxTokens: Int { didSet { defaults.set(maxTokens, forKey: Key.maxTokens) } }
    var timeoutSeconds: Int { didSet { defaults.set(timeoutSeconds, forKey: Key.timeoutSeconds) } }
    var parallelRequests: Int { didSet { defaults.set(parallelRequests, forKey: Key.parallelRequests) } }
    var apiKey: String { didSet { KeychainStore.save(apiKey) } }
    var prompt: String { didSet { defaults.set(prompt, forKey: Key.prompt) } }
    var appendNoThink: Bool { didSet { defaults.set(appendNoThink, forKey: Key.appendNoThink) } }
    var template: String { didSet { defaults.set(template, forKey: Key.template) } }
    var maxFilenameLength: Int { didSet { defaults.set(maxFilenameLength, forKey: Key.maxFilenameLength) } }
    var skipAlreadyNamed: Bool { didSet { defaults.set(skipAlreadyNamed, forKey: Key.skipAlreadyNamed) } }
    var notifyWhenReady: Bool { didSet { defaults.set(notifyWhenReady, forKey: Key.notifyWhenReady) } }
    var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: Key.showMenuBar) } }
    var watchingEnabled: Bool { didSet { defaults.set(watchingEnabled, forKey: Key.watchingEnabled) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        baseURL = defaults.string(forKey: Key.baseURL) ?? Self.defaultBaseURL
        modelName = defaults.string(forKey: Key.modelName) ?? Self.defaultModelName
        temperature = defaults.object(forKey: Key.temperature) as? Double ?? 0.1
        maxTokens = defaults.object(forKey: Key.maxTokens) as? Int ?? 512
        timeoutSeconds = defaults.object(forKey: Key.timeoutSeconds) as? Int ?? 120
        parallelRequests = defaults.object(forKey: Key.parallelRequests) as? Int ?? 1
        apiKey = KeychainStore.load()
        prompt = defaults.string(forKey: Key.prompt) ?? Self.defaultPrompt
        appendNoThink = defaults.object(forKey: Key.appendNoThink) as? Bool ?? true
        template = defaults.string(forKey: Key.template) ?? Self.defaultTemplate
        maxFilenameLength = defaults.object(forKey: Key.maxFilenameLength) as? Int ?? 120
        skipAlreadyNamed = defaults.object(forKey: Key.skipAlreadyNamed) as? Bool ?? true
        notifyWhenReady = defaults.object(forKey: Key.notifyWhenReady) as? Bool ?? true
        showMenuBar = defaults.object(forKey: Key.showMenuBar) as? Bool ?? true
        watchingEnabled = defaults.object(forKey: Key.watchingEnabled) as? Bool ?? false
    }

    func resetPrompt() { prompt = Self.defaultPrompt }
    func resetTemplate() { template = Self.defaultTemplate }

    var llmConfiguration: LLMConfiguration {
        LLMConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            modelName: modelName,
            temperature: temperature,
            maxTokens: maxTokens,
            timeoutSeconds: timeoutSeconds,
            prompt: prompt,
            appendNoThink: appendNoThink
        )
    }
}
