import Foundation
import CryptoKit

/// Pedido do iPhone: "me manda tudo depois desta marca d'água".
public struct SyncRequest: Codable, Sendable {
    public let since: Double?
    public let limit: Int
    /// Versão das fotos de perfil que o iPhone já tem. Igual à do Mac, as fotos
    /// não viajam de novo — são ~1,5 MB e quase nunca mudam.
    public let photosVersion: String?
    public init(since: Date?, limit: Int = 5_000, photosVersion: String? = nil) {
        self.since = since?.timeIntervalSince1970
        self.limit = limit
        self.photosVersion = photosVersion
    }
    public var sinceDate: Date? { since.map(Date.init(timeIntervalSince1970:)) }
}

public struct SyncResponse: Codable, Sendable {
    public let messages: [ZMessage]
    public let hasMore: Bool
    /// Mapa conversa (LID) → telefone, completo e lido da agenda na hora do
    /// pedido. Viaja separado das mensagens para que um contato salvo depois
    /// passe a valer para o histórico inteiro, não só para mensagens novas.
    /// Opcional: servidores antigos não mandam, e o decode continua funcionando.
    public let chatPhones: [String: String]?
    /// JID (conversa, grupo ou participante) → JPEG da foto de perfil, completo.
    /// Só vem na última página e só quando `photosVersion` difere da do pedido;
    /// nil quer dizer "nada mudou", não "ninguém tem foto".
    public let chatPhotos: [String: Data]?
    public let photosVersion: String?

    public init(
        messages: [ZMessage], hasMore: Bool, chatPhones: [String: String]? = nil,
        chatPhotos: [String: Data]? = nil, photosVersion: String? = nil
    ) {
        self.messages = messages
        self.hasMore = hasMore
        self.chatPhones = chatPhones
        self.chatPhotos = chatPhotos
        self.photosVersion = photosVersion
    }
}

public enum SyncProtocol {
    public static let serviceType = "_ziri._tcp"
    public static let maxFrame = 32 * 1024 * 1024

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Quadro = 4 bytes big-endian de tamanho + payload JSON.
    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    public static func frameLength(_ header: Data) -> Int {
        header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
    }
}

/// Segredo compartilhado entre Mac e iPhone, pareado uma vez. Vira a PSK do TLS.
public struct PairingKey: Sendable {
    public static let defaultPath = NSString(string: "~/.ziri/pairing.key").expandingTildeInPath

    public let raw: Data

    public init(raw: Data) { self.raw = raw }

    public static func generate() -> PairingKey {
        PairingKey(raw: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Código legível para digitar/escanear no iPhone: 52 caracteres base32 sem padding.
    public var code: String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0, out = ""
        for byte in raw {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map {
            String(Array(out)[$0..<min($0 + 4, out.count)])
        }.joined(separator: "-")
    }

    public static func fromCode(_ code: String) -> PairingKey? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let clean = code.uppercased().filter { alphabet.contains($0) }
        var bits = 0, value = 0
        var bytes = [UInt8]()
        for ch in clean {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        guard bytes.count == 32 else { return nil }
        return PairingKey(raw: Data(bytes))
    }

    /// Link que o Mac mostra como QR code. A Câmera do iPhone reconhece o
    /// esquema `ziri://` e abre o app, que pareia sem digitar os 52 caracteres.
    public var pairingURL: URL {
        var c = URLComponents()
        c.scheme = "ziri"
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "code", value: code)]
        return c.url!
    }

    public static func fromPairingURL(_ url: URL) -> PairingKey? {
        guard url.scheme == "ziri", url.host == "pair",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        return fromCode(code)
    }

    public static func loadOrCreate(path: String = defaultPath) throws -> PairingKey {
        if let data = FileManager.default.contents(atPath: path), data.count == 32 {
            return PairingKey(raw: data)
        }
        let key = generate()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try key.raw.write(to: URL(fileURLWithPath: path), options: .completeFileProtection)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return key
    }
}
