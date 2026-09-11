import CoreSpotlight
import SwiftUI
import ZiriCore
import os

struct ContentView: View {
    @Bindable var sync: SyncManager
    @State private var code = ""
    @State private var opened: ZMessage?
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                if sync.isPaired {
                    Section("histórico") {
                        LabeledContent("mensagens", value: "\(sync.storedCount)")
                        if let s = sync.stats {
                            LabeledContent("conversas", value: "\(s.chats) (\(s.groups) grupos)")
                            if let last = s.last {
                                LabeledContent("mais recente", value: last.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }
                    Section("estado") {
                        statusRow
                        Button("sincronizar agora") { Task { await sync.sync() } }
                    }
                    Section {
                        Button("desparear", role: .destructive) { sync.unpair() }
                        Button("apagar do índice da Siri", role: .destructive) {
                            Task { try? await Indexer.shared.removeAll() }
                        }
                    }
                } else {
                    Section("parear com o Mac") {
                        Text("Rode `ziri status` no Mac e digite o código abaixo.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("código de pareamento", text: $code, axis: .vertical)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("parear") {
                            if sync.pair(withCode: code) { Task { await sync.sync() } }
                        }
                        .disabled(code.count < 20)
                    }
                }
            }
            .navigationTitle("ziri")
            .onOpenURL { url in
                openLog.notice("caminho: link \(url.scheme ?? "?", privacy: .public)")
                guard let id = ZiriLink.messageID(from: url) else { return }
                Task { opened = try? await MessageStore.shared.messages(withIDs: [id]).first }
            }
            // O toque numa citação da Siri pode chegar como continuação do
            // Spotlight em vez de OpenIntent — por isso as duas portas.
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                openLog.notice("caminho: continuação do Spotlight/Siri")
                guard let id = ZiriOpener.messageID(from: activity) else {
                    openLog.error("continuação sem id: \(String(describing: activity.userInfo), privacy: .public)")
                    return
                }
                openLog.notice("mensagem \(id, privacy: .public)")
                Task { await open(messageID: id) }
            }
            .onContinueUserActivity(CSQueryContinuationActionType) { _ in
                openLog.notice("caminho: continuação de busca, sem mensagem específica")
            }
            .sheet(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
                if let opened { MessageDetail(message: opened) }
            }
        }
    }

    private func open(messageID id: String) async {
        let url = await ZiriOpener.destination(forMessageID: id)
        if let local = ZiriLink.messageID(from: url) {
            opened = try? await MessageStore.shared.messages(withIDs: [local]).first
        } else {
            openURL(url)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch sync.state {
        case .idle: Label("pronto", systemImage: "checkmark.circle")
        case .unpaired: Label("não pareado", systemImage: "link.badge.plus")
        case .syncing(let msg): Label(msg, systemImage: "arrow.triangle.2.circlepath")
        case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .done(let received, let indexed, let at):
            Label("\(received) novas, \(indexed) indexadas — \(at.formatted(date: .omitted, time: .shortened))",
                  systemImage: "checkmark.circle.fill")
        }
    }
}

/// Destino das citações que o WhatsApp não consegue abrir por link.
struct MessageDetail: View {
    let message: ZMessage

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(message.body).textSelection(.enabled)
                } header: {
                    Text("\(message.fromMe ? "você" : message.sender) · \(message.sentAt.formatted(date: .abbreviated, time: .shortened))")
                }
                Section {
                    LabeledContent("conversa", value: message.chatName)
                } footer: {
                    Text(message.isGroup
                         ? "O WhatsApp não aceita abrir grupos por link — só por convite."
                         : "Este contato não tem telefone na sua agenda, e o WhatsApp só abre conversas por link a partir de um número.")
                }
            }
            .navigationTitle(message.isGroup ? "grupo" : "mensagem")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
