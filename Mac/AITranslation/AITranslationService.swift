import Foundation
import Articles
import Account

@MainActor final class AITranslationService {
	static let shared = AITranslationService()
	static let changed = Notification.Name("AITranslationStateChanged")
	private struct Job {
		let article: Article
		let key: String
		let configuration: AITranslationConfiguration
		let html: String
		var automatic: Bool
	}
	struct Entry: Identifiable {
		let id: String
		let article: Article
		let feedName: String
		let feedKey: String
	}
	private(set) var entries = [String: Entry]()
	private var cachedKeys = Set<String>()
	var orderedEntries: [Entry] {
		let positions = Dictionary(uniqueKeysWithValues: queue.enumerated().map { ($0.element.key, $0.offset + 1) })
		return entries.values.sorted {
			let lhs = active[$0.id] != nil ? 0 : positions[$0.id] ?? Int.max
			let rhs = active[$1.id] != nil ? 0 : positions[$1.id] ?? Int.max
			if lhs != rhs { return lhs < rhs }
			return $0.article.logicalDatePublished > $1.article.logicalDatePublished
		}
	}
	func state(for entry: Entry) -> String {
		if cachedKeys.contains(entry.id) { return "已完成" }
		if skippedIDs.contains(entry.article.accountID + ":" + entry.article.articleID) { return "无需翻译" }
		if failures[entry.id] != nil { return "失败" }
		if active[entry.id] != nil { return isPaused ? "暂停中" : "翻译中" }
		if queue.contains(where: { $0.key == entry.id }) { return "排队中" }
		return "未翻译"
	}
	func position(for entry: Entry) -> Int? {
		queue.firstIndex(where: { $0.key == entry.id }).map { $0 + 1 }
	}
	func error(for entry: Entry) -> String? { failures[entry.id] }
	var cachedCount: Int { cachedKeys.count }
	private func register(_ article: Article) {
		let key = key(for: article)
		let outdated = entries.values.filter { $0.id != key && $0.article.accountID == article.accountID && $0.article.articleID == article.articleID }.map(\.id)
		for id in outdated { entries[id] = nil; cachedKeys.remove(id) }
		queue.removeAll { outdated.contains($0.key) }
		entries[key] = Entry(id: key, article: article, feedName: article.feed?.nameForDisplay ?? article.feedID, feedKey: article.accountID + ":" + article.feedID)
		if FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(key + ".json").path) { cachedKeys.insert(key) }
		if isChinese(article) { skippedIDs.insert(article.accountID + ":" + article.articleID) }
	}
	private var queue = [Job]()
	private struct RunningJob {
		let job: Job
		let generation: Int
		var done = 0
		var total = 0
		var recovery: String?
	}
	private var active = [String: RunningJob]()
	private let pool = AITranslationWorkerPool()
	private var generation = 0
	private var retainedCancellationKeys = Set<String>()
	private var scanner: Task<Void, Never>?
	private var failures = [String: String]()
	private var backgroundPaused = false
	private(set) var isPaused = false
	private(set) var isScanning = false
	var chunkCompleted: Int { active.values.reduce(0) { $0 + $1.done } }
	var chunkTotal: Int { active.values.reduce(0) { $0 + $1.total } }
	var recoveryMessage: String? { active.values.compactMap(\.recovery).first }
	var activeCount: Int { active.count }
	var concurrency: Int { AITranslationSettings.shared.concurrency }
	func chunkProgress(for entry: Entry) -> String? {
		guard let running = active[entry.id], running.total > 0 else { return nil }
		return "\(running.done) / \(running.total)"
	}
	var failedCount: Int { failures.count }
	private var skippedIDs = Set<String>()
	var skippedChinese: Int { skippedIDs.count }
	var currentTitle: String? { active.count > 1 ? "正在同时翻译 \(active.count) 篇文章" : active.values.first?.job.article.title }
	var canPause: Bool { pendingCount > 0 || isScanning || isPaused || backgroundPaused }
	var pauseButtonTitle: String { isPaused || backgroundPaused ? "继续翻译" : "暂停翻译" }
	var totalCount: Int { completed + pendingCount }
	var fractionCompleted: Double {
		guard totalCount > 0 else { return 0 }
		let chunk = chunkTotal > 0 ? Double(chunkCompleted) / Double(chunkTotal) : 0
		return (Double(completed) + chunk) / Double(totalCount)
	}
	private var notificationPending = false
	private(set) var lastError: String?
	private(set) var completed = 0
	private let cacheDirectory: URL
	var pendingCount: Int { queue.count + active.count }
	var progress: String {
		let counts = "已完成 \(completed) / \(totalCount) 篇 · 待处理 \(pendingCount) 篇 · 跳过中文 \(skippedChinese) 篇"
		if let lastError { return "翻译失败，已暂停 · \(lastError)" }
		if isPaused { return "已暂停 · \(counts)" }
		if isScanning { return "正在扫描订阅文章… · \(counts)" }
		if pendingCount > 0 { return "翻译中 · \(counts)" }
		return completed > 0 ? "本次翻译完成 · \(counts)" : "就绪 · \(counts)"
	}
	var currentDetail: String {
		guard let currentTitle else { return isPaused ? "点击继续翻译可恢复队列" : "中文文章自动跳过，译文缓存于本机" }
		let part = chunkTotal > 0 ? " · 分段 \(min(chunkCompleted + 1, chunkTotal))/\(chunkTotal)" : ""
		return "\(isPaused ? "已暂停" : "当前")：\(currentTitle)\(part)"
	}

	func togglePause() {
		if isPaused || backgroundPaused {
			isPaused = false
			backgroundPaused = false
			lastError = nil
			if let key = queue.first?.key { failures[key] = nil }
			scanExistingArticles()
			startWorker()
		} else {
			isPaused = true
			retainedCancellationKeys.formUnion(active.keys)
			scanner?.cancel()
			pool.cancelAll()
		}
		postChange()
	}

	private init() {
		let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		cacheDirectory = root.appendingPathComponent("NetNewsWire Neo/Translations", isDirectory: true)
		pool.onAvailable = { [weak self] in self?.startWorker() }
		NotificationCenter.default.addObserver(self, selector: #selector(concurrencyChanged), name: AITranslationSettings.concurrencyChanged, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AITranslationSettings.changed, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(articlesDownloaded(_:)), name: .AccountDidDownloadArticles, object: nil)
	}

	func start() { scanExistingArticles() }

	func sourceText(_ article: Article) -> String {
		let body = [article.contentText, article.contentHTML.map(AITranslationClient.plainText), article.summary].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
		return [article.title ?? "", body].joined(separator: "\n\n")
	}

	func key(for article: Article, configuration: AITranslationConfiguration? = nil) -> String {
		AITranslationClient.cacheKey(accountID: article.accountID, articleID: article.articleID, text: sourceText(article) + (article.contentHTML ?? ""), configuration: configuration ?? AITranslationSettings.shared.configuration)
	}

	func isChinese(_ article: Article) -> Bool { AITranslationClient.isChinese(sourceText(article)) }

	func cachedDocument(for article: Article) -> AITranslationDocument? {
		guard !isChinese(article) else { return nil }
		guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(key(for: article) + ".json")) else { return nil }
		return try? JSONDecoder().decode(AITranslationDocument.self, from: data)
	}

	func cachedTranslation(for article: Article) -> String? {
		guard let document = cachedDocument(for: article) else { return nil }
		return document.title + "\n\n" + AITranslationClient.plainText(html: document.body)
	}

	func status(for article: Article) -> String {
		if isChinese(article) { return "中文文章，无需翻译" }
		let key = key(for: article)
		if active[key]?.generation == generation { return isPaused ? "已暂停" : "正在翻译…" }
		if let failure = failures[key] { return failure }
		if let index = queue.firstIndex(where: { $0.key == key }) { return "排队第 \(index + 1) 篇" }
		return cachedTranslation(for: article) == nil ? "" : "译文已缓存"
	}

	func enqueue(_ article: Article, automatic: Bool = false) {
		let configuration = AITranslationSettings.shared.configuration
		register(article)
		postChange()
		if automatic && (!configuration.automaticallyTranslate || backgroundPaused) { return }
		let text = sourceText(article)
		guard !AITranslationClient.isChinese(text) else {
			skippedIDs.insert(article.accountID + ":" + article.articleID)
			postChange()
			return
		}
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		let key = key(for: article, configuration: configuration)
		if automatic && failures[key] != nil { return }
		if !automatic { failures[key] = nil }
		guard !FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(key + ".json").path) else { return }
		if active[key]?.generation == generation { return }
		if let index = queue.firstIndex(where: { $0.key == key }) {
			if !automatic {
				var job = queue.remove(at: index)
				job.automatic = false
				queue.insert(job, at: 0)
				postChange()
				startWorker()
			}
			return
		}
		failures[key] = nil
		lastError = nil
		let job = Job(article: article, key: key, configuration: configuration, html: article.contentHTML ?? "<p>" + AITranslationClient.escapedHTML(article.contentText ?? article.summary ?? "").replacingOccurrences(of: "\n", with: "<br>") + "</p>", automatic: automatic)
		if automatic { queue.append(job) } else { queue.insert(job, at: 0) }
		postChange()
		startWorker()
	}

	func stopBackgroundTranslation() {
		queue.removeAll(where: { $0.automatic })
		scanner?.cancel()
		for (key, running) in active where running.job.automatic { pool.cancel(key) }
		postChange()
	}

	@objc private func settingsChanged() {
		scanner?.cancel()
		queue.removeAll()
		generation += 1
		retainedCancellationKeys.removeAll()
		pool.cancelAll()
		backgroundPaused = false
		isPaused = false
		lastError = nil
		failures.removeAll()
		entries.removeAll()
		cachedKeys.removeAll()
		skippedIDs.removeAll()
		completed = 0
		scanExistingArticles()
		postChange()
	}

	@objc private func articlesDownloaded(_ note: Notification) {
		let new = note.userInfo?[Account.UserInfoKey.newArticles] as? Set<Article> ?? []
		let updated = note.userInfo?[Account.UserInfoKey.updatedArticles] as? Set<Article> ?? []
		for article in new.union(updated).sorted(by: { ($0.datePublished ?? .distantPast) > ($1.datePublished ?? .distantPast) }) {
			enqueue(article, automatic: true)
		}
	}

	private func scanExistingArticles() {
		guard !backgroundPaused, !isPaused else { return }
		scanner?.cancel()
		scanner = Task { [weak self] in
			guard let self else { return }
			self.isScanning = true
			self.postChange()
			defer { self.isScanning = false; self.postChange() }
			for account in AccountManager.shared.activeAccounts {
				for feed in account.flattenedFeeds() {
					guard !Task.isCancelled else { return }
					let articles = await account.fetchArticlesAsync(.feed(feed))
					guard !Task.isCancelled else { return }
					for (index, article) in articles.sorted(by: { ($0.datePublished ?? .distantPast) > ($1.datePublished ?? .distantPast) }).enumerated() {
						guard !Task.isCancelled else { return }
						if index.isMultiple(of: 20) { await Task.yield() }
						self.enqueue(article, automatic: true)
					}
					await Task.yield()
				}
			}
		}
	}

	@objc private func concurrencyChanged() {
		startWorker()
		postChange()
	}

	private func startWorker() {
		pool.setLimit(concurrency)
		while pool.count < pool.limit, !queue.isEmpty, !isPaused {
			// A cancelled request from the previous settings may still be draining.
			guard !pool.contains(queue[0].key) else { break }
			let job = queue.removeFirst()
			let jobGeneration = generation
			active[job.key] = RunningJob(job: job, generation: jobGeneration)
			pool.start(job.key) { [weak self] in
				await self?.run(job, generation: jobGeneration)
			}
		}
		postChange()
	}

	private func run(_ job: Job, generation jobGeneration: Int) async {
		defer { active[job.key] = nil; postChange() }
		do {
			let translation = try await AITranslationClient().translateDocument(title: job.article.title ?? "", html: job.html, configuration: job.configuration, apiKey: AITranslationSettings.shared.apiKey, checkpoint: cacheDirectory.appendingPathComponent(job.key + ".partial.json"), recovery: { [weak self] message in
				await self?.updateRecovery(message, key: job.key)
			}) { [weak self] done, total in
				await self?.updateChunks(done, total: total, key: job.key)
			}
			try Task.checkCancellation()
			guard jobGeneration == generation else { return }
			try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
			try JSONEncoder().encode(translation).write(to: cacheDirectory.appendingPathComponent(job.key + ".json"), options: .atomic)
			try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(job.key + ".partial.json"))
			cachedKeys.insert(job.key)
			completed += 1
		} catch {
			if Task.isCancelled {
				if retainedCancellationKeys.remove(job.key) != nil, jobGeneration == generation { queue.insert(job, at: 0) }
				return
			}
			guard jobGeneration == generation else { return }
			failures[job.key] = error.localizedDescription
			if let contentError = error as? AITranslationError {
				switch contentError {
				case .truncated, .invalidResponse, .empty, .tooLarge: return
				default: break
				}
			}
			queue.insert(job, at: 0)
			if lastError == nil { lastError = error.localizedDescription }
			backgroundPaused = true
			isPaused = true
			scanner?.cancel()
			retainedCancellationKeys.formUnion(active.keys.filter { $0 != job.key })
			for key in active.keys where key != job.key { pool.cancel(key) }
		}
	}

	private func updateRecovery(_ message: String?, key: String) { active[key]?.recovery = message; postChange() }
	private func updateChunks(_ done: Int, total: Int, key: String) {
		active[key]?.done = done
		active[key]?.total = total
		postChange()
	}

	private func postChange() {
		guard !notificationPending else { return }
		notificationPending = true
		Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(100))
			guard let self else { return }
			self.notificationPending = false
			NotificationCenter.default.post(name: Self.changed, object: self)
		}
	}
}
