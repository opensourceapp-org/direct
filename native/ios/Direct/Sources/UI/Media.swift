import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DirectCore
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MediaPrep {
    static let maxBytes = 6 * 1024 * 1024

    static func photo(_ data: Data) throws -> (kind: String, mime: String, name: String, bytes: Data) {
        if isGif(data) {
            guard data.count <= maxBytes else { throw PrepError("That GIF is over 6 MB. Choose a shorter one.") }
            return ("gif", "image/gif", "animation.gif", data)
        }
        guard let jpeg = compress(data, maxEdge: 1280, maxBytes: maxBytes, quality: 0.85) else {
            throw PrepError("That photo could not be read.")
        }
        guard jpeg.count <= maxBytes else { throw PrepError("That photo is still over 6 MB after compression.") }
        return ("image", "image/jpeg", "photo.jpg", jpeg)
    }

    static func video(_ data: Data, mime: String) throws -> (kind: String, mime: String, name: String, bytes: Data) {
        guard !data.isEmpty else { throw PrepError("That video is empty.") }
        guard data.count <= maxBytes else { throw PrepError("That video is over 6 MB. Choose a shorter one. DIRECT does not compress video.") }
        return ("video", mime.isEmpty ? "video/mp4" : mime, "video.mp4", data)
    }

    static func avatar(_ data: Data) throws -> Data {
        var edge: CGFloat = 256
        var quality: CGFloat = 0.8
        while edge >= 48 {
            if let jpeg = compress(data, maxEdge: edge, maxBytes: 48_000, quality: quality),
               jpeg.count >= 3, jpeg.count <= 48_000, jpeg[0] == 0xFF, jpeg[1] == 0xD8 {
                return jpeg
            }
            if quality > 0.4 { quality -= 0.15 } else { edge *= 0.75; quality = 0.7 }
        }
        throw PrepError("Choose a smaller photo.")
    }

    static func qrAvatar(_ jpeg: Data?) -> Data? {
        guard let jpeg, jpeg.count >= 3, let tiny = compress(jpeg, maxEdge: 48, maxBytes: 700, quality: 0.5),
              tiny.count <= 700, tiny.first == 0xFF else { return nil }
        return tiny
    }

    static let stickerCount = 16

    static func sticker(_ index: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            switch index % stickerCount {
            case 0: head(cg, top: rgb(1, 0.88, 0.54), bottom: rgb(0.96, 0.65, 0.14)); eyes(cg, 118); blush(cg); mouth(cg, 156, 46)
            case 1: head(cg, top: rgb(1, 0.95, 0.66), bottom: rgb(1, 0.76, 0.28)); joy(cg, 112); blush(cg); openMouth(cg, 158, 34, tongue: true)
            case 2:
                head(cg, top: rgb(1, 0.76, 0.83), bottom: rgb(1, 0.42, 0.58))
                heart(cg, 92, 118, 16, rgb(0.88, 0.11, 0.28), rgb(1, 0.56, 0.69))
                heart(cg, 164, 118, 16, rgb(0.88, 0.11, 0.28), rgb(1, 0.56, 0.69))
                blush(cg); mouth(cg, 158, 40)
            case 3: head(cg, top: rgb(1, 0.88, 0.54), bottom: rgb(0.94, 0.71, 0.16)); eye(cg, 96, 120, 11); wink(cg, 162, 122, 16); blush(cg); mouth(cg, 156, 42)
            case 4:
                head(cg, top: rgb(0.72, 0.95, 1), bottom: rgb(0.24, 0.72, 0.88))
                eye(cg, 96, 112, 14); eye(cg, 160, 112, 14)
                rgb(0.12, 0.23, 0.30).setFill(); cg.fillEllipse(in: CGRect(x: 110, y: 150, width: 36, height: 36))
                rgb(1, 0.54, 0.50).setFill(); cg.fillEllipse(in: CGRect(x: 119, y: 165, width: 18, height: 18))
            case 5:
                head(cg, top: rgb(0.84, 0.90, 1), bottom: rgb(0.42, 0.55, 1))
                eye(cg, 96, 124, 10); eye(cg, 160, 124, 10)
                brow(cg, 96, 100, raised: true); brow(cg, 160, 100, raised: false)
                rgb(0.14, 0.23, 0.45).setStroke(); cg.setLineWidth(7); cg.setLineCap(.round)
                cg.addArc(center: CGPoint(x: 128, y: 196), radius: 36, startAngle: .pi + 0.4, endAngle: -.pi * 0.15, clockwise: false)
                cg.strokePath()
            case 6:
                head(cg, top: rgb(1, 0.71, 0.64), bottom: rgb(0.89, 0.29, 0.23))
                brow(cg, 96, 104, raised: false); brow(cg, 160, 104, raised: true)
                eye(cg, 96, 128, 9); eye(cg, 160, 128, 9)
                rgb(0.42, 0.11, 0.09).setStroke(); cg.setLineWidth(8); cg.setLineCap(.round)
                cg.move(to: CGPoint(x: 96, y: 176)); cg.addLine(to: CGPoint(x: 160, y: 176)); cg.strokePath()
            case 7:
                head(cg, top: rgb(0.72, 0.97, 0.83), bottom: rgb(0.12, 0.66, 0.44))
                rgb(0.08, 0.14, 0.11).setFill()
                fill(cg, UIBezierPath(roundedRect: CGRect(x: 58, y: 108, width: 64, height: 34), cornerRadius: 12))
                fill(cg, UIBezierPath(roundedRect: CGRect(x: 134, y: 108, width: 64, height: 34), cornerRadius: 12))
                cg.setStrokeColor(rgb(0.08, 0.14, 0.11).cgColor); cg.setLineWidth(8)
                cg.move(to: CGPoint(x: 122, y: 124)); cg.addLine(to: CGPoint(x: 134, y: 124)); cg.strokePath()
                UIColor.white.withAlphaComponent(0.35).setFill()
                fill(cg, CGRect(x: 68, y: 114, width: 28, height: 10))
                fill(cg, CGRect(x: 144, y: 114, width: 28, height: 10))
                mouth(cg, 162, 36)
            case 8:
                head(cg, top: rgb(1, 0.82, 0.88), bottom: rgb(1, 0.44, 0.63))
                eye(cg, 96, 118, 10); eye(cg, 160, 118, 10); blush(cg)
                fillRadial(cg, 128, 168, 28, rgb(1, 0.36, 0.54), rgb(0.76, 0.09, 0.36))
                UIColor.white.withAlphaComponent(0.35).setFill(); cg.fillEllipse(in: CGRect(x: 114, y: 156, width: 12, height: 12))
            case 9:
                head(cg, top: rgb(0.90, 0.86, 1), bottom: rgb(0.55, 0.42, 1))
                eye(cg, 108, 120, 10); eye(cg, 156, 114, 10); brow(cg, 108, 98, raised: true)
                rgb(0.23, 0.16, 0.42).setStroke(); cg.setLineWidth(7); cg.setLineCap(.round)
                cg.addArc(center: CGPoint(x: 138, y: 168), radius: 28, startAngle: 0.2, endAngle: 1.4, clockwise: false); cg.strokePath()
                rgb(1, 0.88, 0.70).setFill()
                cg.fillEllipse(in: CGRect(x: 160, y: 170, width: 32, height: 32))
                fill(cg, UIBezierPath(roundedRect: CGRect(x: 168, y: 176, width: 46, height: 30), cornerRadius: 14))
            case 10:
                shadow(cg, 128, 168, 70)
                heart(cg, 128, 132, 62, rgb(1, 0.30, 0.43), rgb(0.79, 0.09, 0.29))
                UIColor.white.withAlphaComponent(0.45).setFill(); cg.fillEllipse(in: CGRect(x: 86, y: 98, width: 28, height: 28))
            case 11: flame(cg)
            case 12: thumb(cg)
            case 13:
                do {
                    shadow(cg, 128, 150, 80)
                    cg.saveGState()
                    starPath(128, 128, 100, 44).addClip()
                    let gold = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(1, 0.96, 0.76).cgColor, rgb(1, 0.72, 0.01).cgColor] as CFArray, locations: [0, 1])!
                    cg.drawRadialGradient(gold, startCenter: CGPoint(x: 118, y: 90), startRadius: 0, endCenter: CGPoint(x: 128, y: 140), endRadius: 120, options: [])
                    cg.restoreGState()
                    eye(cg, 104, 124, 8); eye(cg, 152, 124, 8); mouth(cg, 150, 28)
                }
            case 14: party(cg)
            default: sparkles(cg)
            }
        }
        return image.pngData() ?? Data()
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    /// CGContext has no single-argument fill for a path or a rectangle on this SDK.
    private static func fill(_ cg: CGContext, _ path: UIBezierPath) {
        cg.addPath(path.cgPath)
        cg.fillPath()
    }

    private static func fill(_ cg: CGContext, _ rect: CGRect) {
        cg.addRect(rect)
        cg.fillPath()
    }

    private static func shadow(_ cg: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        UIColor.black.withAlphaComponent(0.12).setFill()
        cg.fillEllipse(in: CGRect(x: cx - r * 0.72, y: cy + 18, width: r * 1.44, height: 22))
    }

    private static func fillRadial(_ cg: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ top: UIColor, _ bottom: UIColor) {
        cg.saveGState()
        cg.addEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        cg.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(gradient, startCenter: CGPoint(x: cx - 10, y: cy - radius * 0.35), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: radius, options: [])
        cg.restoreGState()
    }

    private static func head(_ cg: CGContext, top: UIColor, bottom: UIColor) {
        shadow(cg, 128, 150, 90)
        fillRadial(cg, 128, 136, 96, top, bottom)
        UIColor.white.withAlphaComponent(0.32).setFill()
        cg.fillEllipse(in: CGRect(x: 78, y: 62, width: 72, height: 46))
    }

    private static func eye(_ cg: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        rgb(0.17, 0.14, 0.11).setFill()
        cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        UIColor.white.setFill()
        cg.fillEllipse(in: CGRect(x: x - r * 0.7, y: y - r * 0.75, width: r * 0.64, height: r * 0.64))
    }

    private static func eyes(_ cg: CGContext, _ y: CGFloat) { eye(cg, 96, y, 11); eye(cg, 160, y, 11) }

    private static func wink(_ cg: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        rgb(0.17, 0.14, 0.11).setStroke(); cg.setLineWidth(7); cg.setLineCap(.round)
        cg.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        cg.strokePath()
    }

    private static func joy(_ cg: CGContext, _ y: CGFloat) {
        rgb(0.17, 0.14, 0.11).setStroke(); cg.setLineWidth(7); cg.setLineCap(.round)
        cg.addArc(center: CGPoint(x: 96, y: y + 6), radius: 16, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        cg.strokePath()
        cg.addArc(center: CGPoint(x: 160, y: y + 6), radius: 16, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        cg.strokePath()
    }

    private static func brow(_ cg: CGContext, _ x: CGFloat, _ y: CGFloat, raised: Bool) {
        rgb(0.17, 0.14, 0.11).setStroke(); cg.setLineWidth(7); cg.setLineCap(.round)
        let tilt: CGFloat = raised ? -10 : 10
        cg.move(to: CGPoint(x: x - 16, y: y + tilt)); cg.addLine(to: CGPoint(x: x + 16, y: y - tilt)); cg.strokePath()
    }

    private static func blush(_ cg: CGContext) {
        UIColor(red: 1, green: 0.35, blue: 0.43, alpha: 0.32).setFill()
        cg.fillEllipse(in: CGRect(x: 60, y: 136, width: 28, height: 28))
        cg.fillEllipse(in: CGRect(x: 168, y: 136, width: 28, height: 28))
    }

    private static func mouth(_ cg: CGContext, _ y: CGFloat, _ half: CGFloat) {
        rgb(0.35, 0.20, 0.09).setStroke(); cg.setLineWidth(8); cg.setLineCap(.round)
        cg.addArc(center: CGPoint(x: 128, y: y), radius: half, startAngle: 0.25, endAngle: .pi - 0.25, clockwise: false)
        cg.strokePath()
    }

    private static func openMouth(_ cg: CGContext, _ y: CGFloat, _ rx: CGFloat, tongue: Bool) {
        rgb(0.23, 0.14, 0.08).setFill()
        fill(cg, UIBezierPath(roundedRect: CGRect(x: 128 - rx, y: y - 16, width: rx * 2, height: 38), cornerRadius: 16))
        UIColor.white.setFill()
        fill(cg, UIBezierPath(roundedRect: CGRect(x: 128 - rx + 6, y: y - 12, width: rx * 2 - 12, height: 11), cornerRadius: 6))
        if tongue {
            rgb(1, 0.42, 0.51).setFill()
            cg.fillEllipse(in: CGRect(x: 116, y: y + 2, width: 24, height: 16))
        }
    }

    private static func heart(_ cg: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat, _ top: UIColor, _ bottom: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: cx, y: cy + s * 0.85))
        path.addCurve(to: CGPoint(x: cx, y: cy - s * 0.25), controlPoint1: CGPoint(x: cx - s * 1.15, y: cy + s * 0.15), controlPoint2: CGPoint(x: cx - s * 1.05, y: cy - s * 0.95))
        path.addCurve(to: CGPoint(x: cx, y: cy + s * 0.85), controlPoint1: CGPoint(x: cx + s * 1.05, y: cy - s * 0.95), controlPoint2: CGPoint(x: cx + s * 1.15, y: cy + s * 0.15))
        path.close()
        cg.saveGState()
        path.addClip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(gradient, startCenter: CGPoint(x: cx, y: cy - s * 0.2), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: s * 1.4, options: [])
        cg.restoreGState()
    }

    private static func starPath(_ cx: CGFloat, _ cy: CGFloat, _ outer: CGFloat, _ inner: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        for point in 0..<10 {
            let radius = point % 2 == 0 ? outer : inner
            let angle = (-90.0 + Double(point) * 36.0) * .pi / 180
            let x = cx + CGFloat(cos(angle) * radius)
            let y = cy + CGFloat(sin(angle) * radius)
            if point == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.close()
        return path
    }

    private static func flame(_ cg: CGContext) {
        shadow(cg, 128, 190, 60)
        let outer = UIBezierPath()
        outer.move(to: CGPoint(x: 128, y: 28))
        outer.addCurve(to: CGPoint(x: 196, y: 168), controlPoint1: CGPoint(x: 168, y: 78), controlPoint2: CGPoint(x: 214, y: 110))
        outer.addCurve(to: CGPoint(x: 128, y: 236), controlPoint1: CGPoint(x: 184, y: 214), controlPoint2: CGPoint(x: 150, y: 236))
        outer.addCurve(to: CGPoint(x: 60, y: 168), controlPoint1: CGPoint(x: 106, y: 236), controlPoint2: CGPoint(x: 72, y: 214))
        outer.addCurve(to: CGPoint(x: 128, y: 28), controlPoint1: CGPoint(x: 42, y: 110), controlPoint2: CGPoint(x: 88, y: 78))
        outer.close()
        cg.saveGState(); outer.addClip()
        let hot = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(1, 0.95, 0.69).cgColor, rgb(1, 0.42, 0).cgColor] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(hot, startCenter: CGPoint(x: 128, y: 180), startRadius: 0, endCenter: CGPoint(x: 128, y: 180), endRadius: 120, options: [])
        cg.restoreGState()
        let inner = UIBezierPath()
        inner.move(to: CGPoint(x: 128, y: 96))
        inner.addCurve(to: CGPoint(x: 156, y: 186), controlPoint1: CGPoint(x: 150, y: 128), controlPoint2: CGPoint(x: 168, y: 150))
        inner.addCurve(to: CGPoint(x: 128, y: 220), controlPoint1: CGPoint(x: 148, y: 210), controlPoint2: CGPoint(x: 136, y: 220))
        inner.addCurve(to: CGPoint(x: 100, y: 182), controlPoint1: CGPoint(x: 118, y: 220), controlPoint2: CGPoint(x: 104, y: 206))
        inner.addCurve(to: CGPoint(x: 128, y: 96), controlPoint1: CGPoint(x: 92, y: 148), controlPoint2: CGPoint(x: 108, y: 126))
        inner.close()
        cg.saveGState(); inner.addClip()
        let core = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor.white.cgColor, rgb(1, 0.76, 0.03).cgColor] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(core, startCenter: CGPoint(x: 128, y: 190), startRadius: 0, endCenter: CGPoint(x: 128, y: 190), endRadius: 70, options: [])
        cg.restoreGState()
    }

    private static func thumb(_ cg: CGContext) {
        shadow(cg, 128, 176, 70)
        let skin = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(1, 0.88, 0.72).cgColor, rgb(0.91, 0.63, 0.35).cgColor] as CFArray, locations: [0, 1])!
        cg.saveGState()
        UIBezierPath(roundedRect: CGRect(x: 78, y: 108, width: 110, height: 112), cornerRadius: 40).addClip()
        cg.drawRadialGradient(skin, startCenter: CGPoint(x: 120, y: 140), startRadius: 0, endCenter: CGPoint(x: 130, y: 170), endRadius: 110, options: [])
        cg.restoreGState()
        cg.saveGState()
        UIBezierPath(roundedRect: CGRect(x: 48, y: 78, width: 70, height: 90), cornerRadius: 36).addClip()
        cg.drawRadialGradient(skin, startCenter: CGPoint(x: 70, y: 100), startRadius: 0, endCenter: CGPoint(x: 80, y: 130), endRadius: 80, options: [])
        cg.restoreGState()
        UIColor.white.withAlphaComponent(0.28).setFill()
        fill(cg, UIBezierPath(roundedRect: CGRect(x: 96, y: 124, width: 54, height: 26), cornerRadius: 16))
    }

    private static func party(_ cg: CGContext) {
        head(cg, top: rgb(1, 0.88, 0.54), bottom: rgb(0.96, 0.65, 0.14))
        rgb(0.49, 0.30, 1).setFill()
        let hat = UIBezierPath()
        hat.move(to: CGPoint(x: 128, y: 28)); hat.addLine(to: CGPoint(x: 86, y: 118)); hat.addLine(to: CGPoint(x: 170, y: 118)); hat.close(); hat.fill()
        rgb(1, 0.84, 0.04).setFill(); cg.fillEllipse(in: CGRect(x: 116, y: 16, width: 24, height: 24))
        rgb(1, 0.30, 0.43).setFill(); cg.fillEllipse(in: CGRect(x: 102, y: 72, width: 12, height: 12))
        rgb(0.24, 0.86, 0.59).setFill(); cg.fillEllipse(in: CGRect(x: 141, y: 65, width: 10, height: 10))
        joy(cg, 132); openMouth(cg, 168, 26, tongue: false)
        rgb(0.23, 0.51, 0.96).setFill(); cg.fillEllipse(in: CGRect(x: 33, y: 57, width: 14, height: 14))
        rgb(1, 0.30, 0.43).setFill(); cg.fillEllipse(in: CGRect(x: 208, y: 74, width: 12, height: 12))
        rgb(0.24, 0.86, 0.59).setFill(); cg.fillEllipse(in: CGRect(x: 201, y: 163, width: 10, height: 10))
    }

    private static func sparkles(_ cg: CGContext) {
        spark(cg, 128, 118, 78, rgb(1, 0.84, 0.04))
        spark(cg, 58, 70, 28, rgb(0.49, 0.30, 1))
        spark(cg, 196, 64, 24, rgb(0.23, 0.51, 0.96))
        spark(cg, 188, 176, 22, rgb(1, 0.30, 0.43))
        spark(cg, 64, 176, 18, rgb(0.24, 0.86, 0.59))
    }

    private static func spark(_ cg: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addLine(to: CGPoint(x: cx + r * 0.18, y: cy - r * 0.18))
        path.addLine(to: CGPoint(x: cx + r, y: cy))
        path.addLine(to: CGPoint(x: cx + r * 0.18, y: cy + r * 0.18))
        path.addLine(to: CGPoint(x: cx, y: cy + r))
        path.addLine(to: CGPoint(x: cx - r * 0.18, y: cy + r * 0.18))
        path.addLine(to: CGPoint(x: cx - r, y: cy))
        path.addLine(to: CGPoint(x: cx - r * 0.18, y: cy - r * 0.18))
        path.close()
        color.setFill(); path.fill()
        UIColor.white.withAlphaComponent(0.7).setFill()
        cg.fillEllipse(in: CGRect(x: cx - r * 0.22, y: cy - r * 0.28, width: r * 0.24, height: r * 0.24))
    }

    static func shareCard(bundle: String, status: String, avatarJpeg: Data?, bootstrap: String) -> String {
        let tiny = qrAvatar(avatarJpeg)
        let withPhoto = ProfileCards.encode(bundle: bundle, status: status, avatarJpeg: tiny, bootstrap: bootstrap)
        if tiny != nil, qrImage(withPhoto) == nil {
            return ProfileCards.encode(bundle: bundle, status: status, avatarJpeg: nil, bootstrap: bootstrap)
        }
        return withPhoto
    }

    /// Words a person can read. The signed bundle stays inside the QR image.
    static func profileShareCaption(name: String, status: String, directId: String, server: String) -> String {
        var lines = [name]
        let about = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty { lines.append(about) }
        lines.append("DIRECT ID: \(directId)")
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(address.isEmpty ? "Server: not set" : "Server: \(address)")
        lines.append(address.isEmpty
            ? "Set a server under Network before sharing. The other phone needs it to connect."
            : "Scan the QR code in DIRECT. Both phones use this server to connect.")
        return lines.joined(separator: "\n")
    }

    /// A picture of the QR code with the name, status, DIRECT ID, and server address written beside it.
    static func profileCardImage(name: String, status: String, directId: String, server: String, qrText: String) -> UIImage? {
        guard let qr = qrImage(qrText) else { return nil }
        let width: CGFloat = 900
        let margin: CGFloat = 64
        let contentWidth = width - margin * 2
        let nameFont = UIFont.systemFont(ofSize: 44, weight: .bold)
        let statusFont = UIFont.systemFont(ofSize: 28, weight: .regular)
        let labelFont = UIFont.systemFont(ofSize: 18, weight: .semibold)
        let idFont = UIFont.monospacedSystemFont(ofSize: 22, weight: .regular)
        let footerFont = UIFont.systemFont(ofSize: 22, weight: .regular)
        let about = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverText = address.isEmpty ? "Not set" : address
        let footer = address.isEmpty
            ? "Set a server under Network before sharing. The other phone needs it to connect."
            : "Scan this code in DIRECT. Both phones use this server to connect."

        func blockHeight(_ text: String, font: UIFont) -> CGFloat {
            ceil((text as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: 800),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).height)
        }

        let nameHeight = blockHeight(name, font: nameFont)
        let statusHeight = about.isEmpty ? 0 : blockHeight(about, font: statusFont)
        let idHeight = blockHeight(directId, font: idFont)
        let serverHeight = blockHeight(serverText, font: idFont)
        let footerHeight = blockHeight(footer, font: footerFont)
        let qrSize: CGFloat = 620
        var canvasHeight = margin + nameHeight + 16
        if !about.isEmpty { canvasHeight += statusHeight + 20 }
        canvasHeight += 28 + 8 + idHeight + 20 + 28 + 8 + serverHeight + 36 + qrSize + 28 + footerHeight + margin

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: canvasHeight), format: format)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: canvasHeight))
            var y = margin
            func draw(_ text: String, font: UIFont, color: UIColor, box: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
                (text as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: box), withAttributes: attributes)
            }
            draw(name, font: nameFont, color: .black, box: nameHeight)
            y += nameHeight + 16
            if !about.isEmpty {
                draw(about, font: statusFont, color: UIColor(white: 0.35, alpha: 1), box: statusHeight)
                y += statusHeight + 20
            }
            draw("DIRECT ID", font: labelFont, color: UIColor(white: 0.45, alpha: 1), box: 28)
            y += 28 + 8
            draw(directId, font: idFont, color: .black, box: idHeight)
            y += idHeight + 20
            draw("Server", font: labelFont, color: UIColor(white: 0.45, alpha: 1), box: 28)
            y += 28 + 8
            draw(serverText, font: idFont, color: address.isEmpty ? UIColor(white: 0.45, alpha: 1) : .black, box: serverHeight)
            y += serverHeight + 36
            qr.draw(in: CGRect(x: (width - qrSize) / 2, y: y, width: qrSize, height: qrSize))
            y += qrSize + 28
            draw(footer, font: footerFont, color: UIColor(white: 0.35, alpha: 1), box: footerHeight)
        }
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rect = scaled.extent.integral
        guard !rect.isInfinite, rect.width > 1, rect.height > 1 else { return nil }
        // A UIImage that only wraps a CIImage draws blank in SwiftUI.
        let context = CIContext()
        guard let rendered = context.createCGImage(scaled, from: rect) else { return nil }
        return UIImage(cgImage: rendered)
    }

    private static func isGif(_ data: Data) -> Bool {
        data.starts(with: Data("GIF8".utf8))
    }

    private static func compress(_ data: Data, maxEdge: CGFloat, maxBytes: Int, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let size = CGSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
        let renderer = UIGraphicsImageRenderer(size: size)
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        var q = quality
        var out = drawn.jpegData(compressionQuality: q) ?? Data()
        while out.count > maxBytes, q > 0.3 {
            q -= 0.1
            out = drawn.jpegData(compressionQuality: q) ?? out
        }
        return out.isEmpty ? nil : out
    }
}

