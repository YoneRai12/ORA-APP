//
//  ChatHomeMockView.swift
//  ORA2
//
//  NEO-FUTURE / HOLOGRAPHIC MINIMAL – SwiftUI Mock aligned to spec
//  Edited by SwiftUI Assistant on 2025/09/08
//

import SwiftUI

struct ChatHomeMockView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var appearAnim: Bool = false
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            // 背景：純色 (#FFFFFF / #000000)
            Tokens.background(colorScheme)
                .ignoresSafeArea()

            // 背景グリッド：8pt間隔、Opacity 2–3%、パララックス 0.5〜1.0pt（Reduce Motionで0）
            GridBackground(opacity: 0.02...0.03)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // TopBar（44pt）
                topBar
                    .padding(.horizontal, Tokens.spacingH)
                    .frame(height: 44)

                Spacer(minLength: 0)

                // ゼロ状態：ホログラムロゴ + ヒント
                zeroStateCenter
                    .padding(.horizontal, Tokens.spacingH)
                    .padding(.bottom, 12)
                    .opacity(0.9)

                // SmartChips（横スクロール・高さ72・最大3つ）
                chips
                    .padding(.horizontal, Tokens.spacingH)
                    .padding(.bottom, 8)
                    .modifier(AppearSlideFade(enabled: !reduceMotion, trigger: appearAnim, distance: 10, duration: 0.22, delay: 0.02))

                // InputBar（高さ56・角丸18）
                inputBar
                    .padding(.horizontal, Tokens.spacingH)
                    .padding(.bottom, max(Tokens.spacingH, safeBottomInset() == 0 ? Tokens.spacingH : safeBottomInset()))
                    .modifier(AppearSlideFade(enabled: !reduceMotion, trigger: appearAnim, distance: 10, duration: 0.22, delay: 0.06))
            }
        }
        .onAppear {
            guard !appearAnim else { return }
            if reduceMotion {
                appearAnim = true
            } else {
                withAnimation(.easeOut(duration: 0.22)) {
                    appearAnim = true
                }
            }
        }
    }

    // MARK: - Top Bar (44pt)

    private var topBar: some View {
        HStack(spacing: 0) {
            // 左：メニュー（line.3.horizontal）アイコン18 / ヒット44x44
            Button(action: {}) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.fgPrimary(colorScheme))
            }
            .accessibilityLabel("メニュー")

            Spacer(minLength: 0)

            // 中央：タイトル「FUTURE CHAT」Title3 +2%トラッキング
            Text("FUTURE CHAT")
                .font(.system(.title3, design: .default).weight(.semibold))
                .tracking(0.34) // 約+2%相当
                .foregroundStyle(Tokens.fgPrimary(colorScheme))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            // 右：ステータスバッジ（角丸8、1px点線）
            Button(action: {}) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Tokens.accentPrimary.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text("SYNCED")
                        .font(.caption2)
                        .foregroundStyle(Tokens.fgSecondary(colorScheme))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(height: 22)
                .background(
                    surfaceBackground(RoundedRectangle(cornerRadius: 8, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Tokens.strokeColor(colorScheme), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                )
            }
            .accessibilityLabel("ステータス: 同期済み")
        }
        .contentShape(Rectangle())
    }

    // MARK: - Zero State (center hint)

    private var zeroStateCenter: some View {
        VStack(spacing: 10) {
            // 細線ホログラムロゴ（直径96、線幅1pt、accentPrimary→accentSecondary、Opacity 12%）
            ZStack {
                Circle()
                    .strokeBorder(LinearGradient(
                        colors: [
                            Tokens.accentPrimary.opacity(0.35),
                            Tokens.accentSecondary.opacity(0.35)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Circle()
                            .strokeBorder(Tokens.innerHighlight(colorScheme), lineWidth: 1)
                            .blur(radius: 0.5)
                            .opacity(colorScheme == .dark ? 0.22 : 0.18)
                    )
                Circle()
                    .strokeBorder(Tokens.strokeColor(colorScheme), lineWidth: 1)
                    .frame(width: 72, height: 72)
                    .opacity(0.25)
            }
            .accessibilityHidden(true)

            Text("Enter を押すか / でコマンド")
                .font(.caption)
                .foregroundStyle(Tokens.fgSecondary(colorScheme))
        }
    }

    // MARK: - SmartChips（トラック高さ72 / チップ56）

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.spacingM) {
                suggestionChip(icon: "dollarsign.arrow.circlepath", title: "Monetize ideas", subtitle: "Find paths to revenue")
                suggestionChip(icon: "bolt.horizontal.circle", title: "Optimize in real time", subtitle: "Improve responses live")
                suggestionChip(icon: "text.justify.left", title: "Summarize", subtitle: "Condense long threads")
            }
            .frame(height: 72)
            .padding(.vertical, 8)
        }
        .accessibilityLabel("SmartChips")
    }

    private func suggestionChip(icon: String, title: String, subtitle: String) -> some View {
        let stroke = Tokens.strokeColor(colorScheme)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Tokens.fgPrimary(colorScheme))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.fgPrimary(colorScheme))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Tokens.fgSecondary(colorScheme))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 220, maxWidth: 320, minHeight: 56, alignment: .leading)
        .background(
            surfaceBackground(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            // 1px stroke（前景10–12%）+ inner stroke（光の縁）
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Tokens.innerHighlight(colorScheme), lineWidth: 1)
                        .blendMode(.screen)
                        .opacity(colorScheme == .dark ? 0.22 : 0.18)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)。\(subtitle)")
    }

    // MARK: - InputBar（高さ56 / 角丸18 / 左＋ 中央TextField 右Mic+Send）

    private var inputBar: some View {
        let stroke = Tokens.strokeColor(colorScheme)

        return HStack(spacing: 8) {
            // 左：＋（アイコン18、ヒット44x44）
            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.fgPrimary(colorScheme))
                    .background(
                        Circle()
                            .fill(Color.clear)
                            .background(
                                surfaceBackground(Circle())
                            )
                            .overlay(Circle().strokeBorder(stroke, lineWidth: 1))
                    )
            }
            .accessibilityLabel("追加")

            // 中央：TextField（placeholder「質問してみましょう」）最大4行 上揃え
            ZStack(alignment: .topLeading) {
                if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("質問してみましょう")
                        .font(.body)
                        .foregroundStyle(Tokens.fgSecondary(colorScheme))
                        .padding(.top, 10)
                        .padding(.leading, 4)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                TextField("", text: $inputText, axis: .vertical)
                    .font(.body)
                    .textInputAutocapitalization(.sentences)
                    .lineLimit(1...4)
                    .padding(.vertical, 10)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .focused($inputFocused)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            // 右：入力が空なら Mic、入力ありなら Send を表示
            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: {}) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(Tokens.fgPrimary(colorScheme))
                }
                .accessibilityLabel("マイク")
                .transition(.opacity .combined(with: .scale))
            } else {
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Tokens.accentPrimary.gradient)
                        )
                        .shadow(color: Tokens.accentPrimary.opacity(0.35), radius: 8, x: 0, y: 0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("送信")
                .transition(.opacity .combined(with: .scale))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 56, alignment: .center)
        .background(
            surfaceBackground(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Tokens.innerHighlight(colorScheme), lineWidth: 1)
                        .blendMode(.screen)
                        .opacity(colorScheme == .dark ? 0.22 : 0.18)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("メッセージ入力")
    }

    private func send() {
        // 送信：Send scale 0.92→1.0（120ms spring 280/22）
        if !reduceMotion {
            let spring = Animation.spring(response: 0.28, dampingFraction: 0.22, blendDuration: 0)
            withAnimation(spring) {}
        }
        // 入力クリア
        inputText = ""
        // キーボードを閉じる
        inputFocused = false
        dismissKeyboard()
    }

    // MARK: - Safe area helper

    private func safeBottomInset() -> CGFloat {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.compactMap { $0 as? UIWindowScene }.first
        let keyWindow = windowScene?.windows.first { $0.isKeyWindow }
        return keyWindow?.safeAreaInsets.bottom ?? 0
        #else
        return 0
        #endif
    }

    // Reduce Transparency 対応の角丸面（Material or Solid）を適用するユーティリティ（iOS 16 互換）
    private func surfaceBackground<S: InsettableShape>(_ shape: S) -> some View {
        Group {
            if reduceTransparency {
                shape.fill(Tokens.solidSurfaceColor(colorScheme))
            } else {
                shape.fill(Color.clear)
                    .background(.ultraThinMaterial, in: shape)
            }
        }
    }

    // キーボードを閉じる（UIKit 経由）
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

