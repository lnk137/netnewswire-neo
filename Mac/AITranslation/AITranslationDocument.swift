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

extension AITranslationClient {
	func translateDocument(title: String, html: String, configuration: AITranslationConfiguration, apiKey: String, progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> AITranslationDocument {
		guard title.count + html.count <= 200_000 else { throw AITranslationError.tooLarge }
		let slots = AITranslationDocument.slots(in: html)
		var sources = ["title": title]
		for (index, slot) in slots.enumerated() where slot.translate { sources[String(index)] = slot.text }
		sources = sources.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		var batches = [[String: String]]()
		var batch = [String: String]()
		var size = 0
		for key in sources.keys.sorted(by: { ($0 == "title" ? -1 : Int($0) ?? 0) < ($1 == "title" ? -1 : Int($1) ?? 0) }) {
			guard let text = sources[key] else { continue }
			if size + text.count > 2800, !batch.isEmpty { batches.append(batch); batch = [:]; size = 0 }
			batch[key] = text
			size += text.count
		}
		if !batch.isEmpty { batches.append(batch) }
		var translations = [String: String]()
		for (index, batch) in batches.enumerated() {
			try Task.checkCancellation()
			await progress?(index, batches.count)
			let input = try JSONEncoder().encode(batch)
			let output = try await translate(String(decoding: input, as: UTF8.self), configuration: configuration, apiKey: apiKey, structured: true)
			guard let data = output.data(using: .utf8), let translated = try? JSONDecoder().decode([String: String].self, from: data), Set(translated.keys) == Set(batch.keys), translated.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AITranslationError.invalidResponse }
			translations.merge(translated) { _, new in new }
			await progress?(index + 1, batches.count)
		}
		let body = slots.enumerated().map { index, slot in
			guard slot.translate, let text = translations[String(index)] else { return slot.text }
			return AITranslationDocument.replacingText(slot.text, with: text)
		}.joined()
		return AITranslationDocument(title: translations["title"] ?? title, body: body)
	}
}
