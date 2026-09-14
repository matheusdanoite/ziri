import AppKit
import CoreSpotlight
import SwiftUI
import ZiriCore
import os

/// ziri para Mac: vive na barra de menus, lê o WhatsApp desta máquina e
/// entrega as mensagens ao índice semântico da Siri no macOS.
@main
struct ZiriMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var bridge = MacBridge()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(bridge: bridge)
        } label: {
            Image(systemName: bridge.menuSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Recebe o que chega de fora: o link ziri:// do OpenIntent e o toque num
/// resultado do Spotlight/Siri que venha como continuação.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openLog.notice("caminho: link \(url.scheme ?? "?", privacy: .public)")
            guard let id = ZiriLink.messageID(from: url) else { continue }
            Task { await show(messageID: id) }
        }
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = ZiriOpener.messageID(from: userActivity) else { return false }
        openLog.notice("caminho: continuação do Spotlight/Siri — mensagem \(id, privacy: .public)")
        Task {
            let url = await ZiriOpener.destination(forMessageID: id)
            if ZiriLink.messageID(from: url) != nil {
                await show(messageID: id)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return true
    }

    /// Destino das citações que o WhatsApp não abre por link (grupos, contatos
    /// sem telefone). Uma janela só, reaproveitada.
    private func show(messageID id: String) async {
        guard let message = try? await MessageStore.shared.messages(withIDs: [id]).first else {
            openLog.error("mensagem \(id, privacy: .public) não está no store")
            return
        }
        let host = NSHostingController(rootView: MessageCard(message: message))
        let window = self.window ?? NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentViewController = host
        window.title = message.isGroup ? "Mensagem do grupo" : "Mensagem"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
