import AppKit
import SwiftUI
import Articles
import WebKit
import RSCore

@MainActor final class AITranslationQueueWindow: NSWindowController {
	static let shared = AITranslationQueueWindow()
	private init() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
		window.title = "翻译任务"
		window.minSize = NSSize(width: 820, height: 500)
		window.contentViewController = NSHostingController(rootView: TranslationQueueView())
		window.isReleasedWhenClosed = false
		super.init(window: window)
		window.center()
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	func present() {
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}
}

@MainActor private final class TranslationQueueModel: ObservableObject {
	@Published var entries = [AITranslationService.Entry]()
	init() {
		NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AITranslationService.changed, object: nil)
		refresh()
	}
	@objc func refresh() { entries = AITranslationService.shared.orderedEntries }
}

private struct TranslationQueueView: View {
	@StateObject private var model = TranslationQueueModel()
	@State private var feed: String?
	@State private var filter = "全部"
	@State private var search = ""
	@State private var preview: AITranslationService.Entry?
	private let filters = ["全部", "排队中", "翻译中", "已完成", "失败", "未翻译", "无需翻译"]
	private var service: AITranslationService { .shared }
	private var feeds: [AITranslationService.Entry] {
		var seen = Set<String>()
		return model.entries.filter { seen.insert($0.feedKey).inserted }.sorted { $0.feedName.localizedStandardCompare($1.feedName) == .orderedAscending }
	}
	private var visible: [AITranslationService.Entry] {
		model.entries.filter { entry in
			(feed == nil || entry.feedKey == feed) && (filter == "全部" || service.state(for: entry) == filter) && (search.isEmpty || (entry.article.title ?? "").localizedCaseInsensitiveContains(search) || entry.feedName.localizedCaseInsensitiveContains(search))
		}
	}
	var body: some View {
		NavigationSplitView {
			List(selection: $feed) {
				Label("所有订阅源", systemImage: "tray.full").tag(nil as String?)
				Section("订阅源") {
					ForEach(feeds, id: \.feedKey) { item in
						VStack(alignment: .leading, spacing: 4) {
							Text(item.feedName).lineLimit(1)
							let items = model.entries.filter { $0.feedKey == item.feedKey }
							Text("\(items.filter { service.state(for: $0) == "已完成" }.count) / \(items.count) 篇已翻译")
								.font(.caption).foregroundStyle(.secondary)
						}.padding(.vertical, 5).tag(Optional(item.feedKey))
					}
				}
			}.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
		} detail: {
			VStack(alignment: .leading, spacing: 0) {
				HStack(alignment: .firstTextBaseline) {
					VStack(alignment: .leading, spacing: 6) {
						Text(feeds.first { $0.feedKey == feed }?.feedName ?? "翻译任务").font(.title2.weight(.semibold))
						Text("总队列 \(service.pendingCount) 篇 · 已翻译 \(service.cachedCount) 篇").font(.subheadline).foregroundStyle(.secondary)
					}
					Spacer()
					if service.lastError == nil {
						Button(service.pauseButtonTitle, systemImage: service.isPaused ? "play.fill" : "pause.fill") { service.togglePause() }.disabled(!service.canPause)
					}
				}.padding(24)
				if service.pendingCount > 0 || service.isScanning || service.lastError != nil {
					activityPanel.padding(.horizontal, 24).padding(.bottom, 16)
				}
				if service.failedCount > 0 {
					HStack {
						Label("\(service.failedCount) 篇未完成", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
						Spacer()
						Button("查看并重试") { feed = nil; filter = "失败" }.buttonStyle(.link)
					}.font(.caption).padding(.horizontal, 24).padding(.bottom, 14)
				}
				HStack {
					Picker("状态", selection: $filter) { ForEach(filters, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 125)
					Spacer()
					TextField("搜索文章或订阅源", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
				}.padding(.horizontal, 24).padding(.bottom, 14)
				Divider()
				if visible.isEmpty {
					ContentUnavailableView(service.isScanning ? "正在整理文章" : "没有符合条件的文章", systemImage: "doc.text.magnifyingglass", description: Text("更换订阅源、状态或搜索关键词。"))
				} else {
					List(visible) { entry in row(entry) }.listStyle(.inset)
				}
			}
			.background(Color(nsColor: .windowBackgroundColor))
		}
		.sheet(item: $preview) { entry in
			VStack(alignment: .leading, spacing: 16) {
				HStack { Text(entry.article.title ?? "译文").font(.headline).lineLimit(2); Spacer(); Button("完成") { preview = nil }.keyboardShortcut(.cancelAction) }
				TranslatedArticlePreview(article: entry.article)
			}.padding(24).frame(width: 660, height: 520)
		}
	}
	private var activityPanel: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Image(systemName: service.lastError != nil ? "exclamationmark.circle" : service.isPaused ? "pause.circle" : "character.bubble").foregroundStyle(.secondary)
				Text(service.lastError != nil ? "翻译已暂停" : service.isPaused ? "队列已暂停" : service.currentTitle ?? "正在整理文章")
					.font(.system(size: 12, weight: .medium)).lineLimit(1)
				Spacer()
				if service.lastError != nil {
					Button("重试并继续") { service.togglePause() }.controlSize(.small)
				} else if service.chunkTotal > 0 {
					Text("\(service.chunkCompleted) / \(service.chunkTotal)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
				}
			}
			if let error = service.lastError {
				Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
			} else {
				ProgressView(value: service.chunkTotal > 0 ? Double(service.chunkCompleted) / Double(service.chunkTotal) : 0).controlSize(.small)
				if let message = service.recoveryMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
			}
		}.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
	}

	private func row(_ entry: AITranslationService.Entry) -> some View {
		let state = service.state(for: entry)
		return HStack(spacing: 14) {
			Group {
				if let position = service.position(for: entry) { Text("\(position)").monospacedDigit() }
				else { Image(systemName: state == "已完成" ? "checkmark.circle.fill" : state == "翻译中" ? "arrow.triangle.2.circlepath" : state == "失败" ? "exclamationmark.circle" : "doc.text") }
			}.foregroundStyle(state == "已完成" ? Color.green : state == "翻译中" ? Color.accentColor : Color.secondary).frame(width: 28)
			VStack(alignment: .leading, spacing: 5) {
				Text(entry.article.title ?? "无标题").font(.system(size: 13, weight: .medium)).lineLimit(2)
				HStack { Text(entry.feedName).lineLimit(1); Text("·"); Text(state); if let error = service.error(for: entry) { Text(error).lineLimit(1).help(error) } }.font(.caption).foregroundStyle(.secondary)
			}
			Spacer(minLength: 8)
			if state == "已完成" { Button("查看译文") { preview = entry } }
			else if state != "无需翻译" && state != "翻译中" && state != "暂停中" {
				Button(state == "失败" ? "重试翻译" : service.position(for: entry) == 1 ? "已在队首" : "下一篇翻译") { service.enqueue(entry.article) }.disabled(service.position(for: entry) == 1 && state != "失败").help("当前文章完成后翻译；暂停时请先继续队列")
			}
		}.padding(.vertical, 9)
	}
}

private struct TranslatedArticlePreview: NSViewRepresentable {
	let article: Article
	func makeCoordinator() -> Coordinator { Coordinator() }
	func makeNSView(context: Context) -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = false
		let icons = DetailIconSchemeHandler()
		icons.currentArticle = article
		configuration.setURLSchemeHandler(icons, forURLScheme: ArticleRenderer.imageIconScheme)
		let view = WKWebView(frame: .zero, configuration: configuration)
		view.navigationDelegate = context.coordinator
		return view
	}
	func updateNSView(_ view: WKWebView, context: Context) {
		guard view.url == nil, let document = AITranslationService.shared.cachedDocument(for: article) else { return }
		let rendering = ArticleRenderer.articleHTML(article: article, theme: ArticleThemesManager.shared.currentTheme, translatedTitle: document.title, translatedBody: document.body)
		guard let html = try? MacroProcessor.renderedText(withTemplate: ArticleRenderer.page.html, substitutions: ["title": rendering.title, "style": rendering.style, "body": rendering.html, "baseURL": rendering.baseURL]) else { return }
		view.loadHTMLString(html, baseURL: URL(string: rendering.baseURL))
	}
	final class Coordinator: NSObject, WKNavigationDelegate {
		func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
			if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
				if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
				decisionHandler(.cancel)
			} else { decisionHandler(.allow) }
		}
	}
}
