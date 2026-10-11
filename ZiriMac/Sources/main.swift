import CoreSpotlight
import Foundation
import ServiceManagement
import ZiriCore
import os

/// ziri para Mac: um agente do launchd, sem janela, menu nem ícone. Serve as
/// mensagens do WhatsApp desta máquina para o iPhone pela rede local — é lá que
/// a Siri as encontra.
///
/// Por que um app e não o binário `ziri serve`: ler o group container do
/// WhatsApp exige a permissão de dados de outros apps, que o macOS amarra à
/// assinatura. O binário ad-hoc muda de identidade a cada build e, com o SIP
/// ligado, leva código 23 (SQLITE_AUTH); o ziri.app tem identidade estável e
/// a permissão sobrevive a reinstalações.
///
/// O mesmo executável tem três papéis:
/// - lançado pelo launchd (o agente embutido em Contents/Library/LaunchAgents):
///   serve, e não sai mais;
/// - aberto pela pessoa ou pelo instalador: registra o agente e sai;
/// - com `--pair`: mostra o QR de pareamento no Terminal e sai;
/// - com `--uninstall`: tira o agente do launchd e sai.

let log = Logger(subsystem: "fi.ziri.mac", category: "agent")
let agentLabel = "fi.ziri.mac.agent"
let agent = SMAppService.agent(plistName: "\(agentLabel).plist")

// O launchd põe o Label do job em XPC_SERVICE_NAME. Aberto pelo
// LaunchServices, o app recebe outro nome ("application.fi.ziri.mac…").
if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel {
    serve()
} else if CommandLine.arguments.contains("--uninstall") {
    await uninstall()
} else if CommandLine.arguments.contains("--pair") {
    showPairing()
} else {
    await install()
}

func serve() -> Never {
    do {
        let store = try ZiriStore()
        let key = try PairingKey.loadOrCreate()
        let bridge = Bridge(store: store, key: key)
        bridge.onEvent = { log.notice("\($0, privacy: .public)") }
        let count = try store.count
        log.notice("agente no ar, \(count) mensagens no store")
        try bridge.start()
        // O Bridge vive enquanto o processo viver: dispatchMain não retorna.
        withExtendedLifetime(bridge) { dispatchMain() }
    } catch {
        log.error("agente não subiu: \(String(describing: error), privacy: .public)")
        exit(1)
    }
}

@MainActor
func install() async {
    await cleanUpMenuBarVersion()

    if agent.status != .enabled {
        do {
            try agent.register()
        } catch {
            log.error("registrar o agente: \(String(describing: error), privacy: .public)")
        }
    }
    switch agent.status {
    case .enabled:
        log.notice("agente registrado")
    case .requiresApproval:
        // Desligado em Itens de Início: só a pessoa reativa, e lá.
        log.notice("agente aguardando aprovação em Itens de Início")
        SMAppService.openSystemSettingsLoginItems()
    default:
        log.error("agente não registrado: status \(agent.status.rawValue)")
    }
}

/// Sem menu para mostrar o código: o instalador roda isto no Terminal.
func showPairing() {
    guard let key = try? PairingKey.loadOrCreate() else {
        print("não consegui ler nem criar ~/.ziri/pairing.key")
        exit(1)
    }
    // Fora de um terminal (redirecionado para arquivo), o QR seria só lixo ANSI.
    if isatty(STDOUT_FILENO) != 0, let qr = PairingQR.modules(for: key.pairingURL.absoluteString) {
        print(PairingQR.render(qr))
    }
    print("código de pareamento: \(key.code)")
}

/// O store e a chave em ~/.ziri ficam: são do usuário, e o instalador pergunta.
@MainActor
func uninstall() async {
    do {
        try await agent.unregister()
        log.notice("agente removido")
    } catch {
        // Já não registrado também cai aqui; o launchctl do script confirma.
        log.error("remover o agente: \(String(describing: error), privacy: .public)")
    }
}

/// A versão anterior do ziri vivia na barra de menus, abria como item de
/// início e indexava na Siri do Mac — que recusa doações de apps fora da App
/// Store, então nada chegava a ela. Desfaz o que pode ter sobrado.
@MainActor
func cleanUpMenuBarVersion() async {
    if SMAppService.mainApp.status != .notRegistered {
        try? await SMAppService.mainApp.unregister()
    }
    try? await CSSearchableIndex.default().deleteAllSearchableItems()
    // Cópia das mensagens que a versão de barra de menus guardava. O store do
    // agente é o ~/.ziri, o mesmo do `ziri status` e `ziri probe`.
    let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("fi.ziri.mac", isDirectory: true)
    try? FileManager.default.removeItem(at: old)
}
