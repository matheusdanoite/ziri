import SwiftUI

struct ContentView: View {
    @Bindable var sync: SyncManager
    @State private var code = ""

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
