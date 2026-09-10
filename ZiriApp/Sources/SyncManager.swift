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

    private var key: PairingKey? { Keychain.pairingKey }

    var isPaired: Bool { key != nil }

    init() {
        refreshCount()
        if key == nil { state = .unpaired }
    }

    func refreshCount() { storedCount = MessageStore.shared.count }

    func pair(withCode code: String) -> Bool {
        guard let key = PairingKey.fromCode(code) else { return false }
        Keychain.pairingKey = key
        state = .idle
        return true
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
            var since = try MessageStore.shared.watermark
            while true {
                state = .syncing("baixando… (\(received))")
                let resp = try await client.fetch(from: endpoint, since: since)
                guard !resp.messages.isEmpty else { break }
                try MessageStore.shared.ingest(resp.messages)
                received += resp.messages.count
                since = resp.messages.last?.sentAt
                if !resp.hasMore { break }
            }

            state = .syncing("indexando para a Siri…")
            let indexed = try await Indexer.shared.indexPending()

            refreshCount()
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
