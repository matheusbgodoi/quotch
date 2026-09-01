import AppKit
import CoreGraphics

// Gera o AppIcon do Quotch: squircle preto, anel de cota com arco em gradiente
// verde→amarelo→laranja e um "%" no centro. Uso: swift icon.swift <saida.iconset>
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func squircle(_ r: CGRect, k: CGFloat = 0.2237) -> CGPath {
    // Aproximação do squircle do macOS via raio ~22,37% do lado
    return CGPath(roundedRect: r, cornerWidth: r.width * k, cornerHeight: r.height * k, transform: nil)
}

func render(size: Int) -> CGImage {
    let S = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Grid do macOS: o ícone ocupa ~80% da tela (margem 10%)
    let inset = S * 0.10
    let box = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)

    // Sombra suave
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.05,
                  color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(squircle(box)); ctx.setFillColor(CGColor(gray: 0.06, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Corpo: gradiente vertical grafite -> preto
    ctx.saveGState(); ctx.addPath(squircle(box)); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1),
                                                CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    // Brilho no topo (luz batendo no material)
    let hl = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.maxY - box.height * 0.35), options: [])
    ctx.restoreGState()

    // Anel
    let c = CGPoint(x: S / 2, y: S / 2)
    let R = box.width * 0.30
    let track = box.width * 0.075
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 0.19, green: 0.19, blue: 0.19, alpha: 1))
    ctx.setLineWidth(track)
    ctx.addArc(center: c, radius: R, startAngle: 0, endAngle: 2 * .pi, clockwise: false); ctx.strokePath()

    // Arco de cota (72%) em gradiente angular verde -> amarelo -> laranja, sentido horário a partir das 12h
    let sweep: CGFloat = 0.72
    let steps = 180
    let start = CGFloat.pi / 2
    for i in 0..<steps {
        let t0 = CGFloat(i) / CGFloat(steps), t1 = CGFloat(i + 1) / CGFloat(steps)
        let a0 = start - t0 * sweep * 2 * .pi, a1 = start - t1 * sweep * 2 * .pi - 0.01
        let t = t0
        let col: CGColor = {
            // #00FF88 -> #F2FF00 -> #FF3F00
            if t < 0.55 { let u = t / 0.55; return CGColor(red: u * 0.95, green: 1, blue: 0.533 * (1 - u), alpha: 1) }
            let u = (t - 0.55) / 0.45; return CGColor(red: 0.95 + 0.05 * u, green: 1 - 0.753 * u, blue: 0, alpha: 1)
        }()
        ctx.setStrokeColor(col); ctx.setLineWidth(track * 0.62)
        ctx.setLineCap(i == 0 || i == steps - 1 ? .round : .butt)
        ctx.addArc(center: c, radius: R, startAngle: a0, endAngle: a1, clockwise: true); ctx.strokePath()
    }

    // "%" no centro, SF Rounded bold
    let font = NSFont.systemFont(ofSize: box.width * 0.30, weight: .bold)
    let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: font.pointSize) ?? font
    let attrs: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: NSColor.white]
    let str = NSAttributedString(string: "%", attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)
    let b = CTLineGetImageBounds(line, ctx)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.02, color: CGColor(gray: 1, alpha: 0.25))
    ctx.textPosition = CGPoint(x: c.x - b.midX, y: c.y - b.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
for (pt, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    save(render(size: pt * scale), "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png")
}
save(render(size: 1024), "preview_1024.png")
print("iconset ok")
