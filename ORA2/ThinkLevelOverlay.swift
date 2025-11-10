import SwiftUI

struct ThinkLevelOverlay: View {
    @Binding var thinkLevel: ThinkLevel
    @Binding var useWebSearch: Bool
    @Binding var isPresented: Bool
    @State private var sliderValue: Double = 0.5

    var body: some View {
        if isPresented {
            panel.transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            HStack {
                Label("思考レベル & Web検索", systemImage: "brain")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { withAnimation(.spring) { isPresented = false } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            Slider(value: $sliderValue, in: 0...1)
                .onAppear {
                    sliderValue = (thinkLevel == .low ? 0.15 : thinkLevel == .med ? 0.5 : 0.85)
                }
                .onChange(of: sliderValue) { _, v in
                    let new: ThinkLevel = v < 0.34 ? .low : (v < 0.67 ? .med : .high)
                    if thinkLevel != new { thinkLevel = new }
                }

            Toggle(isOn: $useWebSearch) {
                Label("Web検索（MCP）", systemImage: "globe")
            }
            .tint(.accentColor)
        }
        .padding(14)
        .background {
            let r = RoundedRectangle(cornerRadius: 18, style: .continuous)
            // 共通ラッパー（LiquidSurface.swift の oraLiquid）を使用
            r.fill(.clear).oraLiquid(in: r)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
    }
}
