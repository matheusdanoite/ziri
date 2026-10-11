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
        guard let store else { return nil }
        return (try? store.phone(forMessageID: id)) ?? nil
    }

    func replaceChatPhones(_ map: [String: String]) {
        try? store?.replaceChatPhones(map)
    }

    /// Versão das fotos que este iPhone tem, para o Mac não mandar de novo.
    var photosVersion: String? { (try? store?.meta(Self.photosVersionKey)) ?? nil }

    /// Grava as fotos vindas do Mac e devolve os JIDs cujos cards ficaram velhos.
    func replacePhotos(_ photos: [String: Data], version: String?) -> Set<String> {
        guard let store, let changed = try? store.replacePhotos(photos) else { return [] }
        try? store.setMeta(Self.photosVersionKey, version)
        return changed
    }

    private static let photosVersionKey = "photos_version"

    @discardableResult
    func ingest(_ messages: [ZMessage]) throws -> Int {
        try store?.upsert(messages) ?? 0
    }

    func count(since: Date?) -> Int {
        (try? store?.count(since: since)) ?? 0
    }

    func messages(since: Date?, limit: Int = 5_000) throws -> [ZMessage] {
        try store?.messages(since: since, limit: limit) ?? []
    }

    func messages(touching jids: Set<String>, after: Date?, until: Date, limit: Int) throws -> [ZMessage] {
        try store?.messages(touching: jids, after: after, until: until, limit: limit) ?? []
    }

    func messages(withIDs ids: [String]) throws -> [ZMessage] {
        try store?.messages(withIDs: ids) ?? []
    }

    func messageEntities(withIDs ids: [String]) throws -> [ZiriMessageEntity] {
        entities(try store?.messages(withIDs: ids) ?? [])
    }

    func search(_ text: String, limit: Int) throws -> [ZiriMessageEntity] {
        entities(try store?.search(text, limit: limit) ?? [])
    }

    /// Entidades com as fotos de conversa e remetente, buscadas numa consulta
    /// só por lote.
    func entities(_ messages: [ZMessage]) -> [ZiriMessageEntity] {
        let jids = Set(messages.flatMap { [$0.chatJID, $0.senderID] })
        let photos = (try? store?.photos(for: jids)) ?? [:]
        return messages.map { ZiriMessageEntity(from: $0, photos: photos) }
    }

    func people(withIDs ids: [String]) throws -> [ZiriPersonEntity] {
        let photos = (try? store?.photos(for: Set(ids))) ?? [:]
        return try (store?.people(withIDs: ids) ?? [])
            .map { ZiriPersonEntity(id: $0.id, name: $0.name, photo: photos[$0.id]) }
    }

    func conversations(withIDs ids: [String]) throws -> [ZiriConversationEntity] {
        let photos = (try? store?.photos(for: Set(ids))) ?? [:]
        return try (store?.conversations(withIDs: ids) ?? []).map {
            ZiriConversationEntity(id: $0.id, name: $0.name, isGroup: $0.isGroup, photo: photos[$0.id])
        }
    }
}
