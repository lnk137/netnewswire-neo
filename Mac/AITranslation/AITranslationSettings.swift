import Foundation
import Security
import LocalAuthentication

@MainActor final class AITranslationSettings {
	static let shared = AITranslationSettings()
	static let changed = Notification.Name("AITranslationSettingsChanged")
	static let concurrencyChanged = Notification.Name("AITranslationConcurrencyChanged")
	static let scopeChanged = Notification.Name("AITranslationScopeChanged")
	var onlyUnread: Bool { defaults.bool(forKey: "AITranslationOnlyUnread") }
	var queuePaused: Bool {
		get { defaults.bool(forKey: "AITranslationQueuePaused") }
		set { defaults.set(newValue, forKey: "AITranslationQueuePaused") }
	}
	func setOnlyUnread(_ value: Bool) {
		guard value != onlyUnread else { return }
		defaults.set(value, forKey: "AITranslationOnlyUnread")
		NotificationCenter.default.post(name: Self.scopeChanged, object: self)
	}
	var dateScopeEnabled: Bool { defaults.bool(forKey: "AITranslationDateScopeEnabled") }
	var dateScopeStart: Date { defaults.object(forKey: "AITranslationDateScopeStart") as? Date ?? Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() }
	var dateScopeEnd: Date { defaults.object(forKey: "AITranslationDateScopeEnd") as? Date ?? Date() }
	func setDateScope(enabled: Bool, start: Date, end: Date) {
		defaults.set(enabled, forKey: "AITranslationDateScopeEnabled")
		defaults.set(start, forKey: "AITranslationDateScopeStart")
		defaults.set(end, forKey: "AITranslationDateScopeEnd")
		NotificationCenter.default.post(name: Self.scopeChanged, object: self)
	}
	func allowsAutomaticTranslation(isRead: Bool, date: Date = Date()) -> Bool {
		guard !onlyUnread || !isRead else { return false }
		return allowsDate(date)
	}
	func allowsDate(_ date: Date) -> Bool {
		guard dateScopeEnabled else { return true }
		let calendar = Calendar.current
		let start = calendar.startOfDay(for: dateScopeStart)
		let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateScopeEnd)) ?? dateScopeEnd
		return date >= start && date < end
	}
	var concurrency: Int {
		let value = defaults.object(forKey: "AITranslationConcurrency") as? Int ?? 1
		return AITranslationWorkerPool.boundedLimit(value)
	}
	func setConcurrency(_ value: Int) {
		defaults.set(AITranslationWorkerPool.boundedLimit(value), forKey: "AITranslationConcurrency")
		NotificationCenter.default.post(name: Self.concurrencyChanged, object: self)
	}
	private let defaults: UserDefaults
	private let credentialURL: URL
	private let legacyKeyReader: () -> String?
	private var cachedAPIKey: String?
	private var attemptedMigration = false
	private(set) var configuration: AITranslationConfiguration

	init(defaults: UserDefaults = .standard, credentialURL: URL? = nil, legacyKeyReader: (() -> String?)? = nil) {
		self.defaults = defaults
		let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		self.credentialURL = credentialURL ?? root.appendingPathComponent("NetNewsWire Neo/Credentials/translation-api-key")
		self.legacyKeyReader = legacyKeyReader ?? Self.readLegacyKey
		if let data = defaults.data(forKey: "AITranslationConfiguration"),
		   let saved = try? JSONDecoder().decode(AITranslationConfiguration.self, from: data) {
			configuration = saved
		} else { configuration = AITranslationConfiguration() }
	}

	var apiKey: String {
		if let cachedAPIKey { return cachedAPIKey }
		if let key = try? String(contentsOf: credentialURL, encoding: .utf8), !key.isEmpty {
			cachedAPIKey = key
			return key
		}
		guard !FileManager.default.fileExists(atPath: credentialURL.path), !attemptedMigration else { return "" }
		attemptedMigration = true
		guard let key = legacyKeyReader(), !key.isEmpty else { return "" }
		do {
			try writeAPIKey(key)
			cachedAPIKey = key
			return key
		} catch { return "" }
	}

	private static func readLegacyKey() -> String? {
		let context = LAContext()
		context.interactionNotAllowed = true
		let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "local.lnk137.NetNewsWireNeo.translation.v3",
			kSecAttrAccount as String: "api-key", kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
		var result: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
			let data = result as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	private func writeAPIKey(_ key: String) throws {
		let directory = credentialURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
		try Data(key.utf8).write(to: credentialURL, options: .atomic)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialURL.path)
	}

	func save(_ configuration: AITranslationConfiguration, apiKey: String?) throws {
		guard configuration.endpoint != nil, !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty,
			  !configuration.targetLanguage.trimmingCharacters(in: .whitespaces).isEmpty else { throw AITranslationError.configuration }
		if let apiKey {
			let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
			try writeAPIKey(key)
			cachedAPIKey = key
		}

		defaults.set(try JSONEncoder().encode(configuration), forKey: "AITranslationConfiguration")
		self.configuration = configuration
		NotificationCenter.default.post(name: Self.changed, object: self)
	}

	/// One-time local setup file written by the installation script, never bundled or committed.
	func importBootstrapIfPresent() throws {
		struct Bootstrap: Decodable { let configuration: AITranslationConfiguration; let apiKey: String }
		let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		let file = root.appendingPathComponent("NetNewsWire Neo/bootstrap.json")
		guard FileManager.default.fileExists(atPath: file.path) else { return }
		let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: Data(contentsOf: file))
		try save(bootstrap.configuration, apiKey: bootstrap.apiKey)
		try FileManager.default.removeItem(at: file)
	}
}
