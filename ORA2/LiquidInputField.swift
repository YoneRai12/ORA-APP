import Speech
import AVFoundation
import SwiftUI

struct LiquidInputField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    var placeholder: String = "メッセージを入力"
    var onSend: () -> Void
    var onMic: () -> Void = {}

    // 内蔵の音声入力機能を使うか（false の場合は onMic を呼ぶ）
    var enableBuiltInMic: Bool = true

    // 新規: オプションカードをこのコンポーネント直下に表示できるようにするための Binding（任意）
    // これらが渡されていれば、この View 内でカードを表示・制御します。
    var thinkLevel: Binding<ThinkLevel>? = nil
    var useWebSearch: Binding<Bool>? = nil
    var showOptions: Binding<Bool>? = nil

    // 既存: 外から個別にトグルしたい場合のフック（任意）
    var onOptionsTap: () -> Void = {}

    @State private var isEditing = false
    @State private var isHovered = false

    // 音声入力関連の状態
    @State private var isRecording = false
    @State private var speechAuthStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    // 音声認識エンジン
    private let speechRecognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?

    // 必須のプライバシーキー（Info.plist）が存在するかを確認
    private func hasRequiredPrivacyKeys() -> Bool {
        let mic = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        let speech = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        return (mic != nil && !mic!.isEmpty) && (speech != nil && !speech!.isEmpty)
    }

    var body: some View {
        VStack(spacing: 8) {
            let isActive = isEditing || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (showOptions?.wrappedValue ?? false)

            // iOS 18+ Liquid Glass の見た目最適化: テーマと状態に応じてティント濃度を調整
            let glassTint: Color = {
                let activeLight: Double = 0.16
                let activeDark: Double  = 0.22
                let idleLight: Double   = 0.08
                let idleDark: Double    = 0.12
                let alpha = isActive
                    ? (colorScheme == .dark ? activeDark : activeLight)
                    : (colorScheme == .dark ? idleDark  : idleLight)
                return Color.accentColor.opacity(alpha)
            }()

            HStack(spacing: 10) {
                // 先頭を Image → Button に変更
                Button(action: {
                    // 優先: 渡されていればローカルの showOptions をトグル
                    if let show = showOptions {
                        withAnimation(.spring) { show.wrappedValue.toggle() }
                    }
                    // 併用: 外部にも通知（任意）
                    onOptionsTap()
                }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("オプション")

                ZStack(alignment: .leading) {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholder).foregroundStyle(.secondary)
                    }
                    TextField("", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .disableAutocorrection(false)
                        .lineLimit(1...4)
                        .onChange(of: text) { _, _ in isEditing = true }
                        .submitLabel(.send)
                        .onSubmit { trigger() }
                        .onTapGesture { isEditing = true }
                        .onChange(of: text) { _, newValue in
                            isEditing = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        // 入力欄長押しでもオプションを開ける（Binding が渡されている時のみ）
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.35)
                                .onEnded { _ in
                                    if let show = showOptions {
                                        withAnimation(.spring) { show.wrappedValue.toggle() }
                                    } else {
                                        // 外部フックのみ設定されている場合はそちらを呼ぶ
                                        onOptionsTap()
                                    }
                                }
                        )
                }

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: {
                        if enableBuiltInMic {
                            isRecording ? stopRecording() : startRecording()
                        } else {
                            onMic()
                        }
                    }) {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .foregroundStyle(isRecording ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: trigger) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.white)
                            .background(
                                Circle()
                                    .fill(Color.accentColor)
                                    .shadow(color: Color.accentColor.opacity(0.35), radius: 8, x: 0, y: 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 36, alignment: .center)
            .background {
                if #available(iOS 18.0, *) {
                    // 本物の Liquid Glass（iOS 18+）
                    Color.clear
                        .glassEffect(
                            .regular
                                .tint(glassTint)
                                .interactive(),
                            in: .rect(cornerRadius: 18)
                        )
                } else {
                    // フォールバック：既存の擬似ガラス
                    let r = RoundedRectangle(cornerRadius: 18, style: .continuous)
                    r.fill(.clear)
                        .oraLiquid(in: r)
                }
            }
            // アクティブ時の微光グロー（アクセント色）
            .shadow(color: Color.accentColor.opacity(isActive ? 0.22 : 0.0), radius: isActive ? 18 : 0, x: 0, y: 0)
            // 内側のハイライト（光の縁）
            .overlay {
                let r = RoundedRectangle(cornerRadius: 18, style: .continuous)
                r.inset(by: 0.5)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.18), lineWidth: 1)
                    .blendMode(.screen)
                    .opacity(isActive ? 1.0 : 0.7)
            }
            .contentShape(.rect(cornerRadius: 18))
            // ポインタホバー時にわずかにスケールアップ（iPadOS/外部ポインタ）
            .onHover { hovering in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    isHovered = hovering
                }
            }
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .overlay(alignment: .topLeading) {
                if let ws = useWebSearch, let show = showOptions, show.wrappedValue {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("追加", systemImage: "plus")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { show.wrappedValue = false }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        // Web MCP（緑）
                        Button {
                            ws.wrappedValue = true
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { show.wrappedValue = false }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "globe")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Web MCP")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(Capsule().fill(Color.green))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background {
                        if #available(iOS 18.0, *) {
                            Color.clear
                                .glassEffect(
                                    .regular
                                        .tint(Color.accentColor.opacity(0.12))
                                        .interactive(),
                                    in: .rect(cornerRadius: 14)
                                )
                        } else {
                            let r = RoundedRectangle(cornerRadius: 14, style: .continuous)
                            r.fill(Color.clear)
                                .overlay(r.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .overlay {
                        let r = RoundedRectangle(cornerRadius: 14, style: .continuous)
                        r.inset(by: 0.5)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.18), lineWidth: 1)
                            .blendMode(.screen)
                            .opacity(0.9)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98)))
                    .padding(.leading, 0)
                    .padding(.top, -8)
                    .zIndex(3)
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: isEditing)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: text)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showOptions?.wrappedValue)
        .onAppear {
            if enableBuiltInMic {
                if hasRequiredPrivacyKeys() {
                    requestSpeechAuthorization()
                } else {
                    // 必須キーが無い場合は落ちるため、機能を無効化して警告ログ
                    print("[Mic] Missing Info.plist keys: NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription")
                }
            }
        }
    }

    private func trigger() {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend() }
    }

    // MARK: - Speech Recognition
    @MainActor
    private func requestSpeechAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.speechAuthStatus = status
            }
        }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    @MainActor
    private func startRecording() {
        guard speechAuthStatus == .authorized else { return }
        guard hasRequiredPrivacyKeys() else { return }
        // 既存タスクがあれば停止
        stopRecording()

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do { try audioEngine.start() } catch { return }

        self.recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let result = result {
                    // 逐次的にテキストへ反映
                    self.text = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    // 自動停止（必要に応じて継続したい場合は削除）
                    self.stopRecording()
                }
            }
        }

        self.isRecording = true
    }

    @MainActor
    private func stopRecording() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        // 録音終了後はセッションを解放
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

