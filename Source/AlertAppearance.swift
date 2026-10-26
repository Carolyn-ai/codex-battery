import AppKit

enum AlertAppearance {
    static func title(countdown: String, alert: TiboAlert?, fallbackIndicator: String = "", imminent: Bool = false, dark: Bool? = nil, readIndicator: String = "") -> NSAttributedString {
        let baseColor: NSColor = dark.map { $0 ? .white : .black } ?? .labelColor
        let result = NSMutableAttributedString(string: countdown, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: imminent ? NSColor.systemOrange : baseColor
        ])
        if let alert {
            result.append(NSAttributedString(string: "  · \(alert.title)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.systemRed
            ]))
        } else if !fallbackIndicator.isEmpty {
            result.append(NSAttributedString(string: fallbackIndicator, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemOrange
            ]))
        } else if !readIndicator.isEmpty {
            result.append(NSAttributedString(string: readIndicator, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: dark.map { $0 ? NSColor.lightGray : NSColor.gray } ?? NSColor.secondaryLabelColor
            ]))
        }
        return result
    }

    /// A static UI example. It does not inject announcements into the running app.
    static func savePreview(to url: URL) throws {
        let now = Date()
        let samples: [(String, TiboAlertKind, Bool)] = [("Tibo有重置消息", .resetMessage, false), ("Tibo有重置消息", .resetMessage, true), ("Tibo 10/27 17:00前重置", .pendingReset, false)]
        let labels = ["新变化", "打开详情后自动已读", "之后补充了明确时间，再次提醒"]
        let canvas = NSImage(size: NSSize(width: 600, height: 291), flipped: false) { _ in
            for (index, sample) in samples.enumerated() {
                let dark = index == 1
                let origin = CGFloat(2 - index) * 97
                (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)).setFill()
                NSRect(x: 0, y: origin, width: 600, height: 97).fill()
                let label = NSAttributedString(string: "\(labels[index]) · 样式示意（非新公告）", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: dark ? NSColor.lightGray : NSColor.gray
                ])
                label.draw(at: NSPoint(x: 22, y: origin + 65))
                BatteryIcon.image(percent: 64, dark: dark, alert: !sample.2).draw(in: NSRect(x: 22, y: origin + 22, width: sample.2 ? 70.5 : 93, height: 33))
                let example = TiboAlert(id: "0000000000000000000", kind: sample.1, title: sample.0, sourceURL: URL(string: "https://x.com/thsottiaux")!, postedAt: now)
                let text = title(countdown: "↻ 6天14小时", alert: sample.2 ? nil : example, dark: dark, readIndicator: sample.2 ? "  · ✓ Tibo已读" : "")
                let transform = NSAffineTransform()
                transform.translateX(by: 123, yBy: origin + 30)
                transform.scale(by: 1.4)
                NSGraphicsContext.saveGraphicsState()
                transform.concat()
                text.draw(at: .zero)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
