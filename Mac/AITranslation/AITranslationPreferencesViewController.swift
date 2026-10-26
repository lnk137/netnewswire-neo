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
		view = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 540))
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
		let hint = NSTextField(wrappingLabelWithString: "开启后会翻译现有及后续抓取的非中文 RSS 文章，并发送到所填 API 服务，产生相应调用费用。关闭后停止后台队列。译文保存在本机，原文始终保留。")
		hint.textColor = .secondaryLabelColor
		let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
		let test = NSButton(title: "测试连接", target: self, action: #selector(testConnection))
		let authorize = NSButton(title: "重新授权钥匙串", target: self, action: #selector(authorizeKeychain))
		let actions = NSStackView(views: [save, test, authorize])
		actions.spacing = 12
		status.textColor = .secondaryLabelColor
		let progressView = AITranslationProgressView()
		let stack = NSStackView(views: [form, automatic, hint, actions, progressView, status])
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
			status.widthAnchor.constraint(equalTo: stack.widthAnchor),
			progressView.widthAnchor.constraint(equalTo: stack.widthAnchor)
		])
		NotificationCenter.default.addObserver(self, selector: #selector(updateProgress), name: AITranslationService.changed, object: nil)
		updateProgress()
	}

	@objc private func updateProgress() { status.stringValue = AITranslationService.shared.progress }

	@objc private func authorizeKeychain() {
		let key = AITranslationSettings.shared.readAPIKey(allowPrompt: true)
		status.stringValue = key.isEmpty ? "未取得密钥。可在上方重新输入并保存。" : "钥匙串已授权，可点击继续翻译。"
	}

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


/// The same live queue view is visible in the reader and in preferences.
@MainActor final class AITranslationProgressView: NSView {
	private let summary = NSTextField(labelWithString: "")
	private let current = NSTextField(labelWithString: "")
	private let indicator = NSProgressIndicator()
	private lazy var pause = NSButton(title: "暂停翻译", target: self, action: #selector(togglePause))

	init() {
		super.init(frame: .zero)
		indicator.style = .bar
		indicator.isIndeterminate = false
		indicator.minValue = 0
		indicator.maxValue = 1
		summary.font = .systemFont(ofSize: 12, weight: .medium)
		current.font = .systemFont(ofSize: 11)
		current.textColor = .secondaryLabelColor
		for label in [summary, current] {
			label.lineBreakMode = .byTruncatingTail
			label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		}
		let header = NSStackView(views: [summary, pause])
		header.distribution = .fill
		pause.setContentHuggingPriority(.required, for: .horizontal)
		pause.setContentCompressionResistancePriority(.required, for: .horizontal)
		let stack = NSStackView(views: [header, indicator, current])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 5
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			header.widthAnchor.constraint(equalTo: stack.widthAnchor),
			indicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
			current.widthAnchor.constraint(equalTo: stack.widthAnchor)
		])
		NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AITranslationService.changed, object: nil)
		refresh()
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	@objc private func togglePause() { AITranslationService.shared.togglePause(); refresh() }
	@objc private func refresh() {
		let service = AITranslationService.shared
		summary.stringValue = service.progress
		summary.toolTip = service.progress
		current.stringValue = service.currentDetail
		current.toolTip = service.currentDetail
		indicator.doubleValue = service.fractionCompleted
		indicator.setAccessibilityLabel("翻译进度")
		pause.title = service.pauseButtonTitle
		pause.isEnabled = service.canPause
	}
}
