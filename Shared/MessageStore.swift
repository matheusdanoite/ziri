import Foundation
import ZiriCore
#if os(macOS)
import AppKit
#endif

/// Store local do iPhone. Mesmo schema do Mac — o ZiriStore do ZiriCore compila
/// nas duas plataformas, então não existe formato duplicado.
///
/// É um actor de propósito: inserir 20 mil linhas e recontar estatísticas leva
/// dezenas de segundos, e no @MainActor isso congela a interface inteira.
actor MessageStore {
    static let shared = MessageStore()

    private let store: ZiriStore?
    #if os(macOS)
    var lastSourceStamp: [Date?] = []
    #endif

    init() {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        // Fora de sandbox, Application Support é compartilhado por todos os apps.
        dir = dir.appendingPathComponent("fi.ziri.mac", isDirectory: true)
        #endif
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

#if os(macOS)
enum MacIngestError: Error {
    case whatsAppNotInstalled
    /// O banco existe mas o macOS negou a leitura (proteção de dados de outros apps).
    case noAccess
}

extension MessageStore {
    /// No Mac não há sync: o ziri lê o banco do WhatsApp desta máquina.
    ///
    /// Pula a rodada se nenhum arquivo de origem mudou. Sem isso, cada rodada
    /// copia o banco inteiro (~26 MB via VACUUM INTO) mesmo sem mensagem nova.
    func ingestFromWhatsApp() throws -> Int {
        guard let store else { return 0 }
        let reader = ChatStorageReader()
        guard reader.sourceExists else {
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") != nil
            throw installed ? MacIngestError.noAccess : MacIngestError.whatsAppNotInstalled
        }
        let full = try store.needsFullResync
        let stamp = Self.sourceStamp()
        if !full, stamp == lastSourceStamp { return 0 }

        let messages: [ZMessage]
        do {
            messages = try reader.messages(since: full ? nil : try store.watermark)
        } catch SQLiteError.open {
            throw MacIngestError.noAccess
        }
        let novas = try store.upsert(messages)
        if full { try store.clearFullResync() }
        try store.replaceChatPhones(reader.chatPhones())
        lastSourceStamp = stamp
        return novas
    }

    private static func sourceStamp() -> [Date?] {
        [ChatStorageReader.defaultPath, ChatStorageReader.contactsPath]
            .flatMap { [$0, $0 + "-wal"] }
            .map { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
    }
}
#endif
