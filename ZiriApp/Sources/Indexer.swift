import AppIntents
import CoreSpotlight
import Foundation
import ZiriCore

/// Empurra as mensagens para o índice semântico do sistema, em lotes.
/// É este passo que faz a Siri enxergar o histórico.
actor Indexer {
    static let shared = Indexer()

    private let batchSize = 500
    private let indexedKey = "ziri.lastIndexedAt"

    var lastIndexed: Date? {
        get { UserDefaults.standard.object(forKey: indexedKey) as? Date }
    }

    private func setLastIndexed(_ date: Date) {
        UserDefaults.standard.set(date, forKey: indexedKey)
    }

    /// Indexa tudo que chegou depois da última indexação.
    @discardableResult
    func indexPending() async throws -> Int {
        var cursor = lastIndexed
        var total = 0
        while true {
            let batch = try await MessageStore.shared.messages(since: cursor, limit: batchSize)
            guard !batch.isEmpty else { break }
            let entities = batch.map(ZiriMessageEntity.init(from:))
            try await CSSearchableIndex.default().indexAppEntities(entities)
            total += entities.count
            cursor = batch.last?.sentAt
            if let cursor { setLastIndexed(cursor) }
            if batch.count < batchSize { break }
        }
        return total
    }

    /// Remove tudo do índice — o botão de pânico, já que o conteúdo é sensível.
    func removeAll() async throws {
        try await CSSearchableIndex.default().deleteAllSearchableItems()
        UserDefaults.standard.removeObject(forKey: indexedKey)
    }
}
