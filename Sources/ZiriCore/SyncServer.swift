import Foundation
import Network

/// Servidor de sync na rede local. Anuncia via Bonjour e fala TLS 1.3 com PSK —
/// nenhum servidor externo, nenhuma porta exposta fora da LAN.
public final class SyncServer: @unchecked Sendable {
    let store: ZiriStore
    let key: PairingKey
    let port: NWEndpoint.Port
    var listener: NWListener?
    let queue = DispatchQueue(label: "fi.ziri.sync")
    public var onEvent: (@Sendable (String) -> Void)?

    public init(store: ZiriStore, key: PairingKey, port: UInt16 = 0) {
        self.store = store
        self.key = key
        self.port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
    }

    public func start() throws {
        let params = NWParameters(tls: tlsOptions(), tcp: .init())
        params.includePeerToPeer = true

        let listener = try NWListener(using: params, on: port)
        listener.service = NWListener.Service(
            name: "ziri-\(ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: ""))",
            type: SyncProtocol.serviceType
        )
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let p = listener.port.map { ":\($0.rawValue)" } ?? ""
                self?.onEvent?("escutando em \(SyncProtocol.serviceType)\(p)")
            case .failed(let e):
                self?.onEvent?("falhou: \(e)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// TLS 1.3 autenticado só pela PSK: quem não tem o código de pareamento não
    /// completa o handshake, então não existe endpoint anônimo na rede.
    private func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        let psk = key.raw.withUnsafeBytes {
            DispatchData(bytes: UnsafeRawBufferPointer(start: $0.baseAddress, count: $0.count))
        }
        let identity = "ziri".data(using: .utf8)!.withUnsafeBytes {
            DispatchData(bytes: UnsafeRawBufferPointer(start: $0.baseAddress, count: $0.count))
        }
        sec_protocol_options_add_pre_shared_key(sec, psk as __DispatchData, identity as __DispatchData)
        // PSK externa no Network.framework roda na suíte PSK de TLS 1.2.
        // TLS 1.3 com suíte não-PSK derruba o handshake (-9858).
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        return options
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveFrame(conn) { [weak self] data in
            guard let self, let data else { conn.cancel(); return }
            do {
                let req = try SyncProtocol.decoder.decode(SyncRequest.self, from: data)
                let messages = try store.messages(since: req.sinceDate, limit: req.limit)
                let resp = SyncResponse(messages: messages, hasMore: messages.count == req.limit)
                let payload = try SyncProtocol.encoder.encode(resp)
                onEvent?("sync: \(messages.count) mensagens desde \(req.sinceDate.map(String.init(describing:)) ?? "sempre")")
                conn.send(content: SyncProtocol.frame(payload), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            } catch {
                onEvent?("erro no pedido: \(error)")
                conn.cancel()
            }
        }
    }

    private func receiveFrame(_ conn: NWConnection, _ done: @escaping @Sendable (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { done(nil); return }
            let len = SyncProtocol.frameLength(header)
            guard len > 0, len <= SyncProtocol.maxFrame else { done(nil); return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, _ in
                done(body)
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