struct VideoBytes: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        // `contentType` binds the first closure to export. Import has to be named,
        // and `Data(contentsOf:)` without options is async on newer SDKs.
        FileRepresentation(contentType: .movie) { item in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-video-\(UUID().uuidString).mp4")
            try item.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        } importing: { received in
            let bytes = try Data(contentsOf: received.file, options: [])
            return VideoBytes(data: bytes)
        }
    }
}

struct PrepError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct QrScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            (view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer })?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async {
                if !session.isRunning { session.startRunning() }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async {
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let text = object.stringValue else { return }
            delivered = true
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
            onCode?(text)
        }
    }
}

final class VoiceCapture: NSObject, ObservableObject {
    @Published var recording = false
    @Published var levels: [CGFloat] = []
    @Published var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var meter: Timer?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ])
        recorder.isMeteringEnabled = true
        self.recorder = recorder
        file = url
        DispatchQueue.global(qos: .userInitiated).async {
            try? session.setActive(true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                recorder.record()
                self.levels = []
                self.elapsed = 0
                self.recording = true
                self.meter?.invalidate()
                self.meter = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    self?.sampleLevel()
                }
            }
        }
    }

    private func sampleLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        let amplitude = min(1, max(0, pow(10, decibels / 20) * 5))
        var next = levels
        next.append(CGFloat(amplitude))
        if next.count > 36 { next.removeFirst(next.count - 36) }
        levels = next
        elapsed = recorder.currentTime
    }

    func stop() throws -> Data {
        finishMeter()
        recorder?.stop()
        recorder = nil
        recording = false
        guard let file, let data = try? Data(contentsOf: file), !data.isEmpty else {
            throw PrepError("That recording is empty.")
        }
        try? FileManager.default.removeItem(at: file)
        self.file = nil
        guard data.count <= MediaPrep.maxBytes else { throw PrepError("That voice message is over 6 MB.") }
        return data
    }

    func cancel() {
        finishMeter()
        recorder?.stop()
        recorder = nil
        recording = false
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    private func finishMeter() {
        meter?.invalidate()
        meter = nil
    }
}

