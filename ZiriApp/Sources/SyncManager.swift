import Foundation
import Network
import Security
import ZiriCore

/// Descobre o Mac na rede local, puxa o delta e manda indexar.
@MainActor
@Observable
final class SyncManager {
    enum State: Equatable {
        case idle
        case unpaired
        case syncing(String)
        case failed(String)
        case done(received: Int, indexed: Int, at: Date)
    }

    private(set) var state: State = .idle
    private(set) var storedCount: Int = 0
    /// Estatísticas em cache: consultar o banco durante o redesenho da tela
    /// coloca SQLite na main thread a cada frame.
    private(set) var stats: ZiriStore.Stats?

    private var key: PairingKey? { Keychain.pairingKey }

    var isPaired: Bool { key != nil }

    init() {
        if key == nil { state = .unpaired }
        Task { await refresh() }
    }

    func refresh() async {
        stats = await MessageStore.shared.stats
        storedCount = stats?.messages ?? 0
    }

    func pair(withCode code: String) -> Bool {
        guard let key = PairingKey.fromCode(code) else { return false }
        pair(with: key)
        return true
    }

    func pair(with key: PairingKey) {
        Keychain.pairingKey = key
        state = .idle
    }

    func unpair() {
        Keychain.pairingKey = nil
        state = .unpaired
    }

    /// Um ciclo completo: descobrir → buscar delta → guardar → indexar.
    func sync() async {
        guard let key else { state = .unpaired; return }
        let client = SyncClient(key: key)
        do {
            state = .syncing("procurando seu Mac…")
            let endpoint = try await client.discover()

            var received = 0
            var latestPhones: [String: String]?
            // Migração de schema (ex.: chat_phone na v2) exige puxar tudo de novo:
            // o upsert atualiza as linhas que já existem.
            let full = await MessageStore.shared.needsFullResync
            var since = full ? nil : await MessageStore.shared.watermark
            while true {
                state = .syncing("baixando… (\(received))")
                let resp = try await client.fetch(from: endpoint, since: since)
                // Antes do guard: a resposta vazia (nada novo) ainda traz o mapa
                // atualizado, e é justamente o caso comum de um sync de rotina.
                if let phones = resp.chatPhones { latestPhones = phones }
                guard !resp.messages.isEmpty else { break }
                try await MessageStore.shared.ingest(resp.messages)
                received += resp.messages.count
                since = resp.messages.last?.sentAt
                if !resp.hasMore { break }
            }

            if full { await MessageStore.shared.clearFullResync() }
            if let latestPhones { await MessageStore.shared.replaceChatPhones(latestPhones) }

            state = .syncing("indexando para a Siri…")
            let indexed = try await Indexer.shared.indexPending()

            await refresh()
            state = .done(received: received, indexed: indexed, at: Date())
        } catch {
            state = .failed("\(error)")
        }
    }
}

/// A chave de pareamento é o segredo do TLS — Keychain, não UserDefaults.
enum Keychain {
    private static let account = "fi.ziri.pairing"

    static var pairingKey: PairingKey? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, data.count == 32 else { return nil }
            return PairingKey(raw: data)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue else { return }
            var add = base
            add[kSecValueData as String] = newValue.raw
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
