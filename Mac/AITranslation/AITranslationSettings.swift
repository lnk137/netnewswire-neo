import Foundation
import Security
import LocalAuthentication

@MainActor final class AITranslationSettings {
	static let shared = AITranslationSettings()
	static let changed = Notification.Name("AITranslationSettingsChanged")
	static let concurrencyChanged = Notification.Name("AITranslationConcurrencyChanged")
	static let scopeChanged = Notification.Name("AITranslationScopeChanged")
	var onlyUnread: Bool { defaults.bool(forKey: "AITranslationOnlyUnread") }
	func setOnlyUnread(_ value: Bool) {
		guard value != onlyUnread else { return }
		defaults.set(value, forKey: "AITranslationOnlyUnread")
		NotificationCenter.default.post(name: Self.scopeChanged, object: self)
	}
	func allowsAutomaticTranslation(isRead: Bool) -> Bool { !onlyUnread || !isRead }
	var concurrency: Int {
		let value = defaults.object(forKey: "AITranslationConcurrency") as? Int ?? 1
		return AITranslationWorkerPool.boundedLimit(value)
	}
	func setConcurrency(_ value: Int) {
		defaults.set(AITranslationWorkerPool.boundedLimit(value), forKey: "AITranslationConcurrency")
		NotificationCenter.default.post(name: Self.concurrencyChanged, object: self)
	}
	private let defaults: UserDefaults
	private let service = "local.lnk137.NetNewsWireNeo.translation.v3"
	private let account = "api-key"
	private var cachedAPIKey: String?
	private(set) var configuration: AITranslationConfiguration

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		if let data = defaults.data(forKey: "AITranslationConfiguration"),
		   let saved = try? JSONDecoder().decode(AITranslationConfiguration.self, from: data) {
			configuration = saved
		} else { configuration = AITranslationConfiguration() }
	}

	var apiKey: String {
		if let cachedAPIKey { return cachedAPIKey }
		return readAPIKey(allowPrompt: false)
	}

	/// Background jobs must never present authorization dialogs. Explicit UI retries only once.
	@discardableResult func readAPIKey(allowPrompt: Bool) -> String {
		var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service, kSecAttrAccount as String: account,
			kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
		if !allowPrompt {
			let context = LAContext()
			context.interactionNotAllowed = true
			query[kSecUseAuthenticationContext as String] = context
		}
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status == errSecSuccess, let data = result as? Data else {
			// A locked keychain or denied interaction can recover later in this launch.
			if status == errSecItemNotFound { cachedAPIKey = "" }
			return ""
		}
		let key = String(data: data, encoding: .utf8) ?? ""
		cachedAPIKey = key
		return key
	}

	func save(_ configuration: AITranslationConfiguration, apiKey: String?) throws {
		guard configuration.endpoint != nil, !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty,
			  !configuration.targetLanguage.trimmingCharacters(in: .whitespaces).isEmpty else { throw AITranslationError.configuration }
		if let apiKey {
			let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service, kSecAttrAccount as String: account]
			let data = Data(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
			var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
			if status == errSecItemNotFound {
				var item = query
				item[kSecValueData as String] = data
				item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
				status = SecItemAdd(item as CFDictionary, nil)
			}
			guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
			cachedAPIKey = String(data: data, encoding: .utf8)
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