struct AttachmentBar: View {
    @Binding var expanded: Bool
    let onPhoto: (Data) -> Void
    let onVideo: (Data) -> Void
    let onGif: (Data) -> Void
    let onSticker: (Data) -> Void
    let onVoice: (Data) -> Void
    let onError: (String) -> Void

    @StateObject private var voice = VoiceCapture()
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var gifItem: PhotosPickerItem?
    @State private var stickers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voice.recording {
                recordingRow
            } else if expanded {
                attachmentChoices
            }
        }
        .padding(.bottom, voice.recording || expanded ? 10 : 0)
        .onChange(of: expanded) { shown in
            if !shown { stickers = false }
        }
        .onChange(of: photoItem) { item in Task { await load(item, gifOnly: false) } }
        .onChange(of: gifItem) { item in Task { await load(item, gifOnly: true) } }
        .onChange(of: videoItem) { item in
            Task {
                guard let item else { return }
                let bytes: Data?
                if let file = try? await item.loadTransferable(type: VideoBytes.self) {
                    bytes = file.data
                } else {
                    bytes = try? await item.loadTransferable(type: Data.self)
                }
                guard let bytes else { onError("That video could not be read."); return }
                do { onVideo(try MediaPrep.video(bytes, mime: "video/mp4").bytes) } catch { onError((error as? PrepError)?.message ?? "That video was not sent.") }
            }
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 10) {
            Button { voice.cancel() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.danger)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(ComposerPressStyle())
            VoiceWave(levels: voice.levels, progress: 1, played: Ink.success, idle: Ink.success.opacity(0.35))
                .frame(maxWidth: .infinity)
            Text(voiceClock(voice.elapsed))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Ink.text)
                .frame(width: 40, alignment: .trailing)
            Button {
                do { onVoice(try voice.stop()) } catch { onError((error as? PrepError)?.message ?? "That recording was not sent.") }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(Ink.accent, in: Circle())
            }
            .buttonStyle(ComposerPressStyle())
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private var attachmentChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if stickers {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<MediaPrep.stickerCount, id: \.self) { index in
                            let data = MediaPrep.sticker(index)
                            if let image = UIImage(data: data) {
                                Button {
                                    stickers = false
                                    onSticker(data)
                                } label: {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 72, height: 72)
                                }
                                .buttonStyle(ComposerPressStyle())
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
            }
            HStack(spacing: 4) {
                PhotosPicker(selection: $photoItem, matching: .images) { chip("Photo", "photo") }
                    .frame(maxWidth: .infinity)
                PhotosPicker(selection: $videoItem, matching: .videos) { chip("Video", "video.fill") }
                    .frame(maxWidth: .infinity)
                PhotosPicker(selection: $gifItem, matching: .images) { chip("GIF", "sparkles") }
                    .frame(maxWidth: .infinity)
                Button { stickers.toggle() } label: { chip("Sticker", "face.smiling", selected: stickers) }
                    .buttonStyle(ComposerPressStyle())
                    .frame(maxWidth: .infinity)
                Button {
                    AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                        DispatchQueue.main.async {
                            guard allowed else { onError("Microphone permission is needed for a voice message."); return }
                            do { try voice.start() } catch { onError("Recording could not start.") }
                        }
                    }
                } label: { chip("Voice", "mic.fill") }
                .buttonStyle(ComposerPressStyle())
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func chip(_ title: String, _ icon: String, selected: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Ink.accent)
                .frame(width: 44, height: 36)
                .background(selected ? Ink.accent : Ink.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Ink.text : Ink.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func load(_ item: PhotosPickerItem?, gifOnly: Bool) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let gif = item.supportedContentTypes.contains(.gif) || data.starts(with: Data("GIF8".utf8))
        if gifOnly && !gif {
            onError("Choose a GIF.")
            return
        }
        if gif {
            guard data.count <= MediaPrep.maxBytes else { onError("That GIF is over 6 MB. Choose a shorter one."); return }
            onGif(data)
            return
        }
        do { onPhoto(try MediaPrep.photo(data).bytes) } catch { onError((error as? PrepError)?.message ?? "That photo was not sent.") }
    }
}

