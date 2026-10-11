// Gera o ícone do app do iPhone:
//   swift Tools/app-icon.swift ZiriApp/Sources/Assets.xcassets/AppIcon.appiconset/icon.png
// É também o que a Siri mostra no card quando a mensagem não tem foto de perfil.
// Só caminhos próprios: a licença dos SF Symbols proíbe usá-los em ícone de app.
import CoreGraphics
import Foundation
import ImageIO

let n = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colors = [
    CGColor(srgbRed: 0.10, green: 0.12, blue: 0.38, alpha: 1),
    CGColor(srgbRed: 0.38, green: 0.22, blue: 0.72, alpha: 1),
    CGColor(srgbRed: 0.92, green: 0.38, blue: 0.62, alpha: 1),
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: n, y: n), options: [])

// Balão: retângulo bem arredondado com rabicho embaixo à esquerda (y cresce para cima).
let body = CGRect(x: 192, y: 300, width: 640, height: 470)
let bubble = CGMutablePath()
bubble.addRoundedRect(in: body, cornerWidth: 200, cornerHeight: 200)
let tail = CGMutablePath()
tail.move(to: CGPoint(x: 300, y: 340))
tail.addQuadCurve(to: CGPoint(x: 230, y: 205), control: CGPoint(x: 300, y: 250))
tail.addQuadCurve(to: CGPoint(x: 470, y: 310), control: CGPoint(x: 380, y: 220))
tail.closeSubpath()
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(bubble); ctx.fillPath()
ctx.addPath(tail); ctx.fillPath()

// Três pontos com as cores do fundo: "alguém disse algo".
let dots: [(CGFloat, CGColor)] = [
    (372, CGColor(srgbRed: 0.24, green: 0.18, blue: 0.56, alpha: 1)),
    (512, CGColor(srgbRed: 0.42, green: 0.24, blue: 0.74, alpha: 1)),
    (652, CGColor(srgbRed: 0.80, green: 0.34, blue: 0.64, alpha: 1)),
]
for (x, c) in dots {
    ctx.setFillColor(c)
    ctx.fillEllipse(in: CGRect(x: x - 52, y: body.midY - 52, width: 104, height: 104))
}

let out = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(out, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
