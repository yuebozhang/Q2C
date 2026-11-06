import AppKit

/// Original geometric northeast arrow; no font glyphs or third-party icon assets.
@MainActor
enum Q2CIcon {
    private static func arrow(in rect: NSRect) -> NSBezierPath {
        let points: [(CGFloat, CGFloat)] = [
            (0.22, 0.30), (0.60, 0.68), (0.36, 0.68), (0.36, 0.80),
            (0.80, 0.80), (0.80, 0.36), (0.68, 0.36), (0.68, 0.60), (0.30, 0.22)
        ]
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let p = NSPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
            if index == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.black.setFill()
            arrow(in: rect).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Q2C"
        return image
    }

    static func applicationImage(size: Int = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let tile = rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.07)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: tile, xRadius: rect.width * 0.19, yRadius: rect.height * 0.19).fill()
            NSColor.white.setFill()
            arrow(in: rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)).fill()
            return true
        }
    }
}
