import Foundation
import Testing
@testable import ZiriCore

/// O QR code do Mac vira um link ziri://pair que a Câmera do iPhone abre. Se o
/// link não voltar à mesma chave, o handshake TLS falha sem dizer por quê.
@Suite struct PairingURLTests {
    @Test func linkVoltaParaAMesmaChave() throws {
        let key = PairingKey.generate()
        let back = try #require(PairingKey.fromPairingURL(key.pairingURL))
        #expect(back.raw == key.raw)
    }

    @Test func outrosLinksDoZiriNaoPareiam() throws {
        let url = try #require(URL(string: "ziri://message?id=ABC"))
        #expect(PairingKey.fromPairingURL(url) == nil)
    }

    @Test func codigoTruncadoNaoPareia() throws {
        let code = PairingKey.generate().code
        let url = try #require(URL(string: "ziri://pair?code=\(code.prefix(20))"))
        #expect(PairingKey.fromPairingURL(url) == nil)
    }
}
