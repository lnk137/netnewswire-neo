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

@main struct AITranslationCoreTests {
	static func main() async throws {
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
		let translated = try await client.translate("Hello", configuration: config, apiKey: "test-key")
		assert(translated == "你好" && TranslationMockProtocol.requests.count == 2)
		assert(TranslationMockProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
		TranslationMockProtocol.responses = [(401, "private provider error")]
		do { _ = try await client.translate("Hello", configuration: config, apiKey: "test-key"); assertionFailure("401 accepted") }
		catch { assert(error.localizedDescription.contains("401") && !error.localizedDescription.contains("private provider error")) }
		print("AI translation tests passed: endpoint validation, lossless chunking, cache invalidation, HTML escaping, response validation, retries and authentication failures.")
	}
}
