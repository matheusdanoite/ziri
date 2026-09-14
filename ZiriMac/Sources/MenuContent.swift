import AppKit
import SwiftUI
import ZiriCore

struct MenuContent: View {
    @Bindable var bridge: MacBridge

    var body: some View {
        Text(headline)
        Text(status)

        if bridge.state == .failed(.noAccess) {
            Button("Permitir acesso ao WhatsApp…") { bridge.openPrivacySettings() }
        }

        Divider()

        if bridge.state == .paused {
            Button("Retomar indexação") { Task { await bridge.runOnce(force: true) } }
        } else {
            Button("Indexar agora") { Task { await bridge.runOnce(force: true) } }
                .disabled(bridge.isWorking)
                .keyboardShortcut("r")
        }

        Toggle("Abrir ao iniciar sessão", isOn: Binding(
            get: { bridge.launchAtLogin },
            set: { bridge.setLaunchAtLogin($0) }
        ))

        Button("Apagar do índice da Siri…") { Task { await bridge.eraseIndex() } }
            .disabled(bridge.isWorking || bridge.state == .paused)

        Divider()

        Button("Sair do ziri") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var headline: String {
        let n = bridge.messageCount.formatted()
        return bridge.messageCount == 1 ? "1 mensagem do WhatsApp" : "\(n) mensagens do WhatsApp"
    }

    private var status: String {
        switch bridge.state {
        case .starting: "Iniciando…"
        case .working(let what): what
        case .idle(let at): "Disponível para a Siri · \(at.formatted(date: .omitted, time: .shortened))"
        case .paused: "Indexação pausada"
        case .failed(.whatsAppNotInstalled): "WhatsApp para Mac não encontrado"
        case .failed(.noAccess): "Sem acesso aos dados do WhatsApp"
        case .failed(.other(let msg)): "Erro: \(msg.prefix(60))"
        }
    }
}

/// Janela das citações que o WhatsApp não consegue abrir por link.
struct MessageCard: View {
    let message: ZMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image("WhatsApp")
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.chatName).font(.headline)
                    Text("\(message.fromMe ? "Você" : message.sender) · \(message.sentAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(message.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(message.isGroup
                 ? "O WhatsApp não abre grupos por link — só por convite."
                 : "Este contato não tem telefone na agenda do WhatsApp, e o WhatsApp só abre conversas por link a partir de um número.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Abrir o WhatsApp") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
