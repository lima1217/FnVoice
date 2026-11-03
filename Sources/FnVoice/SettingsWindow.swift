import AppKit
import FnVoiceCore

/// LLM settings: Base URL, API Key (Keychain; clearing the field deletes it), Model, Test, Save.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: AppSettings
    private let onSave: () -> Void

    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var testTask: Task<Void, Never>?

    init(settings: AppSettings, onSave: @escaping () -> Void) {
        self.settings = settings
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "LLM Refinement Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        baseURLField.stringValue = settings.llmBaseURL
        apiKeyField.stringValue = Keychain.readAPIKey()
        modelField.stringValue = settings.llmModel
        statusLabel.stringValue = ""
        window?.center()
        NSApp.forceActivate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(baseURLField)
    }

    private var formConfig: LLMConfig {
        LLMConfig(baseURL: baseURLField.stringValue, apiKey: apiKeyField.stringValue, model: modelField.stringValue)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        baseURLField.placeholderString = "https://api.deepseek.com/v1"
        apiKeyField.placeholderString = "sk-… (leave empty for local servers)"
        modelField.placeholderString = "deepseek-chat"
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor

        testButton.target = self
        testButton.action = #selector(test)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let clearKey = NSButton(title: "Clear", target: self, action: #selector(clearKey))
        clearKey.controlSize = .small

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "API Base URL:"), baseURLField, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "API Key:"), apiKeyField, clearKey],
            [NSTextField(labelWithString: "Model:"), modelField, NSGridCell.emptyContentView],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300
        grid.rowSpacing = 10
        grid.columnSpacing = 8

        let buttons = NSStackView(views: [statusLabel, testButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
    }

    @objc private func clearKey() {
        apiKeyField.stringValue = ""
        statusLabel.stringValue = "API key cleared — press Save to apply"
    }

    @objc private func test() {
        let config = formConfig
        guard config.isConfigured else {
            setStatus("Enter a valid Base URL (http/https) and a model", ok: false)
            return
        }
        testTask?.cancel()
        testButton.isEnabled = false
        setStatus("Testing…", ok: nil)
        testTask = Task { @MainActor in
            defer { self.testButton.isEnabled = true }
            let client = OpenAICompatibleClient(config: config, timeout: .seconds(10))
            let start = ContinuousClock.now
            do {
                let sample = "我在用配森写一个杰森解析器"
                let out = try await client.complete(system: RefinementPrompt.system, user: RefinementPrompt.user(sample))
                let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
                let cleaned = OutputSanitizer.clean(out, original: sample)
                self.setStatus("OK (\(ms) ms): \(cleaned)", ok: true)
            } catch let e as LLMError {
                self.setStatus(e.userMessage, ok: false)
            } catch {
                self.setStatus(error.localizedDescription, ok: false)
            }
        }
    }

    @objc private func save() {
        let config = formConfig
        settings.llmBaseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.llmModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Keychain.writeAPIKey(config.apiKey) else {
            setStatus("Couldn't save the API key to the Keychain", ok: false)
            return
        }
        onSave()
        setStatus(config.isConfigured ? "Saved" : "Saved (incomplete: refinement stays off until URL and model are set)", ok: config.isConfigured)
    }

    private func setStatus(_ text: String, ok: Bool?) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        statusLabel.textColor = switch ok {
        case .some(true): .systemGreen
        case .some(false): .systemRed
        case .none: .secondaryLabelColor
        }
    }

    func windowWillClose(_ notification: Notification) {
        testTask?.cancel()
    }
}

extension NSApplication {
    /// macOS 14's cooperative `activate()` is often refused for a background menu-bar app, which
    /// leaves the window visible but not key, so typing goes to the previously active app.
    func forceActivate() {
        activate(ignoringOtherApps: true)
    }
}
