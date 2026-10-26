import Foundation

/// Cancelled requests keep their slots until they actually return.
@MainActor final class AITranslationWorkerPool {
	private var tasks = [String: Task<Void, Never>]()
	private(set) var limit = 1
	var count: Int { tasks.count }
	var onAvailable: (() -> Void)?
	static func boundedLimit(_ value: Int) -> Int { min(20, max(1, value)) }
	func setLimit(_ value: Int) { limit = Self.boundedLimit(value) }
	func contains(_ id: String) -> Bool { tasks[id] != nil }
	@discardableResult func start(_ id: String, operation: @escaping @MainActor () async -> Void) -> Bool {
		guard count < limit, tasks[id] == nil else { return false }
		tasks[id] = Task { [weak self] in
			await operation()
			self?.tasks[id] = nil
			self?.onAvailable?()
		}
		return true
	}
	func cancel(_ id: String) { tasks[id]?.cancel() }
	func cancelAll() { for task in tasks.values { task.cancel() } }
}
