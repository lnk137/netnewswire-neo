// Run with scripts/test-ai-translation.sh. This executable does not contact live services.
import Foundation

final class TranslationMockProtocol: URLProtocol, @unchecked Sendable {
	nonisolated(unsafe) static var responses: [(Int, String)] = []
	nonisolated(unsafe) static var requests: [URLRequest] = []
	static let lock = NSLock()
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		Self.lock.lock()
		Self.requests.append(request)
		let (status, body) = Self.responses.removeFirst()
		Self.lock.unlock()
		let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Data(body.utf8))
		client?.urlProtocolDidFinishLoading(self)
	}
	override func stopLoading() {}
}

actor ProgressRecorder {
	var values = [(Int, Int)]()
	func record(_ done: Int, _ total: Int) { values.append((done, total)) }
	func valid() -> Bool { values.map { $0.0 } == [0, 1] && values.allSatisfy { $0.1 == 1 } }
}

@main struct AITranslationCoreTests {
	static func main() async throws {
		for text in ["这是一篇中文文章，介绍如何构建 Agent、API 和 Claude Code 工程实践。", "這是一篇繁體中文文章，介紹人工智慧的應用與工程實踐。", "中文标题"] {
			assert(AITranslationClient.isChinese(text), text)
		}
		for text in ["Build reliable AI agents with retrieval, tools and memory.", "The Chinese term 智能 means intelligence. This article discusses agent engineering in English.", "これは日本語の記事です。人工知能について説明します。", ""] {
			assert(!AITranslationClient.isChinese(text), text)
		}
		var config = AITranslationConfiguration()
		assert(config.endpoint?.absoluteString == "https://a6api.com/v1/chat/completions")
		config.baseURL = "https://example.com"
		assert(config.endpoint?.path == "/v1/chat/completions")
		config.baseURL = "https://example.com/v1/chat/completions"
		assert(config.endpoint?.path == "/v1/chat/completions")
		config.baseURL = "https://example.com?api_key=secret"
		assert(config.endpoint == nil)
		config.baseURL = "http://example.com"
		assert(config.endpoint == nil)
		config = AITranslationConfiguration()
		let source = String(repeating: "🙂文章paragraph\n", count: 1700)
		let chunks = AITranslationClient.chunks(source)
		assert(chunks.joined() == source && chunks.allSatisfy { $0.count <= 4000 })
		let key = AITranslationClient.cacheKey(accountID: "a", articleID: "b", text: source, configuration: config)
		config.targetLanguage = "日本語"
		assert(key != AITranslationClient.cacheKey(accountID: "a", articleID: "b", text: source, configuration: config))
		assert(!AITranslationClient.escapedHTML("<script>alert('x')</script>").contains("<script>"))
		assert(AITranslationClient.plainText(html: "<style>bad</style><p>Hello &amp; RSS</p><script>bad</script>") == "Hello & RSS")
		let success = "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"你好\"}}]}"
		let parsed = try AITranslationClient.translation(from: Data(success.utf8))
		assert(parsed == "你好")
		for bad in ["{}", "{\"choices\":[{\"message\":{\"content\":null}}]}", success.replacingOccurrences(of: "stop", with: "length")] {
			do { _ = try AITranslationClient.translation(from: Data(bad.utf8)); assertionFailure("Invalid response accepted") }
			catch {}
		}
		let sessionConfig = URLSessionConfiguration.ephemeral
		sessionConfig.protocolClasses = [TranslationMockProtocol.self]
		let client = AITranslationClient(session: URLSession(configuration: sessionConfig))
		TranslationMockProtocol.responses = [(503, ""), (200, success)]
		let recorder = ProgressRecorder()
		let translated = try await client.translate("Hello", configuration: config, apiKey: "test-key") { done, total in await recorder.record(done, total) }
		let progressValid = await recorder.valid()
		assert(progressValid)
		assert(translated == "你好" && TranslationMockProtocol.requests.count == 2)
		assert(TranslationMockProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
		TranslationMockProtocol.responses = [(401, "private provider error")]
		do { _ = try await client.translate("Hello", configuration: config, apiKey: "test-key"); assertionFailure("401 accepted") }
		catch { assert(error.localizedDescription.contains("401") && !error.localizedDescription.contains("private provider error")) }
		let html = #"<h2 id="section">A heading</h2><p class='body'>Read <a href="https://example.com/?q=a&gt;b" title="a > b">this link</a> now.</p><!-- keep > --><img src='image.png' srcset='image@2x.png 2x'><ul><li>Item</li></ul><pre><code>if x < y { print("hello") }</code></pre><style>.x{color:red}</style><script>if (a < b) go()</script><svg><text>Keep</text></svg>"#
		let slots = AITranslationDocument.slots(in: html)
		assert(slots.map(\.text).joined() == html)
		assert(!slots.filter(\.translate).contains { $0.text.contains("print") || $0.text.contains("color:red") || $0.text.contains("go()") || $0.text == "Keep" })
		for fixture in ["<p title='a > b'>Hello &amp; world</p>", "<!-- unclosed comment", "<pre>unclosed code", "<p>1 < 2</p>", String(repeating: "hello ", count: 1000), "<iframe src='video'>fallback</iframe>"] {
			assert(AITranslationDocument.slots(in: fixture).map(\.text).joined() == fixture)
		}
		var mapped = ["title": "中文标题"]
		for (index, slot) in slots.enumerated() where slot.translate { mapped[String(index)] = "译文 <script>attack()</script>" }
		let mappedJSON = String(decoding: try JSONEncoder().encode(mapped), as: UTF8.self)
		func envelope(_ content: String) throws -> String {
			String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]]), as: UTF8.self)
		}
		TranslationMockProtocol.responses = [(200, try envelope(mappedJSON))]
		let document = try await client.translateDocument(title: "Original title", html: html, configuration: config, apiKey: "test-key")
		assert(document.title == "中文标题")
		let originalMarkup = slots.filter { !$0.translate }.map(\.text)
		let translatedMarkup = AITranslationDocument.slots(in: document.body).filter { !$0.translate }.map(\.text)
		assert(originalMarkup == translatedMarkup, "Markup changed")
		assert(document.body.contains("&lt;script&gt;attack()&lt;/script&gt;"))
		assert(document.body.contains(#"href="https://example.com/?q=a&gt;b" title="a > b""#))
		let decoded = try JSONDecoder().decode(AITranslationDocument.self, from: JSONEncoder().encode(document))
		assert(decoded.body == document.body)
		for malformed in ["{}", "{\"title\":\"标题\",\"unexpected\":\"多余\"}", "not json"] {
			TranslationMockProtocol.responses = [(200, try envelope(malformed))]
			do { _ = try await client.translateDocument(title: "Title", html: "<p>Hello</p>", configuration: config, apiKey: "test-key"); assertionFailure("Invalid slot mapping accepted") }
			catch { assert(error is AITranslationError) }
		}

		print("AI translation tests passed: endpoint validation, lossless chunking, cache invalidation, HTML escaping, response validation, retries, authentication failures, preserved HTML/link/image/code structure, slot validation and injection escaping.")
	}
}
