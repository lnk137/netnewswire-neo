import Foundation
import Security

@MainActor final class AITranslationSettings {
	static let shared = AITranslationSettings()
	static let changed = Notification.Name("AITranslationSettingsChanged")
	private let defaults = UserDefaults.standard
	private let service = "local.lnk137.NetNewsWireNeo.translation"
	private let account = "api-key"
	private(set) var configuration: AITranslationConfiguration

	private init() {
		if let data = defaults.data(forKey: "AITranslationConfiguration"),
		   let saved = try? JSONDecoder().decode(AITranslationConfiguration.self, from: data) {
			configuration = saved
		} else { configuration = AITranslationConfiguration() }
	}

	var apiKey: String {
		let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service, kSecAttrAccount as String: account,
			kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
		var result: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
			  let data = result as? Data else { return "" }
		return String(data: data, encoding: .utf8) ?? ""
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
