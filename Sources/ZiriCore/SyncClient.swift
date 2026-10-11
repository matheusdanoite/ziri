import Foundation
import Network

/// Cliente de sync. Roda no iPhone (e no Mac, para diagnóstico): descobre o
/// servidor por Bonjour, faz o handshake com a PSK e pede o delta.
public final class SyncClient: @unchecked Sendable {
    let key: PairingKey
    let queue = DispatchQueue(label: "fi.ziri.client")

    public var onState: (@Sendable (String) -> Void)?

    public init(key: PairingKey) { self.key = key }

    public enum SyncError: Error, CustomStringConvertible {
        case notFound
        case localNetworkDenied
        case connectionFailed(String)
        case badResponse

        public var description: String {
            switch self {
            case .notFound: "nenhum servidor ziri encontrado na rede local"
            case .localNetworkDenied:
                "permissão de rede local negada — Ajustes → Privacidade e Segurança → Rede Local → ziri"
            case .connectionFailed(let m): "conexão falhou: \(m)"
            case .badResponse: "resposta inválida do servidor"
            }
        }
    }

    /// Procura o serviço por Bonjour e retorna o primeiro endpoint encontrado.
    public func discover(timeout: TimeInterval = 5) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { cont in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjour(type: SyncProtocol.serviceType, domain: nil),
                using: params
            )
            let resumed = Locked(false)
            browser.browseResultsChangedHandler = { results, _ in
                guard let first = results.first, resumed.exchange(true) == false else { return }
                browser.cancel()
                cont.resume(returning: first.endpoint)
            }
            // NoAuth(-65555) chega como falha do browser, não como ausência de
            // resultados: sem tratar isso, uma permissão negada vira "não
            // encontrei nada" depois de 5s e ninguém descobre a causa.
            browser.stateUpdateHandler = { state in
                guard case .failed(let error) = state,
                      resumed.exchange(true) == false else { return }
                browser.cancel()
                let denied = if case .dns(let code) = error {
                    code == -65555
                } else {
                    false
                }
                cont.resume(throwing: denied ? SyncError.localNetworkDenied : SyncError.notFound)
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard resumed.exchange(true) == false else { return }
                browser.cancel()
                cont.resume(throwing: SyncError.notFound)
            }
        }
    }

    public func fetch(
        from endpoint: NWEndpoint, since: Date?, limit: Int = 5_000, photosVersion: String? = nil
    ) async throws -> SyncResponse {
        let params = NWParameters(tls: tlsOptions(), tcp: .init())
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)

        return try await withCheckedThrowingContinuation { cont in
            let resumed = Locked(false)
            let finish: @Sendable (Result<SyncResponse, Error>) -> Void = { result in
                guard resumed.exchange(true) == false else { return }
                conn.cancel()
                cont.resume(with: result)
            }

            conn.stateUpdateHandler = { [onState] state in
                onState?("\(state)")
                switch state {
                case .ready:
                    do {
                        let payload = try SyncProtocol.encoder.encode(
                            SyncRequest(since: since, limit: limit, photosVersion: photosVersion)
                        )
                        conn.send(content: SyncProtocol.frame(payload), completion: .contentProcessed { err in
                            if let err { finish(.failure(SyncError.connectionFailed("\(err)"))); return }
                            Self.receiveFrame(conn) { data in
                                guard let data,
                                      let resp = try? SyncProtocol.decoder.decode(SyncResponse.self, from: data)
                                else { finish(.failure(SyncError.badResponse)); return }
                                finish(.success(resp))
                            }
                        })
                    } catch {
                        finish(.failure(error))
                    }
                case .failed(let e):
                    finish(.failure(SyncError.connectionFailed("\(e)")))
                case .waiting(let e):
                    // sem isso o Network.framework fica tentando de novo para sempre
                    finish(.failure(SyncError.connectionFailed("\(e)")))
                case .cancelled:
                    finish(.failure(SyncError.connectionFailed("cancelada")))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

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

    static func receiveFrame(_ conn: NWConnection, _ done: @escaping @Sendable (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { done(nil); return }
            let len = SyncProtocol.frameLength(header)
            guard len > 0, len <= SyncProtocol.maxFrame else { done(nil); return }
            var buffer = Data(capacity: len)
            func more() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: len - buffer.count) { chunk, _, _, _ in
                    guard let chunk, !chunk.isEmpty else { done(nil); return }
                    buffer.append(chunk)
                    if buffer.count >= len { done(buffer) } else { more() }
                }
            }
            more()
        }
    }
}

/// Caixa thread-safe para o guard de continuação única.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func exchange(_ new: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
