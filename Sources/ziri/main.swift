import Foundation
import ZiriCore
import Network

setvbuf(stdout, nil, _IOLBF, 0)

let fmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

func log(_ msg: String) {
    let t = DateFormatter()
    t.dateFormat = "HH:mm:ss"
    print("[\(t.string(from: Date()))] \(msg)")
    fflush(stdout)
}

func printStats(_ s: ZiriStore.Stats) {
    print("  mensagens : \(s.messages)")
    print("  conversas : \(s.chats) (\(s.groups) grupos)")
    if let f = s.first, let l = s.last {
        print("  período   : \(fmt.string(from: f)) → \(fmt.string(from: l))")
    }
}

func cmdExtract() throws {
    let store = try ZiriStore()
    let started = Date()
    if try store.needsFullResync {
        print("→ schema migrado: reprocessando o histórico completo…")
    } else if let w = try store.watermark {
        print("→ extraindo mensagens após \(fmt.string(from: w))…")
    } else {
        print("→ primeira extração (histórico completo)…")
    }
    let novas = try Bridge(store: store, key: try PairingKey.loadOrCreate()).ingest()
    print("✓ \(novas) novas em \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    printStats(try store.stats)
}

func cmdStatus() throws {
    let reader = ChatStorageReader()
    print("fonte    : \(reader.sourceExists ? "ok" : "AUSENTE") — \(ChatStorageReader.defaultPath)")
    print("store    : \(ZiriStore.defaultPath)")
    print("pareamento: \(try PairingKey.loadOrCreate().code)")
    printStats(try ZiriStore().stats)
}

/// Serve o delta na rede local, lendo o WhatsApp a cada pedido — o mesmo que
/// o agente do ziri.app faz. Rodando do Terminal, usa a permissão do Terminal para ler
/// o WhatsApp; serve para depurar, não para ficar rodando (ver README).
func cmdServe() throws {
    let store = try ZiriStore()
    let key = try PairingKey.loadOrCreate()
    let bridge = Bridge(store: store, key: key)
    bridge.onEvent = { log($0) }

    log("store com \(try store.count) mensagens")
    log("código de pareamento: \(key.code)")
    try bridge.start()
    log("servindo — ctrl-c para sair")
    dispatchMain()
}

/// Diagnóstico: faz o papel do iPhone contra o servidor local.
func cmdProbe(since: Date?, port: Int) async throws {
    let key = try PairingKey.loadOrCreate()
    let client = SyncClient(key: key)
    if ProcessInfo.processInfo.environment["ZIRI_DEBUG"] != nil {
        client.onState = { log("estado: \($0)") }
    }
    let endpoint: NWEndpoint
    if port > 0 {
        endpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        print("→ conectando direto em 127.0.0.1:\(port)…")
    } else {
        print("→ procurando servidor ziri na rede local…")
        endpoint = try await client.discover()
        print("✓ encontrado: \(endpoint)")
    }
    let started = Date()
    let resp = try await client.fetch(from: endpoint, since: since)
    let elapsed = Date().timeIntervalSince(started)
    print("✓ \(resp.messages.count) mensagens em \(String(format: "%.2f", elapsed))s (hasMore: \(resp.hasMore))")
    let withPhone = resp.messages.filter { $0.chatPhone != nil }.count
    print("  com telefone (abrem no WhatsApp): \(withPhone)/\(resp.messages.count)")
    print("  mapa conversa→telefone: \(resp.chatPhones?.count ?? 0) conversas")
    if let first = resp.messages.first, let last = resp.messages.last {
        print("  \(fmt.string(from: first.sentAt)) → \(fmt.string(from: last.sentAt))")
        print("  amostra: \(first.isGroup ? "[grupo] " : "")\(first.sender): \(first.body.prefix(40))…")
    }
}

let args = Array(CommandLine.arguments.dropFirst())

func intFlag(_ name: String, default def: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
    return Int(args[i + 1]) ?? def
}

do {
    switch args.first {
    case "extract":
        try cmdExtract()
    case "status":
        try cmdStatus()
    case "serve":
        try cmdServe()
    case "probe":
        let days = intFlag("--days", default: 0)
        let since = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil
        try await cmdProbe(since: since, port: intFlag("--port", default: 0))
    default:
        print("""
        ziri — ponte entre o histórico do WhatsApp e o índice semântico da Siri

        uso:
          ziri extract              extrai novas mensagens do WhatsApp para o store
          ziri status               estado do store e código de pareamento
          ziri serve                serve na LAN em primeiro plano (o agente do ziri.app faz isto)
          ziri probe [--days N]     simula o iPhone contra o servidor (diagnóstico)
        """)
    }
} catch {
    print("✗ \(error)")
    exit(1)
}
