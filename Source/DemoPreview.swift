import AppKit

enum DemoPreview {
    static func save(to url: URL, scenario: DemoScenario, summary: [String]) throws {
        let image = NSImage(size: NSSize(width: 960, height: 640), flipped: false) { _ in
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.14, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 960, height: 640).fill()
            func line(_ text: String, y: CGFloat, size: CGFloat, color: NSColor = .white) {
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
                    .draw(in: NSRect(x: 48, y: y, width: 864, height: 45))
            }
            line("演示模式｜虚构示例", y: 550, size: 32, color: .systemOrange)
            line("Codex 电量管家 · \(scenario.title)", y: 495, size: 23)
            let percent = scenario == .unknown || scenario == .offline ? nil : 24
            BatteryIcon.image(percent: percent, dark: true).draw(in: NSRect(x: 48, y: 420, width: 141, height: 66))
            var y: CGFloat = 360
            for text in summary.filter({ !$0.isEmpty && !$0.contains("演示模式") }).prefix(7) {
                line(String(text.prefix(45)), y: y, size: 19)
                y -= 39
            }
            line("应用自身导出的示意图 · 非真实公告 / 非真实账号读数", y: 36, size: 17, color: .lightGray)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}
