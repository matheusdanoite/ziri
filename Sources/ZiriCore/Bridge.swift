import Foundation
import SQLite3

/// O lado do Mac inteiro: serve o delta na rede local para o iPhone e lê o
/// WhatsApp desta máquina para o store a cada pedido. O agente do ziri.app e o
/// `ziri serve` rodam exatamente isto.
///
/// Sem timer: entre um sync e outro do iPhone ninguém lê o store, então ler o
/// WhatsApp na hora do pedido entrega o mesmo dado mais fresco e deixa o
/// daemon parado o resto do tempo.
public final class Bridge: @unchecked Sendable {
    let store: ZiriStore
    let reader: ChatStorageReader
    let server: SyncServer
    let queue = DispatchQueue(label: "fi.ziri.ingest", qos: .utility)
    /// Carimbo dos arquivos do WhatsApp na última rodada que leu o banco.
    /// Só a fila de ingestão mexe nele.
    var lastStamp: [Date?] = []

    public var onEvent: (@Sendable (String) -> Void)? {
        didSet { server.onEvent = onEvent }
    }

    public init(store: ZiriStore, key: PairingKey, reader: ChatStorageReader = ChatStorageReader()) {
        self.store = store
        self.reader = reader
        server = SyncServer(store: store, key: key)
        server.phonesProvider = { reader.chatPhones() }
        server.beforeResponse = { [weak self] in self?.queue.sync { self?.tick() } }
    }

    /// Começa a servir e já faz a primeira leitura, para o primeiro pedido não
    /// esperar a cópia do banco inteiro.
    public func start() throws {
        try server.start()
        queue.async { [weak self] in self?.tick() }
    }

    private func tick() {
        // A primeira leitura sempre aparece no log: é a prova de que o macOS
        // deixou o ziri ler o WhatsApp, mesmo sem mensagem nova.
        let first = lastStamp.isEmpty
        do {
            let novas = try ingest(skipIfUnchanged: true)
            if novas > 0 || first { onEvent?("WhatsApp lido: \(novas) novas mensagens") }
        } catch SQLiteError.open(_, SQLITE_AUTH) {
            // A proteção de dados de outros apps do macOS negou a leitura. Só a
            // pessoa resolve, em Ajustes do Sistema; repetir não muda nada.
            onEvent?("sem acesso aos dados do WhatsApp (código \(SQLITE_AUTH)): libere o ziri em Ajustes do Sistema → Privacidade e Segurança")
        } catch {
            onEvent?("erro na ingestão: \(error)")
        }
    }

    /// Uma rodada de ingestão. Com `skipIfUnchanged`, pula a rodada se nenhum
    /// arquivo de origem mudou: sem isso, cada rodada copia o banco inteiro
    /// (~26 MB via VACUUM INTO, ~7 GB/dia de escrita no SSD). O carimbo é lido
    /// antes da extração: se o WhatsApp escrever no meio, a próxima rodada vê.
    @discardableResult
    public func ingest(skipIfUnchanged: Bool = false) throws -> Int {
        guard reader.sourceExists else { throw BridgeError.whatsAppNotFound }
        // Depois de uma migração de schema, reprocessa tudo: a marca d'água não
        // traria de volta as linhas antigas que precisam dos campos novos.
        let full = try store.needsFullResync
        let stamp = reader.sourceStamp
        if skipIfUnchanged, !full, stamp == lastStamp { return 0 }

        let messages = try reader.messages(since: full ? nil : try store.watermark)
        let novas = try store.upsert(messages)
        if full { try store.clearFullResync() }
        lastStamp = stamp
        return novas
    }
}

public enum BridgeError: Error, CustomStringConvertible {
    case whatsAppNotFound

    public var description: String {
        "ChatStorage.sqlite não encontrado em \(ChatStorageReader.defaultPath) — o WhatsApp para Mac está instalado?"
    }
}
