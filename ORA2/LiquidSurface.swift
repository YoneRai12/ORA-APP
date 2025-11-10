import SwiftUI

public extension View {
    /// 角丸 shape に“擬似ガラス”背景を敷く（iOS16+ / SDK非依存）
    func oraLiquid<S: InsettableShape>(in shape: S,
                                       strokeOpacity: Double = 0.22) -> some View {
        modifier(_ORALiquid(shape: shape, strokeOpacity: strokeOpacity))
    }
}

private struct _ORALiquid<S: InsettableShape>: ViewModifier {
    let shape: S
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1) }
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(0.20), .clear, .white.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .clipShape(shape)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
            }
            .compositingGroup()
    }
}
