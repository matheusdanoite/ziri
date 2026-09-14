import AppKit
import Foundation
import ServiceManagement
import ZiriCore
import os

let bridgeLog = Logger(subsystem: "fi.ziri.mac", category: "bridge")

/// Laço do Mac: WhatsApp desta máquina → store local → índice semântico.
@MainActor
@Observable
final class MacBridge {
    enum State: Equatable {
        case starting
        case working(String)
        case idle(Date)
        case paused
        case failed(Problem)
    }

    enum Problem: Equatable {
        case whatsAppNotInstalled
        case noAccess
        case other(String)
    }

    private(set) var state: State = .starting
    private(set) var messageCount = 0
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Dois minutos: a Siri do Mac responde sobre conversas desta máquina, então
    /// frescor importa mais que no iPhone. As rodadas sem mudança nos arquivos do
    /// WhatsApp saem quase de graça (só stat, sem copiar o banco).
    private let interval: Duration = .seconds(120)
    private let pausedKey = "ziri.mac.paused"

    init() {
        if UserDefaults.standard.bool(forKey: pausedKey) { state = .paused }
        Task { await loop() }
    }

    var isWorking: Bool { if case .working = state { true } else { false } }

    var menuSymbol: String {
        switch state {
        case .failed: "exclamationmark.bubble"
        case .paused: "bubble.left.and.exclamationmark.bubble.right"
        default: "bubble.left.and.text.bubble.right"
        }
    }

    private func loop() async {
        messageCount = await MessageStore.shared.count
        while !Task.isCancelled {
            await runOnce()
            try? await Task.sleep(for: interval)
        }
    }

    func runOnce(force: Bool = false) async {
        if isWorking { return }
        if state == .paused, !force { return }
        if force {
            UserDefaults.standard.set(false, forKey: pausedKey)
        }
        do {
            state = .working("Lendo o WhatsApp…")
            let novas = try await MessageStore.shared.ingestFromWhatsApp()
            state = .working("Indexando para a Siri…")
            let indexadas = try await Indexer.shared.indexPending()
            messageCount = await MessageStore.shared.count
            if novas > 0 || indexadas > 0 {
                bridgeLog.notice("rodada: \(novas) novas, \(indexadas) indexadas, \(self.messageCount) no total")
            }
            state = .idle(.now)
        } catch MacIngestError.whatsAppNotInstalled {
            state = .failed(.whatsAppNotInstalled)
        } catch MacIngestError.noAccess {
            bridgeLog.error("sem acesso ao banco do WhatsApp")
            state = .failed(.noAccess)
        } catch {
            bridgeLog.error("rodada falhou: \(String(describing: error), privacy: .public)")
            state = .failed(.other("\(error)"))
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            bridgeLog.error("abrir ao iniciar sessão: \(String(describing: error), privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Botão de pânico. Pausa a indexação automática, senão a próxima rodada
    /// devolveria tudo ao índice dois minutos depois.
    func eraseIndex() async {
        let alert = NSAlert()
        alert.messageText = "Apagar suas mensagens do índice da Siri neste Mac?"
        alert.informativeText = "A Siri deixa de encontrar suas conversas do WhatsApp aqui. A indexação fica pausada até você retomar."
        alert.addButton(withTitle: "Apagar")
        alert.addButton(withTitle: "Cancelar")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await Indexer.shared.removeAll()
            UserDefaults.standard.set(true, forKey: pausedKey)
            state = .paused
            bridgeLog.notice("índice apagado; indexação pausada")
        } catch {
            state = .failed(.other("\(error)"))
        }
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
