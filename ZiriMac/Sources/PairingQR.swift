import CoreGraphics
import CoreImage
import Foundation

/// QR code no Terminal, para o iPhone parear pela Câmera.
enum PairingQR {
    /// Módulos do QR (true = escuro), com a margem de 4 módulos que os leitores
    /// esperam. Linha 0 é a de cima.
    static func modules(for text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }

        // Desenhado num contexto de bitmap, a linha 0 da memória é a de cima —
        // o CIImage tem a origem embaixo, e um QR espelhado nem sempre lê.
        let w = cg.width, h = cg.height
        var gray = [UInt8](repeating: 255, count: w * h)
        let drew = gray.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        let quiet = 4
        let size = max(w, h) + 2 * quiet
        return (0..<size).map { y in
            (0..<size).map { x in
                let (px, py) = (x - quiet, y - quiet)
                guard px >= 0, py >= 0, px < w, py < h else { return false }
                return gray[py * w + px] < 128
            }
        }
    }

    /// Duas linhas de módulos por linha de texto, com meio-blocos. Fundo branco
    /// e frente preta explícitos: num Terminal escuro, o QR sairia invertido.
    static func render(_ m: [[Bool]]) -> String {
        let on = "\u{1B}[30;47m", off = "\u{1B}[0m"
        var out = ""
        for y in stride(from: 0, to: m.count, by: 2) {
            out += on
            for x in m[y].indices {
                let top = m[y][x], bottom = y + 1 < m.count && m[y + 1][x]
                let block = switch (top, bottom) {
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                case (false, false): " "
                }
                out += block
            }
            out += off + "\n"
        }
        return out
    }
}
