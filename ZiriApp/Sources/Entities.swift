import AppIntents
import CoreLocation
import LinkPresentation
import os
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

    /// É o card que a Siri mostra ao citar a mensagem. Visto no iOS 27: ela usa
    /// o título e a imagem, põe o ícone do ziri como selo no canto da imagem e
    /// descarta o subtítulo, que só aparece em outros lugares (Spotlight, Atalhos).
    /// O nome aparece uma vez só — numa conversa 1:1, autor e conversa são a
    /// mesma pessoa, e "X em X" era o que aparecia. A imagem é a foto da
    /// conversa (a do grupo, em grupos), com o símbolo como reserva.
    var displayRepresentation: DisplayRepresentation {
        let when = date.formatted(date: .abbreviated, time: .omitted)
        let origin: String
        if !conversation.isGroup {
            origin = "WhatsApp · \(when)"
        } else if author.id == "me" {
            origin = "WhatsApp · você · \(when)"
        } else {
            origin = "WhatsApp · \(author.displayName) · \(when)"
        }
        return DisplayRepresentation(
            title: "\(conversation.displayName)",
            subtitle: "\(origin)",
            image: conversation.image
        )
    }

    static let defaultQuery = ZiriMessageQuery()

    /// `photos` é JID → JPEG; basta conter a conversa e o remetente.
    init(from m: ZMessage, photos: [String: Data] = [:]) {
        id = m.id
        author = ZiriPersonEntity(id: m.senderID, name: m.sender, photo: photos[m.senderID])
        conversation = ZiriConversationEntity(
            id: m.chatJID, name: m.chatName, isGroup: m.isGroup,
            lastActive: m.sentAt, preview: m.body, photo: photos[m.chatJID]
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

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", image: person.image)
    }

    static let defaultQuery = ZiriPersonQuery()

    /// O store grava "me" como id e nome das mensagens que você mandou.
    static let meID = "me"

    init(id: String, name: String, photo: Data? = nil) {
        self.id = id
        let isMe = id == Self.meID
        // "me" chegava literal à Siri ("me em Fulano"). Com `isMe` o sistema
        // sabe que é o dono do aparelho; o nome cobre quem só lê o texto.
        let shown = isMe ? "Você" : name
        // LID do WhatsApp não é telefone nem e-mail: applicationDefined é o
        // handle honesto aqui.
        self.person = IntentPerson(
            identifier: .applicationDefined(id),
            name: .displayName(shown),
            handle: isMe ? nil : .init(applicationDefined: id, label: name),
            isMe: isMe,
            image: photo.map { DisplayRepresentation.Image(data: $0) }
        )
        self.displayName = shown
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
    /// Foto de perfil da conversa (da pessoa ou do grupo), JPEG vindo do Mac.
    var photo: Data?

    var image: DisplayRepresentation.Image {
        photo.map { DisplayRepresentation.Image(data: $0) } ?? .conversation
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: isGroup ? "Grupo no WhatsApp" : "Conversa no WhatsApp",
            image: image
        )
    }

    static let defaultQuery = ZiriConversationQuery()

    init(
        id: String, name: String, isGroup: Bool, lastActive: Date = .now,
        preview: String? = nil, photo: Data? = nil
    ) {
        self.id = id
        self.isGroup = isGroup
        self.photo = photo
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

extension DisplayRepresentation.Image {
    /// Reserva para conversa sem foto. Símbolo genérico, não o logo do
    /// WhatsApp: o repositório é público e o logo é marca da Meta.
    static let conversation = DisplayRepresentation.Image(systemName: "bubble.left.and.text.bubble.right")
}

// MARK: - Queries

/// Busca textual como rede de segurança: o índice semântico cobre "sobre o que
/// falamos", a busca por string cobre nomes e termos exatos.
struct ZiriMessageQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ZiriMessageEntity] {
        try await MessageStore.shared.messageEntities(withIDs: identifiers)
    }

    func entities(matching string: String) async throws -> [ZiriMessageEntity] {
        try await MessageStore.shared.search(string, limit: 50)
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

// MARK: - Abrir a origem

/// O que roda quando você toca na citação que a Siri exibe.
///
/// O WhatsApp não tem deep link público para uma mensagem específica — só
/// `whatsapp://send?phone=`, que abre a conversa com um número. Então o melhor
/// possível é: conversa certa quando o chat tem telefone na agenda; nos demais
/// (grupos e contatos fora da agenda, que só têm LID), a mensagem dentro do ziri.
struct OpenZiriMessageIntent: OpenIntent {
    static let title: LocalizedStringResource = "Abrir conversa no WhatsApp"

    // Sem `supportedModes = .background`: um OpenIntent que proíbe primeiro
    // plano não era chamado no toque da citação. O preço é o ziri aparecer por
    // um instante antes de repassar para o WhatsApp.

    @Parameter(title: "Mensagem")
    var target: ZiriMessageEntity

    // `& OpensIntent` não é enfeite: sem ele o runtime descarta o OpenURLIntent
    // devolvido ("Did not declare OpensIntent but provided one") e o toque só
    // abre o ziri. O compilador aceita as duas assinaturas; quem valida é o sistema.
    func perform() async throws -> some IntentResult & OpensIntent {
        openLog.notice("caminho: OpenIntent — mensagem \(target.id, privacy: .public)")
        return .result(opensIntent: OpenURLIntent(await ZiriOpener.destination(forMessageID: target.id)))
    }
}

let openLog = Logger(subsystem: "fi.ziri.app", category: "open")

/// Destino do toque, resolvido na hora e compartilhado por todas as portas de
/// entrada: OpenIntent, continuação do Spotlight/Siri e link ziri://.
enum ZiriOpener {
    static func destination(forMessageID id: String) async -> URL {
        if let phone = await MessageStore.shared.chatPhone(forMessageID: id),
           let url = URL(string: "whatsapp://send?phone=\(phone)") {
            openLog.notice("destino: WhatsApp (conversa com telefone)")
            return url
        }
        openLog.notice("destino: ziri (conversa sem telefone)")
        return ZiriLink.message(id)
    }

    /// Id da mensagem numa continuação do Spotlight/Siri. O sistema pode anotar a
    /// activity com a entidade; se não anotar, o identificador do item indexado
    /// ainda converte para ela.
    static func messageID(from activity: NSUserActivity) -> String? {
        if let entity = activity.appEntityIdentifier { return entity.identifier }
        guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return EntityIdentifier(activityIdentifier: raw)?.identifier ?? raw
    }
}

enum ZiriLink {
    static func message(_ id: String) -> URL {
        var c = URLComponents()
        c.scheme = "ziri"
        c.host = "message"
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        return c.url!
    }

    static func messageID(from url: URL) -> String? {
        guard url.scheme == "ziri", url.host == "message" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value
    }
}
