import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lê o ChatStorage.sqlite do WhatsApp para Mac sem nunca escrever nele.
public struct ChatStorageReader: Sendable {
    static let groupContainer = NSString(
        string: "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
    ).expandingTildeInPath

    public static let defaultPath = "\(groupContainer)/ChatStorage.sqlite"
    public static let contactsPath = "\(groupContainer)/ContactsV2.sqlite"

    /// Só mensagens de texto: ZMESSAGETYPE = 0.
    ///
    /// Duas armadilhas do schema, ambas custaram dados na primeira versão:
    /// 1. ZGROUPEVENTTYPE = 2 é o valor comum de mensagens normais, não marcador
    ///    de evento de grupo — filtrar por ele descarta ~90% do histórico.
    /// 2. Vários campos de nome vêm como string vazia em vez de NULL, então
    ///    COALESCE puro para na primeira opção e nunca chega no fallback.
    ///    Daí o NULLIF(TRIM(...), '') em cada candidato.
    static let extractSQL = """
    SELECT
      m.ZSTANZAID,
      m.ZMESSAGEDATE,
      NULLIF(TRIM(c.ZCONTACTJID), ''),
      NULLIF(TRIM(c.ZPARTNERNAME), ''),
      c.ZSESSIONTYPE,
      m.ZISFROMME,
      NULLIF(TRIM(gm.ZMEMBERJID), ''),
      NULLIF(TRIM(m.ZPUSHNAME), ''),
      m.ZTEXT,
      p.ZSTANZAID
    FROM ZWAMESSAGE m
    JOIN ZWACHATSESSION c ON m.ZCHATSESSION = c.Z_PK
    LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
    LEFT JOIN ZWAMESSAGE p ON m.ZPARENTMESSAGE = p.Z_PK
    WHERE m.ZMESSAGETYPE = 0
      AND m.ZTEXT IS NOT NULL AND length(m.ZTEXT) > 0
      AND m.ZSTANZAID IS NOT NULL
      AND m.ZMESSAGEDATE > ?
    ORDER BY m.ZMESSAGEDATE ASC
    """

    /// Foto de perfil vigente de cada JID (conversa, grupo ou participante).
    /// ZPATH é relativo ao group container e vem sem extensão: o arquivo é
    /// `.thumb` (96×96) na maioria dos casos e `.jpg` (até 640×640) no resto.
    /// Linha sem caminho de mídia é pedido em andamento ou foto removida.
    static let photosSQL = """
    SELECT ZJID, ZPATH FROM ZWAPROFILEPICTUREITEM
    WHERE ZJID IS NOT NULL AND ZPATH LIKE 'Media/Profile/%'
    """

    let sourcePath: String
    let contactsPath: String

    public init(
        sourcePath: String = ChatStorageReader.defaultPath,
        contactsPath: String = ChatStorageReader.contactsPath
    ) {
        self.sourcePath = sourcePath
        self.contactsPath = contactsPath
    }

    public var sourceExists: Bool { FileManager.default.fileExists(atPath: sourcePath) }

