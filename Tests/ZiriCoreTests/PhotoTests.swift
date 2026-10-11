import Foundation
import ImageIO
import Testing
@testable import ZiriCore

/// Fotos de perfil: o Mac só relê do disco o que mudou, só manda ao iPhone
/// quando o conjunto muda, e o iPhone sabe de quem refazer os cards.
@Suite struct PhotoTests {
    func makeStore() throws -> ZiriStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziri-test-\(UUID().uuidString).sqlite").path
        return try ZiriStore(path: path)
    }

    func message(_ id: String, chat: String, sender: String? = nil, group: Bool = false) -> ZMessage {
        ZMessage(
            id: id, sentAt: Date(timeIntervalSince1970: 1_700_000_000), chatJID: chat, chatName: "conversa",
            isGroup: group, fromMe: false, senderID: sender ?? chat, sender: "alguém",
            body: "oi", replyTo: nil
        )
    }

    @Test func soReleDoDiscoAFotoQueMudou() throws {
        let store = try makeStore()
        var loaded: [String] = []
        let load = { (path: String) -> Data? in loaded.append(path); return Data(path.utf8) }

        try store.syncPhotos(["a@lid": "Media/Profile/a-1", "b@lid": "Media/Profile/b-1"], load: load)
        #expect(Set(loaded) == ["Media/Profile/a-1", "Media/Profile/b-1"])

        loaded = []
        try store.syncPhotos(["a@lid": "Media/Profile/a-1", "b@lid": "Media/Profile/b-2"], load: load)
        #expect(loaded == ["Media/Profile/b-2"])
        #expect(try store.photos(for: ["b@lid"])["b@lid"] == Data("Media/Profile/b-2".utf8))
    }

    @Test func fotoRemovidaSaiEArquivoAusenteTentaDeNovo() throws {
        let store = try makeStore()
        try store.syncPhotos(["a@lid": "p/a-1"], load: { Data($0.utf8) })
        try store.syncPhotos(["b@lid": "p/b-1"], load: { _ in nil })
        #expect(try store.photos(for: nil).isEmpty)

        try store.syncPhotos(["b@lid": "p/b-1"], load: { Data($0.utf8) })
        #expect(try store.photos(for: nil).keys.sorted() == ["b@lid"])
    }

    @Test func soViajaFotoDeQuemEstaNoHistorico() throws {
        let store = try makeStore()
        try store.upsert([message("m1", chat: "grupo@g.us", sender: "membro@lid", group: true)])
        try store.syncPhotos([
            "grupo@g.us": "p/g", "membro@lid": "p/m", "canal@newsletter": "p/c",
        ], load: { Data($0.utf8) })
        #expect(try store.knownPhotos().keys.sorted() == ["grupo@g.us", "membro@lid"])
    }

    @Test func versaoMudaComAFotoENaoComCanal() throws {
        let store = try makeStore()
        try store.upsert([message("m1", chat: "a@lid")])
        try store.syncPhotos(["a@lid": "p/a-1"], load: { Data($0.utf8) })
        let v1 = try store.photosVersion

        try store.syncPhotos(["a@lid": "p/a-1", "canal@newsletter": "p/c"], load: { Data($0.utf8) })
        #expect(try store.photosVersion == v1)

        try store.syncPhotos(["a@lid": "p/a-2"], load: { Data($0.utf8) })
        #expect(try store.photosVersion != v1)
    }

    @Test func iphoneSabeQuemMudou() throws {
        let store = try makeStore()
        #expect(try store.replacePhotos(["a": Data([1]), "b": Data([2])]) == ["a", "b"])
        #expect(try store.replacePhotos(["a": Data([1]), "b": Data([2])]).isEmpty)
        #expect(try store.replacePhotos(["a": Data([9]), "c": Data([3])]) == ["a", "b", "c"])
        #expect(try store.photos(for: nil) == ["a": Data([9]), "c": Data([3])])
    }

    @Test func mensagensDeQuemTrocouAFoto() throws {
        let store = try makeStore()
        try store.upsert([
            message("m1", chat: "a@lid"),
            message("m2", chat: "grupo@g.us", sender: "a@lid", group: true),
            message("m3", chat: "b@lid"),
        ])
        let found = try store.messages(touching: ["a@lid"], after: nil, until: .distantFuture, limit: 10)
        #expect(Set(found.map(\.id)) == ["m1", "m2"])
    }

    @Test func metaGuardaEApaga() throws {
        let store = try makeStore()
        try store.setMeta("photos_version", "abc'1")
        #expect(try store.meta("photos_version") == "abc'1")
        try store.setMeta("photos_version", nil)
        #expect(try store.meta("photos_version") == nil)
    }

    @Test func miniaturaVaiComoEstaEFotoGrandeEncolhe() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziri-photos-\(UUID().uuidString)", isDirectory: true)
        let profile = dir.appendingPathComponent("Media/Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let reader = ChatStorageReader(sourcePath: dir.appendingPathComponent("ChatStorage.sqlite").path)

        try Data([0xFF, 0xD8, 0x01]).write(to: profile.appendingPathComponent("a-1.thumb"))
        #expect(reader.photoData(atPath: "Media/Profile/a-1") == Data([0xFF, 0xD8, 0x01]))

        try Self.jpeg(side: 640).write(to: profile.appendingPathComponent("b-1.jpg"))
        let small = try #require(reader.photoData(atPath: "Media/Profile/b-1"))
        let src = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 192)

        #expect(reader.photoData(atPath: "Media/Profile/nada") == nil)
    }

    static func jpeg(side: Int) throws -> Data {
        let ctx = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func pedidoEDeRespostaAntigosDecodificam() throws {
        let req = try SyncProtocol.decoder.decode(SyncRequest.self, from: Data(#"{"limit":10}"#.utf8))
        #expect(req.photosVersion == nil)
        let resp = try SyncProtocol.decoder.decode(
            SyncResponse.self, from: Data(#"{"messages":[],"hasMore":false}"#.utf8)
        )
        #expect(resp.chatPhotos == nil && resp.photosVersion == nil)
    }
}
