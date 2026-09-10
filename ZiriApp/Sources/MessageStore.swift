import Foundation
import ZiriCore

/// Store local do iPhone. Mesmo schema do Mac — o ZiriStore do ZiriCore compila
/// nas duas plataformas, então não existe formato duplicado.
final class MessageStore: @unchecked Sendable {
    static let shared = try! MessageStore()

    private let store: ZiriStore
    private let lock = NSLock()

    init() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try ZiriStore(path: dir.appendingPathComponent("ziri.sqlite").path)
    }

    var watermark: Date? {
        get throws { lock.withLock { try? store.watermark } ?? nil }
    }

    var count: Int { (try? lock.withLock { try store.count }) ?? 0 }

    var stats: ZiriStore.Stats? { try? lock.withLock { try store.stats } }

    @discardableResult
    func ingest(_ messages: [ZMessage]) throws -> Int {
        try lock.withLock { try store.upsert(messages) }
    }

    func messages(since: Date?, limit: Int = 5_000) throws -> [ZMessage] {
        try lock.withLock { try store.messages(since: since, limit: limit) }
    }

    func messages(withIDs ids: [String]) throws -> [ZMessage] {
        try lock.withLock { try store.messages(withIDs: ids) }
    }

    func search(_ text: String, limit: Int) throws -> [ZMessage] {
        try lock.withLock { try store.search(text, limit: limit) }
    }

    func people(withIDs ids: [String]) throws -> [ZiriPersonEntity] {
        try lock.withLock { try store.people(withIDs: ids) }
            .map { ZiriPersonEntity(id: $0.id, name: $0.name) }
    }

    func conversations(withIDs ids: [String]) throws -> [ZiriConversationEntity] {
        try lock.withLock { try store.conversations(withIDs: ids) }
            .map { ZiriConversationEntity(id: $0.id, name: $0.name, isGroup: $0.isGroup) }
    }
}
