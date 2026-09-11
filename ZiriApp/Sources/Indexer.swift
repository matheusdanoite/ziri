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

    /// Sobe sempre que muda a forma como a entidade aparece (título, ícone).
    /// O índice guarda o displayRepresentation do momento da indexação, então
    /// mudar o código não muda os cards da Siri até reindexar tudo.
    /// v2: nome uma vez só + ícone do WhatsApp.
    private let indexVersion = 2
    private let versionKey = "ziri.indexVersion"

    var lastIndexed: Date? {
        get { UserDefaults.standard.object(forKey: indexedKey) as? Date }
    }

    private func setLastIndexed(_ date: Date) {
        UserDefaults.standard.set(date, forKey: indexedKey)
    }

    /// Indexa tudo que chegou depois da última indexação.
    @discardableResult
    func indexPending() async throws -> Int {
        // Zerar a marca d'água basta: reindexar com o mesmo id substitui o item.
        // Se for interrompido, a próxima rodada continua do cursor da versão nova.
        if UserDefaults.standard.integer(forKey: versionKey) != indexVersion {
            UserDefaults.standard.removeObject(forKey: indexedKey)
            UserDefaults.standard.set(indexVersion, forKey: versionKey)
        }
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
