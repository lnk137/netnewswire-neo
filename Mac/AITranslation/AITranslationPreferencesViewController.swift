import AppKit

final class AITranslationPreferencesViewController: NSViewController {
	private let baseURL = NSTextField()
	private let model = NSTextField()
	private let language = NSTextField()
	private let apiKey = NSSecureTextField()
	private let automatic = NSButton(checkboxWithTitle: "自动后台翻译所有文章", target: nil, action: nil)
	private let status = NSTextField(wrappingLabelWithString: "")
	private var testTask: Task<Void, Never>?

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 480))
		let configuration = AITranslationSettings.shared.configuration
		baseURL.stringValue = configuration.baseURL
		model.stringValue = configuration.model
		language.stringValue = configuration.targetLanguage
		apiKey.placeholderString = AITranslationSettings.shared.apiKey.isEmpty ? "输入 API 密钥" : "已保存至钥匙串；留空保持不变"
		automatic.state = configuration.automaticallyTranslate ? .on : .off
		let form = NSGridView(views: [
			[NSTextField(labelWithString: "API 地址"), baseURL],
			[NSTextField(labelWithString: "模型"), model],
			[NSTextField(labelWithString: "API 密钥"), apiKey],
			[NSTextField(labelWithString: "目标语言"), language]
		])
		form.rowSpacing = 14
		form.columnSpacing = 18
		form.column(at: 0).xPlacement = .trailing
		form.column(at: 1).width = 420
		for field in [baseURL, model, language, apiKey] { field.isEditable = true; field.isSelectable = true }
		baseURL.setAccessibilityLabel("API 地址")
		model.setAccessibilityLabel("模型")
		apiKey.setAccessibilityLabel("API 密钥")
		language.setAccessibilityLabel("目标语言")
		automatic.target = self
		automatic.action = #selector(automaticChanged)
		let hint = NSTextField(wrappingLabelWithString: "开启后会翻译现有及后续抓取的 RSS 文章，并发送到所填 API 服务，产生相应调用费用。关闭后停止后台队列。译文保存在本机，原文始终保留。")
		hint.textColor = .secondaryLabelColor
		let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
		let test = NSButton(title: "测试连接", target: self, action: #selector(testConnection))
		let actions = NSStackView(views: [save, test])
		actions.spacing = 12
		status.textColor = .secondaryLabelColor
		let stack = NSStackView(views: [form, automatic, hint, actions, status])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 22
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
			stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
			stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
			hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
			status.widthAnchor.constraint(equalTo: stack.widthAnchor)
		])
		NotificationCenter.default.addObserver(self, selector: #selector(updateProgress), name: AITranslationService.changed, object: nil)
		updateProgress()
	}

	@objc private func updateProgress() { status.stringValue = AITranslationService.shared.progress }

	private func persist() throws {
		let configuration = AITranslationConfiguration(baseURL: baseURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), model: model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), targetLanguage: language.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), automaticallyTranslate: automatic.state == .on)
		try AITranslationSettings.shared.save(configuration, apiKey: apiKey.stringValue.isEmpty ? nil : apiKey.stringValue)
		apiKey.stringValue = ""
		apiKey.placeholderString = "已保存至钥匙串；留空保持不变"
	}

	@objc private func automaticChanged() {
		do { try persist() } catch {
			automatic.state = AITranslationSettings.shared.configuration.automaticallyTranslate ? .on : .off
			status.stringValue = error.localizedDescription
		}
	}

	@objc private func saveSettings() {
		do { try persist(); status.stringValue = "设置已保存。\(AITranslationService.shared.progress)" }
		catch { status.stringValue = error.localizedDescription }
	}

	@objc private func testConnection(_ sender: NSButton) {
		do { try persist() } catch { status.stringValue = error.localizedDescription; return }
		testTask?.cancel()
		sender.isEnabled = false
		status.stringValue = "正在测试连接…"
		let configuration = AITranslationSettings.shared.configuration
		let key = AITranslationSettings.shared.apiKey
		testTask = Task { [weak self, weak sender] in
			defer { sender?.isEnabled = true }
			do {
				let text = try await AITranslationClient().translate("Hello, RSS reader.", configuration: configuration, apiKey: key)
				self?.status.stringValue = "连接成功：\(text)"
			} catch { self?.status.stringValue = error.localizedDescription }
		}
	}
}
