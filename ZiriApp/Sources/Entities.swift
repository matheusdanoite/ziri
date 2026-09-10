import AppIntents
import CoreLocation
import LinkPresentation
import CoreSpotlight
import Foundation
import ZiriCore

// MARK: - Enums do schema

@AppEnum(schema: .messages.messageType)
enum ZiriMessageType: String {
    case text
    case unspecified

    static let caseDisplayRepresentations: [ZiriMessageType: DisplayRepresentation] = [
        .text: "texto",
        .unspecified: "não especificado",
    ]
}

@AppEnum(schema: .messages.messageAttribute)
enum ZiriMessageAttribute: String {
    case unread

    static let caseDisplayRepresentations: [ZiriMessageAttribute: DisplayRepresentation] = [
        .unread: "não lida"
    ]
}

@AppEnum(schema: .messages.conversationAttribute)
enum ZiriConversationAttribute: String {
    case unread

    static let caseDisplayRepresentations: [ZiriConversationAttribute: DisplayRepresentation] = [
        .unread: "não lida"
    ]
}

@AppEnum(schema: .messages.messageEffect)
enum ZiriMessageEffect: String {
    case none

    static let caseDisplayRepresentations: [ZiriMessageEffect: DisplayRepresentation] = [
        .none: "nenhum"
    ]
}

@AppEnum(schema: .messages.customReaction)
enum ZiriTapback: String {
    case heart, thumbsUp, thumbsDown, haha, exclamation, question

    static let caseDisplayRepresentations: [ZiriTapback: DisplayRepresentation] = [
        .heart: "coração",
        .thumbsUp: "joinha",
        .thumbsDown: "joinha para baixo",
        .haha: "risada",
        .exclamation: "exclamação",
        .question: "interrogação",
    ]
}

/// O schema aceita reação como tapback pré-definido OU texto livre — isso é um
/// tipo união no App Intents, não um opcional de um dos dois.
@UnionValue
enum ZiriReaction {
    case tapback(ZiriTapback)
    case text(AttributedString)
}

// MARK: - Entidades

/// A entidade que a Siri indexa. O schema `.messages.message` é o contrato que
/// diz ao sistema "isto é uma mensagem" — sem ele o conteúdo entra no Spotlight
/// mas a Siri não o interpreta como conversa.
@AppEntity(schema: .messages.message)
struct ZiriMessageEntity: IndexedEntity {
    var id: String

    @Property(indexingKey: \.textContent)
    var body: String?

    @Property(indexingKey: \.contentCreationDate)
    var date: Date

    var author: ZiriPersonEntity
    var conversation: ZiriConversationEntity
    var subject: String?
    var isRead: Bool
    var messageType: ZiriMessageType
    var messageEffect: ZiriMessageEffect?
    var attributes: Set<ZiriMessageAttribute>
    var attachments: [IntentFile]
    var customAttachments: [ZiriCustomAttachment]
    var audioMessage: IntentFile?
    var links: [LinkMetadata]
    var locations: [CLPlacemark]
    var notificationIdentifier: String?
    var reaction: ZiriReaction?
    var referencedMessage: ZiriMessageEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(author.displayName) em \(conversation.displayName)",
            subtitle: "\(body ?? "")"
        )
    }

    static let defaultQuery = ZiriMessageQuery()

    init(from m: ZMessage) {
        id = m.id
        author = ZiriPersonEntity(id: m.senderID, name: m.sender)
        conversation = ZiriConversationEntity(
            id: m.chatJID, name: m.chatName, isGroup: m.isGroup,
            lastActive: m.sentAt, preview: m.body
        )
        subject = nil
        isRead = true
        messageType = .text
        date = m.sentAt
        messageEffect = nil
        attributes = []
        attachments = []
        customAttachments = []
        audioMessage = nil
        links = []
        locations = []
        notificationIdentifier = nil
        reaction = nil
        referencedMessage = nil
        body = m.body
    }
}

@AppEntity(schema: .messages.messagePerson)
struct ZiriPersonEntity {
    var id: String

    @Property(indexingKey: \.displayName)
    var displayName: String

    var person: IntentPerson

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(displayName)") }

    static let defaultQuery = ZiriPersonQuery()

    init(id: String, name: String) {
        self.id = id
        // LID do WhatsApp não é telefone nem e-mail: applicationDefined é o
        // handle honesto aqui.
        self.person = IntentPerson(handle: .init(applicationDefined: id, label: name))
        self.displayName = name
    }
}

@AppEntity(schema: .messages.conversation)
struct ZiriConversationEntity {
    var id: String

    @Property(indexingKey: \.displayName)
    var displayName: String

    var conversationName: String?
    var dateLastActive: Date?
    var isRead: Bool
    var previewText: String
    var recipients: [ZiriPersonEntity]
    var attributes: Set<ZiriConversationAttribute>
    var isGroup: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: isGroup ? "grupo" : "conversa")
    }

    static let defaultQuery = ZiriConversationQuery()

    init(id: String, name: String, isGroup: Bool, lastActive: Date = .now, preview: String? = nil) {
        self.id = id
        self.isGroup = isGroup
        self.conversationName = name
        self.dateLastActive = lastActive
        self.isRead = true
        self.previewText = preview ?? ""
        self.recipients = []
        self.attributes = []
        self.displayName = name
    }
}

@AppEntity(schema: .messages.customAttachment)
struct ZiriCustomAttachment {
    var id: String
    var description: String?
    var sourceName: String?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "anexo") }

    static let defaultQuery = ZiriAttachmentQuery()
}

// MARK: - Queries

/// Busca textual como rede de segurança: o índice semântico cobre "sobre o que
/// falamos", a busca por string cobre nomes e termos exatos.
struct ZiriMessageQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ZiriMessageEntity] {
        try await MessageStore.shared.messages(withIDs: identifiers).map(ZiriMessageEntity.init(from:))
    }

    func entities(matching string: String) async throws -> [ZiriMessageEntity] {
        try await MessageStore.shared.search(string, limit: 50).map(ZiriMessageEntity.init(from:))
    }
}

struct ZiriPersonQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ZiriPersonEntity] {
        try await MessageStore.shared.people(withIDs: identifiers)
    }
}

struct ZiriConversationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ZiriConversationEntity] {
        try await MessageStore.shared.conversations(withIDs: identifiers)
    }
}

struct ZiriAttachmentQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ZiriCustomAttachment] { [] }
}
