import Foundation
import ZiriCore

/// Store local do iPhone. Mesmo schema do Mac — o ZiriStore do ZiriCore compila
/// nas duas plataformas, então não existe formato duplicado.
///
/// É um actor de propósito: inserir 20 mil linhas e recontar estatísticas leva
/// dezenas de segundos, e no @MainActor isso congela a interface inteira.
actor MessageStore {
    static let shared = MessageStore()

    private let store: ZiriStore?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try? ZiriStore(path: dir.appendingPathComponent("ziri.sqlite").path)
    }

    var watermark: Date? { try? store?.watermark }

    var count: Int { (try? store?.count) ?? 0 }

    var stats: ZiriStore.Stats? {
        guard let s = try? store?.stats else { return nil }
        return s
    }

    var needsFullResync: Bool { (try? store?.needsFullResync) ?? false }

    func clearFullResync() { try? store?.clearFullResync() }

    /// Telefone do chat de uma mensagem — é o que o OpenIntent usa para montar
    /// o deep link do WhatsApp.
    func chatPhone(forMessageID id: String) -> String? {
        (try? store?.messages(withIDs: [id]))?.first?.chatPhone
    }

    @discardableResult
    func ingest(_ messages: [ZMessage]) throws -> Int {
        try store?.upsert(messages) ?? 0
    }

    func messages(since: Date?, limit: Int = 5_000) throws -> [ZMessage] {
        try store?.messages(since: since, limit: limit) ?? []
    }

    func messages(withIDs ids: [String]) throws -> [ZMessage] {
        try store?.messages(withIDs: ids) ?? []
    }

    func search(_ text: String, limit: Int) throws -> [ZMessage] {
        try store?.search(text, limit: limit) ?? []
    }

    func people(withIDs ids: [String]) throws -> [ZiriPersonEntity] {
        try (store?.people(withIDs: ids) ?? []).map { ZiriPersonEntity(id: $0.id, name: $0.name) }
    }

    func conversations(withIDs ids: [String]) throws -> [ZiriConversationEntity] {
        try (store?.conversations(withIDs: ids) ?? [])
            .map { ZiriConversationEntity(id: $0.id, name: $0.name, isGroup: $0.isGroup) }
    }
}