struct MediaBubble: View {
    let message: MessageRecord
    var tail: Bool
    var showReceipt: Bool
    @EnvironmentObject private var model: AppModel
    @State private var bytes: Data?
    @State private var videoOpen = false
    @State private var settled: Bool

    init(message: MessageRecord, tail: Bool = true, showReceipt: Bool = false) {
        self.message = message
        self.tail = tail
        self.showReceipt = showReceipt
        let age = Date().timeIntervalSince1970 * 1000 - Double(message.createdAt)
        let justSent = message.direction == .outgoing && age > -2_000 && age < 1_500
        _bytes = State(initialValue: nil)
        _videoOpen = State(initialValue: false)
        _settled = State(initialValue: !justSent)
    }

    var body: some View {
        let outgoing = message.direction == .outgoing
        HStack(alignment: .bottom, spacing: 0) {
            if outgoing { Spacer(minLength: 64) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
                content(outgoing: outgoing)
                if showReceipt, !receipt.isEmpty {
                    Button {
                        if message.state == .failed { model.retry(message.id) }
                    } label: {
                        Text(receipt)
                            .font(.caption2)
                            .foregroundStyle(message.state == .failed ? Ink.danger : Ink.muted)
                    }
                    .buttonStyle(.plain)
                    .disabled(message.state != .failed)
                }
                if let error = message.lastError, message.state == .queued || message.state == .failed {
                    Text(error).font(.caption2).foregroundStyle(Ink.danger)
                }
            }
            if !outgoing { Spacer(minLength: 64) }
        }
        .scaleEffect(settled ? 1 : 0.45, anchor: outgoing ? .bottomTrailing : .bottomLeading)
        .offset(y: settled ? 0 : 22)
        .onAppear {
            model.loadMedia(message.id) { bytes = $0 }
            guard !settled else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) {
                settled = true
            }
        }
        .onChange(of: message.mediaFile) { _ in model.loadMedia(message.id) { bytes = $0 } }
        .sheet(isPresented: $videoOpen) {
            if let bytes {
                PlayerSheet(data: bytes, mime: message.mediaMime ?? "video/mp4", name: "video.mp4")
            }
        }
    }

    private var receipt: String {
        switch message.state {
        case .queued, .sending: return "Sending"
        case .sent: return "Sent"
        case .accepted: return "Delivered"
        case .acknowledged: return "Read"
        case .failed: return "Not Delivered"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func content(outgoing: Bool) -> some View {
        let kind = message.mediaKind
        let label = MediaNotes.label(kind)
        let fill = outgoing ? Ink.accent : Ink.incoming
        let shape = messageBubble(outgoing, tail: tail)
        if let bytes, let image = UIImage(data: bytes), let kind, ["image", "sticker", "gif"].contains(kind) {
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
                let caption = !message.body.isEmpty && message.body != label
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(messageBubble(outgoing, tail: caption ? false : tail))
                if !message.body.isEmpty, message.body != label {
                    textBubble(message.body, outgoing: outgoing, fill: fill)
                }
            }
        } else if kind == "audio" {
            if let bytes {
                VoiceNoteBubble(data: bytes, outgoing: outgoing, tail: tail)
            } else if !message.body.isEmpty {
                textBubble(message.body, outgoing: outgoing, fill: fill)
            }
        } else if kind == "video" {
            Button { videoOpen = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Video")
                        .font(.system(size: 17))
                }
                .foregroundStyle(outgoing ? Color.white : Ink.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(fill, in: shape)
            }
            .buttonStyle(.plain)
            .disabled(bytes == nil)
        } else if !message.body.isEmpty {
            textBubble(message.body, outgoing: outgoing, fill: fill)
        }
    }

    private func textBubble(_ text: String, outgoing: Bool, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 17))
            .foregroundStyle(outgoing ? Color.white : Ink.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(fill, in: messageBubble(outgoing, tail: tail))
    }
}

