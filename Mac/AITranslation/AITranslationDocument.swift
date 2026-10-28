import Foundation

/// Original markup never passes through the model. Only text slots are translated.
struct AITranslationDocument: Codable, Sendable {
	let title: String
	let body: String

	struct Slot: Sendable {
		let text: String
		let translate: Bool
	}

	static func slots(in html: String) -> [Slot] {
		// Keep raw-text/code elements, comments, declarations and quoted attributes intact.
		let pattern = #"(?is)<(script|style|pre|code|svg|math|textarea|noscript)\b(?:[^>"']|"[^"]*"|'[^']*')*>.*?(?:</\1\s*>|$)|<!--[\s\S]*?(?:-->|$)|<![^>]*>|<[/!?]?[a-zA-Z](?:[^>"']|"[^"]*"|'[^']*')*>|[^<]+|<"#
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return [Slot(text: html, translate: false)] }
		let ns = html as NSString
		return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).flatMap { match -> [Slot] in
			let token = ns.substring(with: match.range)
			if token.hasPrefix("<"), token.count > 1 { return [Slot(text: token, translate: false)] }
			return AITranslationClient.chunks(token, limit: 1600).map { part in
				let meaningful = AITranslationClient.plainText(html: part).unicodeScalars.contains { CharacterSet.letters.contains($0) }
				return Slot(text: part, translate: meaningful)
			}
		}
	}

	static func replacingText(_ source: String, with translation: String) -> String {
		let prefix = source.prefix(while: { $0.isWhitespace })
		let suffix = source.reversed().prefix(while: { $0.isWhitespace }).reversed()
		return String(prefix) + AITranslationClient.escapedHTML(translation.trimmingCharacters(in: .whitespacesAndNewlines)) + String(suffix)
	}
}

private struct TranslationCheckpoint: Codable {
	let sources: [String: String]
	let translations: [String: String]
}

extension AITranslationClient {
	func translateDocument(title: String, html: String, configuration: AITranslationConfiguration, apiKey: String, checkpoint: URL? = nil, recovery: (@Sendable (String?) async -> Void)? = nil, progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> AITranslationDocument {
		guard title.count + html.count <= 200_000 else { throw AITranslationError.tooLarge }
		let slots = AITranslationDocument.slots(in: html)
		var sources = ["title": title]
		for (index, slot) in slots.enumerated() where slot.translate { sources[String(index)] = slot.text }
		sources = sources.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		var translations = [String: String]()
		if let checkpoint, let data = try? Data(contentsOf: checkpoint), let saved = try? JSONDecoder().decode(TranslationCheckpoint.self, from: data), saved.sources == sources {
			translations = saved.translations.filter { sources[$0.key] != nil && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		}
		await progress?(translations.count, sources.count)
		var batches = [[String: String]]()
		var batch = [String: String]()
		var size = 0
		for key in sources.keys.sorted(by: { ($0 == "title" ? -1 : Int($0) ?? 0) < ($1 == "title" ? -1 : Int($1) ?? 0) }) where translations[key] == nil {
			guard let text = sources[key] else { continue }
			if size + text.count > 1800, !batch.isEmpty { batches.append(batch); batch = [:]; size = 0 }
			batch[key] = text
			size += text.count
		}
		if !batch.isEmpty { batches.append(batch) }
		for batch in batches {
			try Task.checkCancellation()
			let translated = try await translateBatch(batch, configuration: configuration, apiKey: apiKey, depth: 0, recovery: recovery)
			translations.merge(translated) { _, new in new }
			if let checkpoint {
				try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
				try JSONEncoder().encode(TranslationCheckpoint(sources: sources, translations: translations)).write(to: checkpoint, options: .atomic)
			}
			await recovery?(nil)
			await progress?(translations.count, sources.count)
		}
		let body = slots.enumerated().map { index, slot in
			guard slot.translate, let text = translations[String(index)] else { return slot.text }
			return AITranslationDocument.replacingText(slot.text, with: text)
		}.joined()
		return AITranslationDocument(title: translations["title"] ?? title, body: body)
	}

	static func parseTranslatedSlots(_ output: String, expectedKeys: Set<String>) throws -> [String: String] {
		var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
		if text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") {
			let header = text[..<newline].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if header == "```" || header == "```json" {
				text = String(text[text.index(after: newline)..<text.index(text.endIndex, offsetBy: -3)]).trimmingCharacters(in: .whitespacesAndNewlines)
			}
		}
		guard let data = text.data(using: .utf8), let translated = try? JSONDecoder().decode([String: String].self, from: data), Set(translated.keys) == expectedKeys, translated.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
			throw AITranslationError.invalidTranslation
		}
		return translated
	}

	private func translateBatch(_ batch: [String: String], configuration: AITranslationConfiguration, apiKey: String, depth: Int, recovery: (@Sendable (String?) async -> Void)?) async throws -> [String: String] {
		try Task.checkCancellation()
		do {
			let input = try JSONEncoder().encode(batch)
			let output = try await translate(String(decoding: input, as: UTF8.self), configuration: configuration, apiKey: apiKey, structured: true)
			return try Self.parseTranslatedSlots(output, expectedKeys: Set(batch.keys))
		} catch let error as AITranslationError {
			switch error {
			case .truncated, .invalidResponse, .invalidTranslation, .empty:
				guard depth < 5 else { throw error }
				await recovery?("正在拆分长段，自动重试")
				let keys = batch.keys.sorted()
				if keys.count > 1 {
					let leftKeys = Set(keys.prefix(keys.count / 2))
					let left = try await translateBatch(batch.filter { leftKeys.contains($0.key) }, configuration: configuration, apiKey: apiKey, depth: depth + 1, recovery: recovery)
					let right = try await translateBatch(batch.filter { !leftKeys.contains($0.key) }, configuration: configuration, apiKey: apiKey, depth: depth + 1, recovery: recovery)
					return left.merging(right) { _, new in new }
				}
				guard let key = keys.first, let text = batch[key], text.count > 120 else { throw error }
				let parts = Self.chunks(text, limit: max(1, text.count / 2))
				var result = ""
				for part in parts {
					let translated = try await translateBatch([key: part], configuration: configuration, apiKey: apiKey, depth: depth + 1, recovery: recovery)
					guard let value = translated[key] else { throw AITranslationError.invalidResponse }
					result += value
				}
				return [key: result]
			default: throw error
			}
		}
	}
}
