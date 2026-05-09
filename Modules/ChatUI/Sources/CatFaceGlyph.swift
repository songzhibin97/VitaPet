import SwiftUI

/// SwiftUI rendering of the same cat-face glyph used by the .icns app icon and
/// the menu bar. Geometry mirrors `scripts/generate_icon.swift` /
/// `StatusBarController.menuBarImage(...)` so the three surfaces stay visually
/// identical. Stroke width is proportional to glyph width.
public struct CatFaceGlyph: View {
    public var color: Color
    public var lineWidthRatio: CGFloat

    public init(color: Color = .primary, lineWidthRatio: CGFloat = 0.105) {
        self.color = color
        self.lineWidthRatio = lineWidthRatio
    }

    public var body: some View {
        Canvas { context, size in
            let gw = size.width
            let gh = size.height
            let strokeWidth = gw * lineWidthRatio

            let cx = gw * 0.50
            let fr = gw * 0.40
            let fcyAppKit = gh * 0.40

            var head = Path()
            head.move(to: CGPoint(x: cx, y: fcyAppKit - fr))
            head.addCurve(
                to: CGPoint(x: cx + fr, y: fcyAppKit),
                control1: CGPoint(x: cx + fr * 0.552, y: fcyAppKit - fr),
                control2: CGPoint(x: cx + fr, y: fcyAppKit - fr * 0.552)
            )
            head.addCurve(
                to: CGPoint(x: cx + fr * 0.70, y: fcyAppKit + fr * 0.70),
                control1: CGPoint(x: cx + fr, y: fcyAppKit + fr * 0.35),
                control2: CGPoint(x: cx + fr * 0.88, y: fcyAppKit + fr * 0.58)
            )
            head.addCurve(
                to: CGPoint(x: cx + fr * 0.22, y: fcyAppKit + fr * 0.88),
                control1: CGPoint(x: cx + fr * 0.72, y: fcyAppKit + fr * 1.22),
                control2: CGPoint(x: cx + fr * 0.20, y: fcyAppKit + fr * 1.22)
            )
            head.addCurve(
                to: CGPoint(x: cx - fr * 0.22, y: fcyAppKit + fr * 0.88),
                control1: CGPoint(x: cx + fr * 0.10, y: fcyAppKit + fr * 0.72),
                control2: CGPoint(x: cx - fr * 0.10, y: fcyAppKit + fr * 0.72)
            )
            head.addCurve(
                to: CGPoint(x: cx - fr * 0.70, y: fcyAppKit + fr * 0.70),
                control1: CGPoint(x: cx - fr * 0.20, y: fcyAppKit + fr * 1.22),
                control2: CGPoint(x: cx - fr * 0.72, y: fcyAppKit + fr * 1.22)
            )
            head.addCurve(
                to: CGPoint(x: cx - fr, y: fcyAppKit),
                control1: CGPoint(x: cx - fr * 0.88, y: fcyAppKit + fr * 0.58),
                control2: CGPoint(x: cx - fr, y: fcyAppKit + fr * 0.35)
            )
            head.addCurve(
                to: CGPoint(x: cx, y: fcyAppKit - fr),
                control1: CGPoint(x: cx - fr, y: fcyAppKit - fr * 0.552),
                control2: CGPoint(x: cx - fr * 0.552, y: fcyAppKit - fr)
            )
            head.closeSubpath()

            let eyeR = fr * 0.13
            let eyeY = fcyAppKit + fr * 0.12
            let eyeOX = fr * 0.38
            var features = Path()
            features.addEllipse(in: CGRect(
                x: cx - eyeOX - eyeR, y: eyeY - eyeR,
                width: eyeR * 2, height: eyeR * 2
            ))
            features.addEllipse(in: CGRect(
                x: cx + eyeOX - eyeR, y: eyeY - eyeR,
                width: eyeR * 2, height: eyeR * 2
            ))

            let noseY = fcyAppKit - fr * 0.10
            let ns = fr * 0.10
            features.move(to: CGPoint(x: cx - ns, y: noseY + ns * 0.65))
            features.addLine(to: CGPoint(x: cx + ns, y: noseY + ns * 0.65))
            features.addLine(to: CGPoint(x: cx, y: noseY - ns * 0.65))
            features.closeSubpath()

            // AppKit Y is bottom-up; SwiftUI Canvas Y is top-down. Flip vertically.
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: gh)
            head = head.applying(flip)
            features = features.applying(flip)

            let shading = GraphicsContext.Shading.color(color)
            context.stroke(
                head,
                with: shading,
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .miter)
            )
            context.fill(features, with: shading)
        }
    }
}
