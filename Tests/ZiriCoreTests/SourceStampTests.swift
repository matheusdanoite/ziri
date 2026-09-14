import Foundation
import Testing
@testable import ZiriCore

/// O daemon pula a rodada quando o carimbo não muda. Se o carimbo ficar igual
/// com arquivo alterado, mensagens novas nunca chegam; se mudar sem alteração,
/// volta a cópia de ~26 MB a cada 5 minutos.
@Suite struct SourceStampTests {
    let dir: URL
    let reader: ChatStorageReader

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziri-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reader = ChatStorageReader(
            sourcePath: dir.appendingPathComponent("ChatStorage.sqlite").path,
            contactsPath: dir.appendingPathComponent("ContactsV2.sqlite").path
        )
        for name in ["ChatStorage.sqlite", "ChatStorage.sqlite-wal", "ContactsV2.sqlite"] {
            try touch(name, at: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    func touch(_ name: String, at date: Date) throws {
        let path = dir.appendingPathComponent(name).path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    @Test func semMudancaCarimboIgual() {
        #expect(reader.sourceStamp == reader.sourceStamp)
        #expect(reader.sourceStamp.count == 4)
    }

    @Test func walAlteradoMudaCarimbo() throws {
        let antes = reader.sourceStamp
        try touch("ChatStorage.sqlite-wal", at: Date(timeIntervalSince1970: 1_700_000_300))
        #expect(reader.sourceStamp != antes)
    }

    @Test func checkpointNoBancoMudaCarimbo() throws {
        let antes = reader.sourceStamp
        try touch("ChatStorage.sqlite", at: Date(timeIntervalSince1970: 1_700_000_300))
        #expect(reader.sourceStamp != antes)
    }

    @Test func walDaAgendaQueSurgeMudaCarimbo() throws {
        let antes = reader.sourceStamp
        try touch("ContactsV2.sqlite-wal", at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(reader.sourceStamp != antes)
    }
}
