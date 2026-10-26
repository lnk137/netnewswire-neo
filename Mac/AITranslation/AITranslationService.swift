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
		let text: String
		var automatic: Bool
	}
	private var queue = [Job]()
	private var current: Job?
	private var worker: Task<Void, Never>?
	private var scanner: Task<Void, Never>?
	private var failures = [String: String]()
	private var backgroundPaused = false
	private var retainCancelledJob = false
	private(set) var isPaused = false
	private(set) var isScanning = false
	private(set) var chunkCompleted = 0
	private(set) var chunkTotal = 0
	private var skippedIDs = Set<String>()
	var skippedChinese: Int { skippedIDs.count }
	var currentTitle: String? { current?.article.title }
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
	var pendingCount: Int { queue.count + (current == nil ? 0 : 1) }
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
			failures.removeAll()
			scanExistingArticles()
			startWorker()
		} else {
			isPaused = true
			retainCancelledJob = current != nil
			scanner?.cancel()
			worker?.cancel()
		}
		postChange()
	}

	private init() {
		let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		cacheDirectory = root.appendingPathComponent("NetNewsWire Neo/Translations", isDirectory: true)
		NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AITranslationSettings.changed, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(articlesDownloaded(_:)), name: .AccountDidDownloadArticles, object: nil)
	}

	func start() { scanExistingArticles() }

	func sourceText(_ article: Article) -> String {
		let body = [article.contentText, article.contentHTML.map(AITranslationClient.plainText), article.summary].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
		return [article.title ?? "", body].joined(separator: "\n\n")
	}

	func key(for article: Article, configuration: AITranslationConfiguration? = nil) -> String {
		AITranslationClient.cacheKey(accountID: article.accountID, articleID: article.articleID, text: sourceText(article), configuration: configuration ?? AITranslationSettings.shared.configuration)
	}

	func isChinese(_ article: Article) -> Bool { AITranslationClient.isChinese(sourceText(article)) }

	func cachedTranslation(for article: Article) -> String? {
		guard !isChinese(article) else { return nil }
		return try? String(contentsOf: cacheDirectory.appendingPathComponent(key(for: article) + ".txt"), encoding: .utf8)
	}

	func status(for article: Article) -> String {
		if isChinese(article) { return "中文文章，无需翻译" }
		let key = key(for: article)
		if current?.key == key { return "正在翻译…" }
		if queue.contains(where: { $0.key == key }) { return "已加入翻译队列" }
		if let failure = failures[key] { return failure }
		return cachedTranslation(for: article) == nil ? "" : "译文已缓存"
	}

	func enqueue(_ article: Article, automatic: Bool = false) {
		let configuration = AITranslationSettings.shared.configuration
		if automatic && (!configuration.automaticallyTranslate || backgroundPaused) { return }
		let text = sourceText(article)
		guard !AITranslationClient.isChinese(text) else {
			skippedIDs.insert(article.accountID + ":" + article.articleID)
			postChange()
			return
		}
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		let key = key(for: article, configuration: configuration)
		guard !FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(key + ".txt").path) else { return }
		if current?.key == key { return }
		if let index = queue.firstIndex(where: { $0.key == key }) {
			if !automatic {
				var job = queue.remove(at: index)
				job.automatic = false
				queue.insert(job, at: 0)
			}
			return
		}
		failures[key] = nil
		lastError = nil
		let job = Job(article: article, key: key, configuration: configuration, text: text, automatic: automatic)
		if automatic { queue.append(job) } else { queue.insert(job, at: 0) }
		postChange()
		startWorker()
	}

	func stopBackgroundTranslation() {
		queue.removeAll(where: { $0.automatic })
		scanner?.cancel()
		if current?.automatic == true { worker?.cancel() }
		postChange()
	}

	@objc private func settingsChanged() {
		scanner?.cancel()
		queue.removeAll()
		retainCancelledJob = false
		worker?.cancel()
		backgroundPaused = false
		isPaused = false
		lastError = nil
		failures.removeAll()
		scanExistingArticles()
		postChange()
	}

	@objc private func articlesDownloaded(_ note: Notification) {
		guard AITranslationSettings.shared.configuration.automaticallyTranslate else { return }
		let new = note.userInfo?[Account.UserInfoKey.newArticles] as? Set<Article> ?? []
		let updated = note.userInfo?[Account.UserInfoKey.updatedArticles] as? Set<Article> ?? []
		for article in new.union(updated).sorted(by: { ($0.datePublished ?? .distantPast) > ($1.datePublished ?? .distantPast) }) {
			enqueue(article, automatic: true)
		}
	}

	private func scanExistingArticles() {
		guard AITranslationSettings.shared.configuration.automaticallyTranslate, !backgroundPaused, !isPaused else { return }
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
					for article in articles.sorted(by: { ($0.datePublished ?? .distantPast) > ($1.datePublished ?? .distantPast) }) {
						self.enqueue(article, automatic: true)
					}
					await Task.yield()
				}
			}
		}
	}

	private func startWorker() {
		guard worker == nil, !queue.isEmpty, !isPaused else { return }
		worker = Task { [weak self] in
			guard let self else { return }
			defer {
				self.current = nil
				self.worker = nil
				self.postChange()
				self.startWorker()
			}
			while !self.queue.isEmpty, !Task.isCancelled {
				let job = self.queue.removeFirst()
				self.current = job
				self.chunkCompleted = 0
				self.chunkTotal = 0
				self.postChange()
				do {
					let translation = try await AITranslationClient().translate(job.text, configuration: job.configuration, apiKey: AITranslationSettings.shared.apiKey) { [weak self] done, total in
						await self?.updateChunks(done, total: total)
					}
					try Task.checkCancellation()
					try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
					try translation.write(to: self.cacheDirectory.appendingPathComponent(job.key + ".txt"), atomically: true, encoding: .utf8)
					self.completed += 1
					self.lastError = nil
				} catch {
					if Task.isCancelled {
						if self.retainCancelledJob { self.queue.insert(job, at: 0) }
						self.retainCancelledJob = false
						break
					}
					let message = error.localizedDescription
					self.queue.insert(job, at: 0)
					self.failures[job.key] = message
					self.lastError = message
					// Pause the backlog on failure instead of repeatedly spending quota or retrying invalid credentials.
					self.backgroundPaused = true
					self.scanner?.cancel()
					self.isPaused = true
					break
				}
				self.current = nil
				self.postChange()
			}
		}
	}

	private func updateChunks(_ done: Int, total: Int) {
		chunkCompleted = done
		chunkTotal = total
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
