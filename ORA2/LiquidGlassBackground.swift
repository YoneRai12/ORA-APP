import SwiftUI

struct LiquidGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.25), location: 0.0),
                        .init(color: .white.opacity(0.06), location: 0.5),
                        .init(color: .black.opacity(0.18), location: 1.0)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                NoiseView(opacity: 0.06).blendMode(.overlay)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct NoiseView: View {
    let opacity: CGFloat
    var body: some View {
        Canvas { ctx, size in
            let count = Int((size.width * size.height) / 1200) // 密度をデバイスサイズに追随
            for _ in 0..<max(count, 60) {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let r = CGFloat.random(in: 0.6...1.4)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(opacity)))
            }
        }
        .allowsHitTesting(false)
    }
}
