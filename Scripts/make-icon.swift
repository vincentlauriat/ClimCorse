#!/usr/bin/env swift
//
// Génère l'icône de ClimCorse dans Assets.xcassets/AppIcon.appiconset.
//
// Usage : swift Scripts/make-icon.swift
//
// macOS n'applique aucun masque aux icônes d'application : le squircle et sa
// marge transparente doivent être dessinés ici. Une icône qui va bord à bord
// dépasse visuellement toutes ses voisines dans le Dock.

import AppKit
import Foundation

let canvas: CGFloat = 1024
// Proportions Apple : contenu de 824 pt centré dans 1024, coins de 185.
let inset: CGFloat = 100
let cornerRadius: CGFloat = 185

let outputDirectory = FileManager.default.currentDirectoryPath
    + "/ClimCorse/Assets.xcassets/AppIcon.appiconset"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

let body = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let squircle = CGPath(roundedRect: body,
                      cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                      transform: nil)

// — Fond : dégradé du bleu profond au cyan, en diagonale —
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.043, green: 0.239, blue: 0.494, alpha: 1),
        CGColor(red: 0.086, green: 0.478, blue: 0.788, alpha: 1),
        CGColor(red: 0.290, green: 0.757, blue: 0.925, alpha: 1)
    ] as CFArray,
    locations: [0, 0.55, 1]
)!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: body.minX, y: body.maxY),
                       end: CGPoint(x: body.maxX, y: body.minY),
                       options: [])

// — Souffle : trois traits incurvés, décroissants —
//
// Chaque trait part de la gauche, ondule, et se termine par une volute.
// L'épaisseur et l'opacité décroissent vers le bas pour suggérer la
// dispersion de l'air.
struct Stream {
    let y: CGFloat
    let length: CGFloat
    let width: CGFloat
    let alpha: CGFloat
    let curl: CGFloat
}

let streams = [
    Stream(y: 660, length: 0.78, width: 46, alpha: 1.00, curl: 78),
    Stream(y: 512, length: 0.92, width: 52, alpha: 0.92, curl: 96),
    Stream(y: 364, length: 0.62, width: 40, alpha: 0.72, curl: 64)
]

ctx.setLineCap(.round)
ctx.setLineJoin(.round)

for stream in streams {
    let startX = body.minX + 118
    let endX = body.minX + 118 + (body.width - 236) * stream.length

    let path = CGMutablePath()
    path.move(to: CGPoint(x: startX, y: stream.y))
    // Ondulation douce sur la course principale.
    path.addCurve(
        to: CGPoint(x: endX, y: stream.y),
        control1: CGPoint(x: startX + (endX - startX) * 0.35, y: stream.y + 46),
        control2: CGPoint(x: startX + (endX - startX) * 0.65, y: stream.y - 46)
    )
    // Volute terminale : l'air s'enroule au lieu de s'arrêter net.
    path.addCurve(
        to: CGPoint(x: endX - stream.curl * 0.35, y: stream.y + stream.curl * 0.30),
        control1: CGPoint(x: endX + stream.curl * 0.75, y: stream.y + stream.curl * 0.10),
        control2: CGPoint(x: endX + stream.curl * 0.55, y: stream.y + stream.curl * 0.60)
    )

    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: stream.alpha))
    ctx.setLineWidth(stream.width)
    ctx.addPath(path)
    ctx.strokePath()
}

ctx.restoreGState()

// — Liseré intérieur : détache l'icône des fonds clairs —
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3),
                   cornerWidth: cornerRadius - 3, cornerHeight: cornerRadius - 3,
                   transform: nil))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
ctx.setLineWidth(6)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let masterPath = outputDirectory + "/icon_1024.png"
try png.write(to: URL(fileURLWithPath: masterPath))
print("écrit  icon_1024.png")

// Les tailles dérivées sont produites par `sips`, qui rééchantillonne
// correctement. Les noms doivent correspondre exactement à Contents.json.
for size in [512, 256, 128, 64, 32, 16] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "\(size)", "\(size)", masterPath,
                         "--out", outputDirectory + "/icon_\(size).png"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    print("écrit  icon_\(size).png")
}