// MARK: - Tokens

private enum Tokens {
    // Spacing
    static let spacingH: CGFloat = 16
    static let spacingM: CGFloat = 12

    // 背景（純色）
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black : Color.white
    }

    // 前景
    static func fgPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color(red: 0.067, green: 0.067, blue: 0.067) // #111111
    }

    static func fgSecondary(_ scheme: ColorScheme) -> Color {
        fgPrimary(scheme).opacity(0.7)
    }

    // 1px stroke（前景10–12%）
    static func strokeColor(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? Color.white : Color.black).opacity(scheme == .dark ? 0.12 : 0.10)
    }

    // inner stroke（光の縁）
    static func innerHighlight(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? Color.white : Color.white)
            .opacity(scheme == .dark ? 0.22 : 0.18)
    }

    // Reduce Transparency時のソリッド面（Color を返す：iOS 16 互換）
    static func solidSurfaceColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark
        ? Color(red: 0.11, green: 0.11, blue: 0.118) // #1C1C1E
        : Color(red: 0.949, green: 0.949, blue: 0.969) // #F2F2F7
    }

    // アクセント（ネオン）
    static let accentPrimary = Color(red: 0.086, green: 0.949, blue: 0.843) // #16F2D7
    static let accentSecondary = Color(red: 0.478, green: 0.549, blue: 1.0)  // #7A8CFF
}

// MARK: - Grid Background（8pt / 0.5pt線 / 2–3%）

private struct GridBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let opacity: ClosedRange<Double>
    private let spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let base = (scheme == .dark ? Color.white : Color.black)
                let color = base.opacity(opacity.lowerBound)
                var path = Path()

                // パララックス（Reduce Motionで0）
                let offset: CGFloat = reduceMotion ? 0 : 0.6

                // 縦線
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x + offset, y: 0))
                    path.addLine(to: CGPoint(x: x + offset, y: size.height))
                    x += spacing
                }

                // 横線
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y + offset))
                    path.addLine(to: CGPoint(x: size.width, y: y + offset))
                    y += spacing
                }

                ctx.stroke(path, with: .color(color), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Appear Motion（y=10→0 / 200–240ms easeOut）

private struct AppearSlideFade: ViewModifier {
    let enabled: Bool
    let trigger: Bool
    var distance: CGFloat = 10
    var duration: Double = 0.22
    var delay: Double = 0

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(y: trigger ? 0 : distance)
                .opacity(trigger ? 1 : 0)
                .animation(.easeOut(duration: duration).delay(delay), value: trigger)
        } else {
            content
        }
    }
}

// MARK: - Preview

#Preview("ChatHomeMockView – Light & Dark") {
    Group {
        ChatHomeMockView()
            .environment(\.colorScheme, .light)

        ChatHomeMockView()
            .environment(\.colorScheme, .dark)
    }
}