    /// Datas de modificação dos dois bancos e dos seus `-wal`. Se não mudou
    /// nada desde a última rodada, não há mensagem nova — e dá para pular o
    /// `VACUUM INTO`, que copia o banco inteiro (~26 MB) a cada leitura.
    /// Arquivo ausente vira nil, então um `-wal` que aparece também conta.
    public var sourceStamp: [Date?] {
        [sourcePath, contactsPath]
            .flatMap { [$0, $0 + "-wal"] }
            .map { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
    }

    /// Snapshot consistente via `VACUUM INTO` a partir de conexão somente-leitura.
    /// Resolve o WAL pendente sem tocar no banco original.
    func snapshot(_ path: String, to destination: String) throws {
        try? FileManager.default.removeItem(atPath: destination)
        let src = try DB(path: path, readOnly: true)
        try src.exec("VACUUM INTO '\(destination.replacingOccurrences(of: "'", with: "''"))'")
    }

    /// LID/JID → nome da agenda. O ChatStorage não guarda nome de participante
    /// de grupo: ZWAGROUPMEMBER.ZCONTACTNAME vem vazio em todas as linhas.
    struct Contacts {
        var names: [String: String] = [:]
        /// LID → dígitos do telefone, extraídos de ZWHATSAPPID (`<dígitos>@s.whatsapp.net`).
        var phones: [String: String] = [:]
    }

    func contacts() -> Contacts {
        guard FileManager.default.fileExists(atPath: contactsPath) else { return Contacts() }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziri-contacts-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard (try? snapshot(contactsPath, to: tmp)) != nil,
              let db = try? DB(path: tmp, readOnly: true) else { return Contacts() }

        var out = Contacts()
        try? db.query("""
        SELECT NULLIF(TRIM(ZLID),''), NULLIF(TRIM(ZWHATSAPPID),''),
               COALESCE(NULLIF(TRIM(ZFULLNAME),''), NULLIF(TRIM(ZGIVENNAME),''))
        FROM ZWAADDRESSBOOKCONTACT
        """) { s in
            let lid = s.string(0), wid = s.string(1)
            if let name = s.string(2) {
                if let lid { out.names[lid] = name }
                if let wid { out.names[wid] = name }
            }
            if let lid, let digits = wid.flatMap(Self.phoneDigits) { out.phones[lid] = digits }
        }
        return out
    }

    /// `5511999999999@s.whatsapp.net` → `5511999999999`. Qualquer outro domínio → nil.
    static func phoneDigits(fromJID jid: String) -> String? {
        guard jid.hasSuffix("@s.whatsapp.net") else { return nil }
        let digits = String(jid.prefix { $0 != "@" })
        return digits.isEmpty || !digits.allSatisfy(\.isNumber) ? nil : digits
    }

    /// Conversa (LID) → telefone, lido da agenda do WhatsApp agora.
    public func chatPhones() -> [String: String] { contacts().phones }

    /// O que uma leitura do banco traz: o delta de mensagens e o mapa
    /// completo JID → foto de perfil, tirados da mesma cópia do banco.
    public struct Extract: Sendable {
        public let messages: [ZMessage]
        /// JID → caminho da foto, relativo ao group container e sem extensão.
        /// O caminho muda quando a foto muda (leva o id da foto), então serve
        /// de versão: só o que mudou precisa ser lido do disco de novo.
        public let photos: [String: String]
    }

    /// Extrai mensagens com data estritamente maior que `since`, e as fotos.
    public func read(since watermark: Date?) throws -> Extract {
        let snapshotPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziri-snapshot-\(UUID().uuidString).sqlite").path
        try snapshot(sourcePath, to: snapshotPath)
        defer { try? FileManager.default.removeItem(atPath: snapshotPath) }

        let db = try DB(path: snapshotPath, readOnly: true)
        var photos: [String: String] = [:]
        // Tabela ausente (schema antigo ou mudado) não pode custar as mensagens.
        try? db.query(Self.photosSQL) { s in
            if let jid = s.string(0), let path = s.string(1) { photos[jid] = path }
        }
        return Extract(messages: try messages(in: db, since: watermark), photos: photos)
    }

    /// Bytes JPEG da foto em `path` (como vem em `Extract.photos`), prontos para
    /// o card da Siri. A miniatura vai como está; a versão grande é reduzida,
    /// porque o card não passa de ~130 px e cada foto viaja para o iPhone.
    public func photoData(atPath path: String) -> Data? {
        let base = URL(fileURLWithPath: (sourcePath as NSString).deletingLastPathComponent)
            .appendingPathComponent(path)
        if let thumb = try? Data(contentsOf: base.appendingPathExtension("thumb")) { return thumb }
        guard let full = try? Data(contentsOf: base.appendingPathExtension("jpg")) else { return nil }
        return Self.downscaled(full, maxPixels: 192) ?? full
    }

    static func downscaled(_ jpeg: Data, maxPixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    func messages(in db: DB, since watermark: Date?) throws -> [ZMessage] {
        let book = contacts()
        let names = book.names
        let cutoff = (watermark?.timeIntervalSince1970 ?? 0) - coreDataEpochOffset

        let stmt = try db.prepare(Self.extractSQL)
        defer { stmt.finalize() }
        stmt.bind(1, cutoff)

        var out: [ZMessage] = []
        while try stmt.step() {
            guard let id = stmt.string(0), let body = stmt.string(8) else { continue }
            let chatJID = stmt.string(2) ?? ""
            let isGroup = stmt.int(4) == 1
            let fromMe = stmt.bool(5)
            let memberJID = stmt.string(6)
            let pushName = stmt.string(7)
            let chatName = stmt.string(3) ?? names[chatJID] ?? chatJID

            // Nome da agenda ganha do pushName: é como você chama a pessoa, e é
            // por esse nome que você vai perguntar à Siri.
            let senderID = fromMe ? "me" : (isGroup ? (memberJID ?? "") : chatJID)
            let sender: String = if fromMe {
                "me"
            } else if isGroup {
                memberJID.flatMap { names[$0] } ?? pushName ?? memberJID ?? "desconhecido"
            } else {
                names[chatJID] ?? chatName
            }

            out.append(ZMessage(
                id: id,
                sentAt: Date(timeIntervalSince1970: stmt.double(1) + coreDataEpochOffset),
                chatJID: chatJID,
                chatName: chatName,
                isGroup: isGroup,
                fromMe: fromMe,
                senderID: senderID,
                sender: sender,
                body: body,
                replyTo: stmt.string(9),
                chatPhone: isGroup ? nil : (book.phones[chatJID] ?? Self.phoneDigits(fromJID: chatJID))
            ))
        }
        return out
    }
}
