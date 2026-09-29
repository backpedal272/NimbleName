import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Model", systemImage: "brain") { LLMSettingsView() }
            Tab("Prompt", systemImage: "text.quote") { PromptSettingsView() }
            Tab("Naming", systemImage: "textformat") { NamingSettingsView() }
            Tab("Watching", systemImage: "eye") { WatchSettingsView() }
        }
        .frame(width: 600)
    }
}

struct LLMSettingsView: View {
    private var model: AppModel { AppModel.shared }
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var availableModels: [String] = []

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Endpoint") {
                TextField("Base URL", text: $settings.baseURL, prompt: Text(AppSettings.defaultBaseURL))
                SecureField("API key (optional)", text: $settings.apiKey)
                HStack {
                    TextField("Model name", text: $settings.modelName, prompt: Text(AppSettings.defaultModelName))
                    if !availableModels.isEmpty {
                        Menu("Choose") {
                            ForEach(availableModels, id: \.self) { name in
                                Button(name) { settings.modelName = name }
                            }
                        }
                        .fixedSize()
                    }
                }
                HStack(alignment: .top) {
                    Button(isTesting ? "Testing…" : "Test Connection") { testConnection() }
                        .disabled(isTesting)
                    if let testResult {
                        Text(testResult)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Section("Generation") {
                TextField("Temperature", value: $settings.temperature, format: .number)
                TextField("Max tokens", value: $settings.maxTokens, format: .number)
                TextField("Timeout (seconds)", value: $settings.timeoutSeconds, format: .number)
                Stepper("Parallel requests: \(settings.parallelRequests)", value: $settings.parallelRequests, in: 1...4)
                Text("Keep parallel requests at 1 for a local model. Hosted endpoints can take more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let client = LLMClient(config: model.settings.llmConfiguration)
        Task {
            do {
                let models = try await client.listModels()
                availableModels = models
                testResult = models.isEmpty
                    ? "Connected, but the server lists no models."
                    : "Connected. \(models.count) model(s) available; use Choose to pick one."
                if models.count == 1, model.settings.modelName.isEmpty { model.settings.modelName = models[0] }
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}

struct PromptSettingsView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                TextEditor(text: $settings.prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 320)
            } header: {
                Text("Prompt sent with each document image")
            } footer: {
                Text("The model must answer with a JSON object containing date, vendor, description, currency and amount.")
            }
            Section {
                Toggle("Disable model reasoning (Qwen3: /no_think + enable_thinking=false)", isOn: $settings.appendNoThink)
                Button("Reset to Default Prompt") { settings.resetPrompt() }
                    .disabled(settings.prompt == AppSettings.defaultPrompt)
            }
        }
        .formStyle(.grouped)
    }
}

struct NamingSettingsView: View {
    private var model: AppModel { AppModel.shared }

    private static let sampleWithAmount: ExtractedFields = {
        var fields = ExtractedFields()
        fields.date = "2024-03-15"; fields.vendor = "Swisscom"; fields.description = "Mobile phone bill"
        fields.currency = "CHF"; fields.amount = "89.00"
        return fields
    }()

    private static let sampleWithoutAmount: ExtractedFields = {
        var fields = ExtractedFields()
        fields.date = "2024-01-08"; fields.vendor = "Landlord"; fields.description = "Rental contract"
        return fields
    }()

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                TextField("Template", text: $settings.template)
                    .font(.system(.body, design: .monospaced))
                Text("Placeholders: {date} {vendor} {description} {currency} {amount}. A parenthesized group is dropped when all its placeholders are empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset to Default Template") { settings.resetTemplate() }
                    .disabled(settings.template == AppSettings.defaultTemplate)
            } header: {
                Text("Filename template")
            }
            Section("Examples") {
                LabeledContent("With amount", value: preview(Self.sampleWithAmount))
                LabeledContent("Without amount", value: preview(Self.sampleWithoutAmount))
            }
            Section("Limits") {
                Stepper("Maximum length: \(settings.maxFilenameLength) characters", value: $settings.maxFilenameLength, in: 40...200, step: 10)
                Toggle("Watched folders: ignore files whose name already follows the template", isOn: $settings.skipAlreadyNamed)
            }
        }
        .formStyle(.grouped)
    }

    private func preview(_ fields: ExtractedFields) -> String {
        FilenameComposer.compose(template: model.settings.template, fields: fields, maxLength: model.settings.maxFilenameLength) + ".pdf"
    }
}

struct WatchSettingsView: View {
    private var model: AppModel { AppModel.shared }
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Watch folders for new documents", isOn: $settings.watchingEnabled)
                Toggle("Notify me when files are ready to rename", isOn: $settings.notifyWhenReady)
            } header: {
                Text("Watching")
            } footer: {
                Text("New files in watched folders are analyzed in the background and appear in the review table. Nothing is renamed without your confirmation.")
            }
            Section("Watched folders") {
                if model.access.watchedFolders.isEmpty {
                    Text("No folders yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.access.watchedFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { model.removeWatchedFolder(folder) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { model.addWatchedFolder() }
            }
            Section("Menu bar") {
                Toggle("Show menu bar icon", isOn: $settings.showMenuBar)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
