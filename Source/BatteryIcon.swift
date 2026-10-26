import AppKit

enum BatteryIcon {
    static func image(percent: Int?, stale: Bool = false, dark: Bool = false, alert: Bool = false) -> NSImage {
        let size = NSSize(width: alert ? 62 : 47, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink: NSColor = dark ? .white : .black
            let body = NSRect(x: 1.5, y: 3.5, width: 39, height: 15)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.2, yRadius: 3.2)
            ink.withAlphaComponent(0.82).setStroke()
            outline.lineWidth = 1.3
            outline.stroke()
            ink.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: 42, y: 8, width: 2.5, height: 6), xRadius: 1, yRadius: 1).fill()
            if let percent, !stale {
                let inner = NSRect(x: 3.5, y: 5.5, width: 35, height: 11)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5).addClip()
                let fill: NSColor = percent <= 10 ? .systemRed : (percent <= 20 ? .systemOrange : ink)
                fill.withAlphaComponent(dark ? 0.33 : 0.19).setFill()
                NSRect(x: inner.minX, y: inner.minY, width: inner.width * CGFloat(max(0, min(100, percent))) / 100, height: inner.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let text = percent.map { stale ? "--" : "\($0)%" } ?? "--"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: text.count > 3 ? 10 : 10.5, weight: .semibold),
                .foregroundColor: ink
            ]
            let string = NSAttributedString(string: text, attributes: attrs)
            let measured = string.size()
            string.draw(at: NSPoint(x: body.midX - measured.width / 2, y: body.midY - measured.height / 2 + 0.2))
            if alert {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 48, y: 5, width: 12, height: 12)).fill()
                let mark = NSAttributedString(string: "!", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.white
                ])
                let markSize = mark.size()
                mark.draw(at: NSPoint(x: 54 - markSize.width / 2, y: 11 - markSize.height / 2 + 0.2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func savePreview(to url: URL) throws {
        let canvas = NSImage(size: NSSize(width: 500, height: 180), flipped: false) { _ in
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: 90, width: 500, height: 90).fill()
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 500, height: 90).fill()
            for (index, value) in [100, 67, 20, 5, -1].enumerated() {
                let x = CGFloat(index) * 94 + 24
                image(percent: value < 0 ? nil : value).draw(in: NSRect(x: x, y: 120, width: 70.5, height: 33))
                image(percent: value < 0 ? nil : value, dark: true).draw(in: NSRect(x: x, y: 30, width: 70.5, height: 33))
            }
            return true
        }
        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
