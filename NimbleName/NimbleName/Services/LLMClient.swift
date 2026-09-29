import Foundation

nonisolated struct LLMConfiguration: Sendable {
    var baseURL: String
    var apiKey: String
    var modelName: String
    var temperature: Double
    var maxTokens: Int
    var timeoutSeconds: Int
    var prompt: String
    var appendNoThink: Bool
}

nonisolated enum LLMError: LocalizedError {
    case invalidBaseURL(String)
    case httpStatus(Int, String)
    case emptyContent(String)
    case noJSON(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url): "Invalid base URL: \(url)"
        case .httpStatus(let code, let body): "Server returned HTTP \(code): \(body)"
        case .emptyContent(let reason): "Model returned no content (finish reason: \(reason)). Try raising max tokens."
        case .noJSON(let content): "Model answer is not JSON: \(content.prefix(120))"
        case .malformedResponse: "Unexpected response format from the server"
        }
    }
}

/// Minimal OpenAI-compatible chat completions client (LM Studio, Ollama, OpenAI, ...).
nonisolated struct LLMClient: Sendable {
    let config: LLMConfiguration

    func extractFields(imageJPEG: Data) async throws -> ExtractedFields {
        do {
            return try await requestFields(imageJPEG: imageJPEG, structured: true)
        } catch LLMError.httpStatus(let code, _) where code == 400 {
            // Endpoint rejects response_format / chat_template_kwargs; retry with a plain request.
            return try await requestFields(imageJPEG: imageJPEG, structured: false)
        } catch LLMError.noJSON {
            // Some servers (oMLX 0.6 with a thinking model) let the model's reasoning leak into the
            // constrained output, e.g. `["date:"]` or `[{"_type": "thinking", ...}]`. Retry unconstrained.
            return try await requestFields(imageJPEG: imageJPEG, structured: false)
        }
    }

    /// Strict schema for the answer: exactly the five fields, all strings.
    static var fieldsSchema: [String: Any] {
        let keys = ["date", "vendor", "description", "currency", "amount"]
        return [
            "type": "object",
            "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, ["type": "string"]) }),
            "required": keys,
            "additionalProperties": false,
        ]
    }

    func listModels() async throws -> [String] {
        var request = URLRequest(url: try endpoint("models"))
        request.timeoutInterval = 15
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            throw LLMError.malformedResponse
        }
        return list.compactMap { $0["id"] as? String }
    }

    // MARK: - Request

    private func endpoint(_ path: String) throws -> URL {
        let trimmed = config.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/" + path), url.scheme != nil, url.host != nil else {
            throw LLMError.invalidBaseURL(config.baseURL)
        }
        return url
    }

    private func authorize(_ request: inout URLRequest) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.httpStatus(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    /// `structured` sends `response_format: json_schema` and, when the no-think setting is on,
    /// `chat_template_kwargs.enable_thinking = false`. A plain request sends neither.
    private func requestFields(imageJPEG: Data, structured: Bool) async throws -> ExtractedFields {
        var text = config.prompt
        if config.appendNoThink { text += "\n/no_think" }
        let dataURL = "data:image/jpeg;base64," + imageJPEG.base64EncodedString()

        var payload: [String: Any] = [
            "model": config.modelName,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": text],
                        ["type": "image_url", "image_url": ["url": dataURL]],
                    ],
                ],
            ],
        ]
        if structured {
            payload["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "document_fields", "strict": true, "schema": Self.fieldsSchema],
            ]
            if config.appendNoThink {
                payload["chat_template_kwargs"] = ["enable_thinking": false]
            }
        }

        var request = URLRequest(url: try endpoint("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(max(10, config.timeoutSeconds))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return try Self.parseFields(fromResponse: data)
    }

    // MARK: - Parsing

    static func parseFields(fromResponse data: Data) throws -> ExtractedFields {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMError.malformedResponse
        }
        let content = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            throw LLMError.emptyContent(String(describing: first["finish_reason"] ?? "unknown"))
        }
        return try parseFields(fromContent: content)
    }

    /// Extracts the first {...} object from the model text, tolerating code fences and prose around it.
    static func parseFields(fromContent content: String) throws -> ExtractedFields {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end else {
            throw LLMError.noJSON(content)
        }
        let jsonText = String(content[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any] else {
            throw LLMError.noJSON(content)
        }

        var fields = ExtractedFields()
        var recognizedKeys = 0
        for (key, value) in object {
            let text: String
            switch value {
            case let string as String: text = string
            case let number as NSNumber: text = number.stringValue
            default: text = ""
            }
            switch key.lowercased() {
            case "date": fields.date = text
            case "vendor": fields.vendor = text
            case "description": fields.description = text
            case "currency": fields.currency = text
            case "amount": fields.amount = text
            default: continue
            }
            recognizedKeys += 1
        }
        // An object without any expected key is not an answer (e.g. leaked reasoning).
        guard recognizedKeys > 0 else { throw LLMError.noJSON(content) }
        fields.normalize()
        return fields
    }
}
