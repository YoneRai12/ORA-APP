// LiquidGlassBackground.swift (fallback)
import SwiftUI

#if false
struct LiquidGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .background(.ultraThinMaterial)
            .overlay(
                Rectangle().stroke(.white.opacity(0.18), lineWidth: 1)
            )
    }
}
#endif
