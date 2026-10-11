import CryptoKit
import Foundation

/// Store normalizado do ziri. É a fonte que o iPhone consome — o ChatStorage do
/// WhatsApp nunca é exposto diretamente.
public final class ZiriStore {
    public static let defaultPath = NSString(string: "~/.ziri/store.sqlite").expandingTildeInPath

    let db: DB

    public init(path: String = ZiriStore.defaultPath) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        db = try DB(path: path)
        try db.exec("PRAGMA journal_mode=WAL;")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS message (
          id       TEXT PRIMARY KEY,
          sent_at  REAL NOT NULL,
          chat_jid TEXT NOT NULL,
          chat_name TEXT NOT NULL,
          is_group INTEGER NOT NULL,
          from_me  INTEGER NOT NULL,
          sender_id TEXT NOT NULL DEFAULT '',
          sender   TEXT NOT NULL,
          body     TEXT NOT NULL,
          reply_to TEXT,
          chat_phone TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_message_sent_at ON message(sent_at);
        CREATE INDEX IF NOT EXISTS idx_message_chat ON message(chat_jid, sent_at);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS chat_phone (chat_jid TEXT PRIMARY KEY, phone TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS chat_photo (jid TEXT PRIMARY KEY, source TEXT NOT NULL, jpeg BLOB NOT NULL);
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try migrate()
    }

    /// Stores criados antes da v2 não têm chat_phone. A marca d'água não reenvia
    /// linhas antigas, então a migração pede uma ressincronização completa.
    private func migrate() throws {
        var hasPhone = false
        try db.query("PRAGMA table_info(message)") { s in
            if s.string(1) == "chat_phone" { hasPhone = true }
        }
        if !hasPhone {
            try db.exec("ALTER TABLE message ADD COLUMN chat_phone TEXT")
            try db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('needs_full_resync', '1')")
        }
    }

    /// Verdadeiro depois de uma migração que exige reprocessar o histórico inteiro.
    public var needsFullResync: Bool {
        get throws {
            try db.scalarInt("SELECT COUNT(*) FROM meta WHERE key='needs_full_resync' AND value='1'") > 0
        }
    }

    public func clearFullResync() throws {
        try db.exec("DELETE FROM meta WHERE key='needs_full_resync'")
    }

    /// Substitui o mapa inteiro: contato removido da agenda some, contato novo
    /// passa a valer para todas as mensagens daquela conversa.
    public func replaceChatPhones(_ map: [String: String]) throws {
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec("DELETE FROM chat_phone")
            let stmt = try db.prepare("INSERT INTO chat_phone (chat_jid, phone) VALUES (?, ?)")
            defer { stmt.finalize() }
            for (jid, phone) in map {
                stmt.bind(1, jid)
                stmt.bind(2, phone)
                try stmt.run()
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Fotos de perfil
    //
    // Uma tabela só para conversas, grupos e participantes: o JID já diz quem é.
    // No Mac, `source` é o caminho da foto no WhatsApp; no iPhone fica vazio.

    /// Mac: alinha a tabela com o mapa JID → caminho lido do WhatsApp. Só lê do
    /// disco (`load`) as fotos cujo caminho mudou; JID fora do mapa perdeu a foto.
    public func syncPhotos(_ paths: [String: String], load: (String) -> Data?) throws {
        var current: [String: String] = [:]
        try db.query("SELECT jid, source FROM chat_photo") { s in
            if let jid = s.string(0) { current[jid] = s.string(1) ?? "" }
        }
        let gone = current.keys.filter { paths[$0] == nil }
        let changed = paths.filter { current[$0.key] != $0.value }
        guard !gone.isEmpty || !changed.isEmpty else { return }

        try db.exec("BEGIN IMMEDIATE")
        do {
            let del = try db.prepare("DELETE FROM chat_photo WHERE jid = ?")
            defer { del.finalize() }
            for jid in gone {
                del.bind(1, jid)
                try del.run()
            }
            let put = try db.prepare("INSERT OR REPLACE INTO chat_photo (jid, source, jpeg) VALUES (?, ?, ?)")
            defer { put.finalize() }
            for (jid, path) in changed {
                // Arquivo ainda não baixado pelo WhatsApp: fica de fora e a
                // próxima leitura tenta de novo, já que o caminho não foi gravado.
                guard let jpeg = load(path) else { continue }
                put.bind(1, jid)
                put.bind(2, path)
                put.bind(3, jpeg)
                try put.run()
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// Só as fotos de quem aparece nas mensagens: o WhatsApp guarda também as
    /// de canais e de participantes de grupos que não estão no histórico.
    static let knownPhotosFilter =
        "jid IN (SELECT chat_jid FROM message) OR jid IN (SELECT sender_id FROM message)"

    /// Mac: identifica o conjunto de fotos que o iPhone deveria ter. Muda quando
    /// qualquer foto muda; igual ao que o iPhone mandou, as fotos não viajam.
    public var photosVersion: String {
        get throws {
            var hasher = SHA256()
            try db.query("SELECT jid, source FROM chat_photo WHERE \(Self.knownPhotosFilter) ORDER BY jid") { s in
                hasher.update(data: Data("\(s.string(0) ?? "")\t\(s.string(1) ?? "")\n".utf8))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Mac: JID → JPEG, o que vai para o iPhone.
    public func knownPhotos() throws -> [String: Data] {
        var out: [String: Data] = [:]
        try db.query("SELECT jid, jpeg FROM chat_photo WHERE \(Self.knownPhotosFilter)") { s in
            if let jid = s.string(0), let jpeg = s.data(1) { out[jid] = jpeg }
        }
        return out
    }

    /// iPhone: substitui o mapa inteiro e devolve os JIDs cuja foto mudou
    /// (nova, trocada ou removida) — as mensagens deles precisam de novo card.
    @discardableResult
    public func replacePhotos(_ map: [String: Data]) throws -> Set<String> {
        let current = try photos(for: nil)
        var changed = Set(current.keys.filter { map[$0] == nil })
        changed.formUnion(map.keys.filter { current[$0] != map[$0] })
        guard !changed.isEmpty else { return [] }

        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec("DELETE FROM chat_photo")
            let put = try db.prepare("INSERT INTO chat_photo (jid, source, jpeg) VALUES (?, '', ?)")
            defer { put.finalize() }
            for (jid, jpeg) in map {
                put.bind(1, jid)
                put.bind(2, jpeg)
                try put.run()
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        return changed
    }

    /// Fotos dos JIDs pedidos; `nil` traz todas.
    public func photos(for jids: Set<String>?) throws -> [String: Data] {
        if let jids, jids.isEmpty { return [:] }
        let filter = jids.map { "WHERE jid IN (\($0.map(Self.quote).joined(separator: ",")))" } ?? ""
        var out: [String: Data] = [:]
        try db.query("SELECT jid, jpeg FROM chat_photo \(filter)") { s in
            if let jid = s.string(0), let jpeg = s.data(1) { out[jid] = jpeg }
        }
        return out
    }

    public func meta(_ key: String) throws -> String? {
        var out: String?
        try db.query("SELECT value FROM meta WHERE key = \(Self.quote(key))") { s in out = s.string(0) }
        return out
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (\(Self.quote(key)), \(Self.quote(value)))")
        } else {
            try db.exec("DELETE FROM meta WHERE key = \(Self.quote(key))")
        }
    }

    /// Telefone da conversa de uma mensagem, resolvido na hora: o mapa atual
    /// ganha; o valor gravado na importação é só fallback.
    public func phone(forMessageID id: String) throws -> String? {
        var out: String?
        try db.query("""
        SELECT COALESCE(p.phone, m.chat_phone) FROM message m
        LEFT JOIN chat_phone p ON p.chat_jid = m.chat_jid
        WHERE m.id = \(Self.quote(id))
        """) { s in out = s.string(0) }
        return out
    }

    /// Data da mensagem mais recente já ingerida. Usada como marca d'água da extração.
    public var watermark: Date? {
        get throws {
            let t = try db.scalarDouble("SELECT COALESCE(MAX(sent_at), 0) FROM message")
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
    }

    public var count: Int {
        get throws { try db.scalarInt("SELECT COUNT(*) FROM message") }
    }

    /// Mensagens depois de `since` — o que falta indexar a partir de um cursor.
    public func count(since: Date?) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM message WHERE sent_at > \(since?.timeIntervalSince1970 ?? 0)")
    }

    /// Insere ignorando duplicatas por id. Retorna quantas linhas eram novas.
    @discardableResult
    public func upsert(_ messages: [ZMessage]) throws -> Int {
        guard !messages.isEmpty else { return 0 }
        let before = try count
        try db.exec("BEGIN IMMEDIATE")
        do {
            let stmt = try db.prepare("""
            INSERT INTO message
              (id, sent_at, chat_jid, chat_name, is_group, from_me, sender_id, sender, body, reply_to, chat_phone)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              chat_name = excluded.chat_name,
              sender = excluded.sender,
              chat_phone = COALESCE(excluded.chat_phone, message.chat_phone)
            """)
            defer { stmt.finalize() }
            for m in messages {
                stmt.bind(1, m.id)
                stmt.bind(2, m.sentAt.timeIntervalSince1970)
                stmt.bind(3, m.chatJID)
                stmt.bind(4, m.chatName)
                stmt.bind(5, m.isGroup)
                stmt.bind(6, m.fromMe)
                stmt.bind(7, m.senderID)
                stmt.bind(8, m.sender)
                stmt.bind(9, m.body)
                stmt.bind(10, m.replyTo)
                stmt.bind(11, m.chatPhone)
                try stmt.run()
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        return try count - before
    }

    /// Mensagens posteriores a `since`, em ordem cronológica — o delta que vai pro iPhone.
    public func messages(since: Date?, limit: Int = 5_000) throws -> [ZMessage] {
        let cutoff = since?.timeIntervalSince1970 ?? 0
        var out: [ZMessage] = []
        try db.query("""
        SELECT \(Self.columns)
        FROM message WHERE sent_at > \(cutoff)
        ORDER BY sent_at ASC LIMIT \(limit)
        """) { s in
            out.append(ZMessage(
                id: s.string(0) ?? "",
                sentAt: Date(timeIntervalSince1970: s.double(1)),
                chatJID: s.string(2) ?? "",
                chatName: s.string(3) ?? "",
                isGroup: s.bool(4),
                fromMe: s.bool(5),
                senderID: s.string(6) ?? "",
                sender: s.string(7) ?? "",
                body: s.string(8) ?? "",
                replyTo: s.string(9),
                chatPhone: s.string(10)
            ))
        }
        return out
    }

    public struct Stats: Sendable {
        public let messages: Int
        public let chats: Int
        public let groups: Int
        public let first: Date?
        public let last: Date?
    }

    public var stats: Stats {
        get throws {
            let first = try db.scalarDouble("SELECT COALESCE(MIN(sent_at),0) FROM message")
            let last = try db.scalarDouble("SELECT COALESCE(MAX(sent_at),0) FROM message")
            return Stats(
                messages: try count,
                chats: try db.scalarInt("SELECT COUNT(DISTINCT chat_jid) FROM message"),
                groups: try db.scalarInt("SELECT COUNT(DISTINCT chat_jid) FROM message WHERE is_group=1"),
                first: first > 0 ? Date(timeIntervalSince1970: first) : nil,
                last: last > 0 ? Date(timeIntervalSince1970: last) : nil
            )
        }
    }
}

// MARK: - Consultas usadas pelas entidades do App Intents

public struct ZParty: Sendable {
    public let id: String
    public let name: String
    public let isGroup: Bool
}

extension ZiriStore {
    func rows(_ sql: String) throws -> [ZMessage] {
        var out: [ZMessage] = []
        try db.query(sql) { s in
            out.append(ZMessage(
                id: s.string(0) ?? "",
                sentAt: Date(timeIntervalSince1970: s.double(1)),
                chatJID: s.string(2) ?? "",
                chatName: s.string(3) ?? "",
                isGroup: s.bool(4),
                fromMe: s.bool(5),
                senderID: s.string(6) ?? "",
                sender: s.string(7) ?? "",
                body: s.string(8) ?? "",
                replyTo: s.string(9),
                chatPhone: s.string(10)
            ))
        }
        return out
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static let columns =
        "id, sent_at, chat_jid, chat_name, is_group, from_me, sender_id, sender, body, reply_to, chat_phone"

    public func messages(withIDs ids: [String]) throws -> [ZMessage] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(Self.quote).joined(separator: ",")
        return try rows("SELECT \(Self.columns) FROM message WHERE id IN (\(list))")
    }

    /// Mensagens de ou para estes JIDs (conversa ou remetente) até `until`, em
    /// ordem cronológica a partir de `after` — o que reindexar quando uma foto muda.
    public func messages(touching jids: Set<String>, after: Date?, until: Date, limit: Int) throws -> [ZMessage] {
        guard !jids.isEmpty else { return [] }
        let list = jids.map(Self.quote).joined(separator: ",")
        return try rows("""
        SELECT \(Self.columns) FROM message
        WHERE (chat_jid IN (\(list)) OR sender_id IN (\(list)))
          AND sent_at > \(after?.timeIntervalSince1970 ?? 0) AND sent_at <= \(until.timeIntervalSince1970)
        ORDER BY sent_at ASC LIMIT \(limit)
        """)
    }

    public func search(_ text: String, limit: Int = 50) throws -> [ZMessage] {
        let needle = Self.quote("%\(text)%")
        return try rows("""
        SELECT \(Self.columns) FROM message
        WHERE body LIKE \(needle) OR sender LIKE \(needle) OR chat_name LIKE \(needle)
        ORDER BY sent_at DESC LIMIT \(limit)
        """)
    }

    public func people(withIDs ids: [String]) throws -> [ZParty] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(Self.quote).joined(separator: ",")
        var out: [ZParty] = []
        try db.query("""
        SELECT sender_id, sender FROM message
        WHERE sender_id IN (\(list)) GROUP BY sender_id
        """) { s in
            out.append(ZParty(id: s.string(0) ?? "", name: s.string(1) ?? "", isGroup: false))
        }
        return out
    }

    public func conversations(withIDs ids: [String]) throws -> [ZParty] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(Self.quote).joined(separator: ",")
        var out: [ZParty] = []
        try db.query("""
        SELECT chat_jid, chat_name, is_group FROM message
        WHERE chat_jid IN (\(list)) GROUP BY chat_jid
        """) { s in
            out.append(ZParty(id: s.string(0) ?? "", name: s.string(1) ?? "", isGroup: s.bool(2)))
        }
        return out
    }
}
