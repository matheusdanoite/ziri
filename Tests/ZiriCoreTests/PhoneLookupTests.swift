import Foundation
import Testing
@testable import ZiriCore

/// O telefone que abre a conversa no WhatsApp é resolvido no toque, a partir do
/// mapa mais recente vindo do Mac — não congelado na importação da mensagem.
@Suite struct PhoneLookupTests {
    func makeStore() throws -> ZiriStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziri-test-\(UUID().uuidString).sqlite").path
        return try ZiriStore(path: path)
    }

    func message(_ id: String, chat: String, phone: String? = nil) -> ZMessage {
        ZMessage(
            id: id, sentAt: Date(), chatJID: chat, chatName: "conversa",
            isGroup: false, fromMe: false, senderID: chat, sender: "alguém",
            body: "oi", replyTo: nil, chatPhone: phone
        )
    }

    @Test func contatoSalvoDepoisValeParaMensagensAntigas() throws {
        let store = try makeStore()
        try store.upsert([message("m1", chat: "111@lid")])
        #expect(try store.phone(forMessageID: "m1") == nil)

        try store.replaceChatPhones(["111@lid": "5511999990000"])
        #expect(try store.phone(forMessageID: "m1") == "5511999990000")
    }

    @Test func mapaAtualGanhaDoValorDaImportacao() throws {
        let store = try makeStore()
        try store.upsert([message("m1", chat: "111@lid", phone: "5500000000000")])
        try store.replaceChatPhones(["111@lid": "5511999990000"])
        #expect(try store.phone(forMessageID: "m1") == "5511999990000")
    }

    @Test func contatoRemovidoDaAgendaCaiNoValorDaImportacao() throws {
        let store = try makeStore()
        try store.upsert([message("m1", chat: "111@lid", phone: "5500000000000")])
        try store.replaceChatPhones(["111@lid": "5511999990000"])
        try store.replaceChatPhones([:])
        #expect(try store.phone(forMessageID: "m1") == "5500000000000")
    }

    @Test func mapaNaoVazaEntreConversas() throws {
        let store = try makeStore()
        try store.upsert([message("m1", chat: "111@lid"), message("m2", chat: "222@lid")])
        try store.replaceChatPhones(["111@lid": "5511999990000"])
        #expect(try store.phone(forMessageID: "m2") == nil)
    }

    @Test func idComAspasNaoQuebraAConsulta() throws {
        let store = try makeStore()
        try store.upsert([message("m'1", chat: "111@lid")])
        try store.replaceChatPhones(["111@lid": "5511999990000"])
        #expect(try store.phone(forMessageID: "m'1") == "5511999990000")
    }

    @Test func respostaDeServidorAntigoSemMapaDecodifica() throws {
        let json = Data(#"{"messages":[],"hasMore":false}"#.utf8)
        let resp = try SyncProtocol.decoder.decode(SyncResponse.self, from: json)
        #expect(resp.chatPhones == nil)
    }

    @Test func digitosSoDeJIDDeTelefone() {
        #expect(ChatStorageReader.phoneDigits(fromJID: "5511999990000@s.whatsapp.net") == "5511999990000")
        #expect(ChatStorageReader.phoneDigits(fromJID: "123456@lid") == nil)
        #expect(ChatStorageReader.phoneDigits(fromJID: "abc@s.whatsapp.net") == nil)
    }
}
