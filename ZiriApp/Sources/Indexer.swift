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
    /// v3: símbolo de conversa no lugar do ícone do WhatsApp.
    /// v4: foto de perfil da conversa e do remetente; "Você" no lugar de "me".
    private let indexVersion = 4
    private let versionKey = "ziri.indexVersion"

    var lastIndexed: Date? {
        get { UserDefaults.standard.object(forKey: indexedKey) as? Date }
    }

    private func setLastIndexed(_ date: Date) {
        UserDefaults.standard.set(date, forKey: indexedKey)
    }

    /// Indexa tudo que chegou depois da última indexação. `progress` recebe
    /// (feitas, total) a cada lote: uma reindexação completa leva ~15 minutos
    /// (~14 s por lote de 500 num iPhone 15 Pro), e sem número na tela isso
    /// parece travado.
    ///
    /// `refreshing` são JIDs cuja foto mudou: as mensagens já indexadas deles
    /// são doadas de novo, porque o card guarda a foto do momento da doação.
    @discardableResult
    func indexPending(
        refreshing photoChanges: Set<String> = [],
        progress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> Int {
        // Zerar a marca d'água basta: reindexar com o mesmo id substitui o item.
        // Se for interrompido, a próxima rodada continua do cursor da versão nova.
        if UserDefaults.standard.integer(forKey: versionKey) != indexVersion {
            UserDefaults.standard.removeObject(forKey: indexedKey)
            UserDefaults.standard.set(indexVersion, forKey: versionKey)
        }
        var cursor = lastIndexed
        var total = 0
        // Sem cursor, tudo vai ser indexado de qualquer jeito, já com as fotos novas.
        // Uma interrupção aqui perde a renovação até a foto mudar de novo: o
        // card fica com a foto anterior, que não é dado errado, só velho.
        if let until = cursor, !photoChanges.isEmpty {
            var after: Date?
            while true {
                let batch = try await MessageStore.shared.messages(
                    touching: photoChanges, after: after, until: until, limit: batchSize
                )
                guard !batch.isEmpty else { break }
                try await CSSearchableIndex.default().indexAppEntities(await MessageStore.shared.entities(batch))
                total += batch.count
                after = batch.last?.sentAt
                if batch.count < batchSize { break }
            }
        }
        let pending = await MessageStore.shared.count(since: cursor) + total
        while true {
            let batch = try await MessageStore.shared.messages(since: cursor, limit: batchSize)
            guard !batch.isEmpty else { break }
            let entities = await MessageStore.shared.entities(batch)
            try await CSSearchableIndex.default().indexAppEntities(entities)
            total += entities.count
            cursor = batch.last?.sentAt
            if let cursor { setLastIndexed(cursor) }
            await progress?(total, pending)
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
