import Foundation

/// Uma mensagem de texto normalizada, independente do schema do WhatsApp.
/// `id` é o ZSTANZAID: estável entre dispositivos e nunca nulo.
public struct ZMessage: Codable, Sendable, Hashable {
    public let id: String
    public let sentAt: Date
    public let chatJID: String
    public let chatName: String
    public let isGroup: Bool
    public let fromMe: Bool
    /// LID/JID do remetente — identidade estável, base do ContactEntity no app.
    public let senderID: String
    public let sender: String
    public let body: String
    public let replyTo: String?
    /// Telefone do chat 1:1 (só dígitos, com DDI). É o único identificador que
    /// o WhatsApp aceita em deep link público; LID e JID de grupo não servem.
    public let chatPhone: String?

    public init(
        id: String, sentAt: Date, chatJID: String, chatName: String,
        isGroup: Bool, fromMe: Bool, senderID: String, sender: String,
        body: String, replyTo: String?, chatPhone: String? = nil
    ) {
        self.id = id
        self.sentAt = sentAt
        self.chatJID = chatJID
        self.chatName = chatName
        self.isGroup = isGroup
        self.fromMe = fromMe
        self.senderID = senderID
        self.sender = sender
        self.body = body
        self.replyTo = replyTo
        self.chatPhone = chatPhone
    }
}

/// Core Data grava timestamps como segundos desde 2001-01-01.
public let coreDataEpochOffset: Double = 978_307_200