struct VoiceWave: View {
    let levels: [CGFloat]
    var progress: Double = 1
    var played: Color
    var idle: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars.count, id: \.self) { index in
                let reached = bars.count <= 1 || Double(index) / Double(bars.count - 1) <= progress
                Capsule()
                    .fill(reached ? played : idle)
                    .frame(width: 3, height: max(4, 26 * bars[index]))
            }
        }
        .frame(height: 28)
    }

    private var bars: [CGFloat] {
        if levels.isEmpty { return Array(repeating: 0.2, count: 18) }
        return levels
    }
}

struct VoiceNoteBubble: View {
    let data: Data
    let outgoing: Bool
    let tail: Bool
    @StateObject private var playback = VoicePlayback()
    @State private var peaks: [CGFloat] = []

    var body: some View {
        HStack(spacing: 8) {
            Button { playback.toggle(data) } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(outgoing ? Ink.accent : Color.white)
                    .frame(width: 32, height: 32)
                    .background(outgoing ? Color.white : Ink.success, in: Circle())
            }
            .buttonStyle(ComposerPressStyle())
            VoiceWave(
                levels: peaks,
                progress: playback.playing || playback.progress > 0 ? playback.progress : 0,
                played: outgoing ? Color.white : Ink.success,
                idle: (outgoing ? Color.white : Ink.text).opacity(0.35)
            )
            Text(voiceClock(playback.current > 0 ? playback.current : playback.duration))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(outgoing ? Color.white.opacity(0.9) : Ink.muted)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(outgoing ? Ink.accent : Ink.incoming, in: messageBubble(outgoing, tail: tail))
        .task(id: data.count) {
            let samples = await Task.detached(priority: .userInitiated) { voicePeaks(data) }.value
            peaks = samples
            playback.prepare(data)
        }
        .onDisappear { playback.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .directVoiceStarted)) { note in
            if note.object as? UUID != playback.id { playback.pause() }
        }
    }
}

