import AppKit

final class AITranslationPreferencesViewController: NSViewController {
	private let baseURL = NSTextField()
	private let model = NSTextField()
	private let language = NSTextField()
	private let apiKey = NSSecureTextField()
	private let concurrency = NSPopUpButton(frame: .zero, pullsDown: false)
	private let automatic = NSButton(checkboxWithTitle: "自动后台翻译", target: nil, action: nil)
	private let onlyUnread = NSButton(checkboxWithTitle: "仅翻译未读文章", target: nil, action: nil)
	private let dateScope = NSButton(checkboxWithTitle: "仅翻译指定日期的文章", target: nil, action: nil)
	private let startDate = NSDatePicker()
	private let endDate = NSDatePicker()
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
		onlyUnread.state = AITranslationSettings.shared.onlyUnread ? .on : .off
		onlyUnread.target = self
		onlyUnread.action = #selector(onlyUnreadChanged)
		concurrency.addItems(withTitles: (1...20).map { "\($0) 篇" })
		concurrency.selectItem(at: AITranslationSettings.shared.concurrency - 1)
		concurrency.target = self
		concurrency.action = #selector(concurrencySelected)
		concurrency.setAccessibilityLabel("并发翻译数量")
		let form = NSGridView(views: [
			[NSTextField(labelWithString: "API 地址"), baseURL],
			[NSTextField(labelWithString: "模型"), model],
			[NSTextField(labelWithString: "API 密钥"), apiKey],
			[NSTextField(labelWithString: "目标语言"), language],
			[NSTextField(labelWithString: "并发翻译"), concurrency]
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
		let settings = AITranslationSettings.shared
		dateScope.state = settings.dateScopeEnabled ? .on : .off
		dateScope.target = self
		dateScope.action = #selector(dateScopeChanged)
		for picker in [startDate, endDate] {
			picker.datePickerStyle = .textFieldAndStepper
			picker.datePickerElements = [.yearMonthDay]
			picker.target = self
			picker.action = #selector(dateScopeChanged)
		}
		startDate.dateValue = settings.dateScopeStart
		endDate.dateValue = settings.dateScopeEnd
		let dates = NSStackView(views: [dateScope, startDate, NSTextField(labelWithString: "至"), endDate])
		dates.spacing = 8
		let scope = NSStackView(views: [automatic, onlyUnread, dates])
		scope.orientation = .vertical
		scope.alignment = .leading
		scope.spacing = 8
		let stack = NSStackView(views: [form, scope, hint, actions, progressView, status])
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

	@objc private func dateScopeChanged() {
		guard startDate.dateValue <= endDate.dateValue else {
			status.stringValue = "开始日期不能晚于结束日期。"
			return
		}
		AITranslationSettings.shared.setDateScope(enabled: dateScope.state == .on, start: startDate.dateValue, end: endDate.dateValue)
		status.stringValue = "翻译日期范围已更新。"
	}
	@objc private func concurrencySelected() { AITranslationSettings.shared.setConcurrency(concurrency.indexOfSelectedItem + 1) }
	@objc private func onlyUnreadChanged() { AITranslationSettings.shared.setOnlyUnread(onlyUnread.state == .on) }
	@objc private func updateProgress() {
		concurrency.selectItem(at: AITranslationSettings.shared.concurrency - 1)
		status.stringValue = AITranslationService.shared.progress
	}

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


/// Compact activity bar with access to the full queue.
@MainActor final class AITranslationProgressView: NSView {
	private let summary = NSTextField(labelWithString: "")
	private lazy var pause = NSButton(title: "暂停", target: self, action: #selector(togglePause))
	private lazy var tasks = NSButton(title: "翻译任务", target: self, action: #selector(showTasks))
	init() {
		super.init(frame: .zero)
		summary.font = .systemFont(ofSize: 11)
		summary.textColor = .secondaryLabelColor
		summary.lineBreakMode = .byTruncatingTail
		summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		for button in [pause, tasks] {
			button.bezelStyle = .rounded
			button.controlSize = .small
			button.font = .systemFont(ofSize: 11)
			button.setContentHuggingPriority(.required, for: .horizontal)
			button.setContentCompressionResistancePriority(.required, for: .horizontal)
		}
		tasks.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
		tasks.imagePosition = .imageLeading
		let stack = NSStackView(views: [summary, pause, tasks])
		stack.spacing = 8
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
		])
		NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AITranslationService.changed, object: nil)
		refresh()
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	@objc private func showTasks() { AITranslationQueueWindow.shared.present() }
	@objc private func togglePause() { AITranslationService.shared.togglePause() }
	@objc private func refresh() {
		let service = AITranslationService.shared
		summary.stringValue = service.lastError != nil ? "翻译失败 · 已暂停" : "\(service.isPaused ? "已暂停" : service.isScanning ? "扫描中" : "AI 翻译") · 翻译中 \(service.activeCount)/\(service.concurrency) · 待处理 \(service.pendingCount) · 已翻译 \(service.cachedCount)"
		summary.toolTip = service.currentDetail
		pause.title = service.isPaused ? "继续" : "暂停"
		pause.isEnabled = service.canPause
	}
}