extension Notification.Name {
    static let directVoiceStarted = Notification.Name("direct.voice.started")
}

final class VoicePlayback: ObservableObject {
    let id = UUID()
    @Published var playing = false
    @Published var progress: Double = 0
    @Published var duration: TimeInterval = 0
    @Published var current: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func prepare(_ data: Data) {
        guard player == nil else { return }
        player = try? AVAudioPlayer(data: data)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
    }

    func toggle(_ data: Data) {
        prepare(data)
        guard let player else { return }
        if playing {
            pause()
            return
        }
        NotificationCenter.default.post(name: .directVoiceStarted, object: id)
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            DispatchQueue.main.async { [weak self] in
                guard let self, let player = self.player else { return }
                player.play()
                self.playing = true
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self, let player = self.player else { return }
                    self.current = player.currentTime
                    self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                    if !player.isPlaying {
                        self.playing = false
                        self.progress = 0
                        self.current = 0
                        self.timer?.invalidate()
                    }
                }
            }
        }
    }

    func pause() {
        player?.pause()
        playing = false
        timer?.invalidate()
    }

    func stop() {
        timer?.invalidate()
        player?.stop()
        playing = false
    }
}

func voiceClock(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

func voicePeaks(_ data: Data, bars: Int = 28) -> [CGFloat] {
    let quiet = Array(repeating: CGFloat(0.25), count: bars)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-wave-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    guard (try? data.write(to: url, options: .atomic)) != nil,
          let file = try? AVAudioFile(forReading: url),
          file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return quiet }
    let total = Int(file.length)
    var peaks = Array(repeating: Float(0), count: bars)
    var frame = 0
    while frame < total {
        buffer.frameLength = 0
        guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
        let count = Int(buffer.frameLength)
        for index in 0..<count {
            let bin = min(bars - 1, (frame + index) * bars / max(total, 1))
            peaks[bin] = max(peaks[bin], abs(channel[index]))
        }
        frame += count
    }
    let loudest = peaks.max() ?? 0
    guard loudest > 0.001 else { return quiet }
    return peaks.map { CGFloat(max(0.12, min(1, $0 / loudest))) }
}

struct ComposerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct PlayerSheet: View {
    let data: Data
    let mime: String
    let name: String
    @State private var player: AVPlayer?

    var body: some View {
        VStack {
            if let player {
                VideoPlayer(player: player).frame(maxHeight: 320)
            } else {
                ProgressView()
            }
        }
        .padding()
        .background(Ink.background.ignoresSafeArea())
        .onAppear {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url)
            let next = AVPlayer(url: url)
            player = next
            next.play()
        }
    }
}
