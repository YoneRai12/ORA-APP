// CHANGELOG (2025-11-01)
// - Full refactor for stability and iOS 17+ compatibility (iOS 18 Liquid Glass with fallback)
// - Dynamic ServerConfig with priority: ENV ORA_BASE_URL -> @AppStorage("ora.baseURL") -> Info.plist ORA_BASE_URL -> default
// - Connection Settings sheet (edit/validate Base URL, ping /v1/chat/completions)
// - Request body compatibility and fallback; removed invalid max_tokens: -1
// - Robust bestText extraction; shorter error summaries; retry/timeout preserved
// - Threads/messages persistence via UserDefaults JSON (key: ora.threads.v1); Temporary chat remains non-persistent
// - Privacy scope toggle (全員/自分のみ); private mode prevents server send; dangerous words auto-downgrade with pill
// - OCR/Photos picker hardened (accurate, non-blocking, error-handled)
// - Safari wrapper hardened; future configuration stubbed
// - Streaming load reduced; scroll coalesced; state dictionaries cleared deterministically
// - Bug fixes: AttributedString fallback safety, edge drag start handling, OCR cgImage nil guard, unified scroll handling, previews

import SwiftUI
import UserNotifications
import Vision
import PhotosUI
import SafariServices
import WebKit
import UniformTypeIdentifiers

// MARK: - Server Configuration

fileprivate enum ServerConfig {
    // Default fallback
    private static let defaultBaseURLString = "https://example.ngrok-free.app"

    // Info.plist keys
    private static let infoKeyBaseURL = "ORA_BASE_URL"
    private static let infoKeyDefaultModel = "ORA_DEFAULT_MODEL"
    private static let appStorageKeyBaseURL = "ora.baseURL"

    // AppStorage key (user override)
    private static var storedBaseURLString: String {
        get { UserDefaults.standard.string(forKey: appStorageKeyBaseURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: appStorageKeyBaseURL) }
    }

    // Normalized Base URL String (dynamic priority)
    static var baseURLString: String {
        // 1) ENV (DEBUG/any)
        if let env = ProcessInfo.processInfo.environment["ORA_BASE_URL"], !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalize(urlString: env)
        }
        // 2) @AppStorage override
        if !storedBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalize(urlString: storedBaseURLString)
        }
        // 3) Info.plist
        if let info = Bundle.main.object(forInfoDictionaryKey: infoKeyBaseURL) as? String, !info.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalize(urlString: info)
        }
        // 4) Default
        return normalize(urlString: defaultBaseURLString)
    }

    static var baseURL: URL { URL(string: baseURLString)! }

    // Build URL by safely appending path components
    static func url(appending path: String) -> URL? {
        guard var url = URL(string: baseURLString) else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/").map(String.init)
        for p in parts where !p.isEmpty { url.append(path: p) }
        return url
    }

    static func defaultModel() -> String {
        if let info = Bundle.main.object(forInfoDictionaryKey: infoKeyDefaultModel) as? String, !info.isEmpty { return info }
        return "openai/gpt-oss-20b"
    }

    // URL normalization: require scheme, remove trailing slash (keeping scheme://)
    static func normalize(urlString: String) -> String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return defaultBaseURLString }
        let lower = s.lowercased()
        if !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) { s = "https://" + s }
        while s.count > 8 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - Models (Codable + Identifiable)

fileprivate struct Msg: Identifiable, Hashable, Codable {
    let id: UUID
    var text: String
    let isUser: Bool
}

fileprivate struct ChatThread: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var messages: [Msg]
    var updatedAt: Date
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // Drawer
    @State private var drawerProgress: CGFloat = 0
    @State private var lastHapticStateOpen: Bool = false
    @State private var drawerSearchText: String = ""
    @State private var drawerSearchDebounced: String = ""

    // Chat state
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool
    @State private var messages: [Msg] = []

    // Threads persistence
    @State private var threads: [ChatThread] = []
    @State private var currentThreadID: UUID? = nil
    private let placeholderTitle = "NEWchat"

    // UI states
    @State private var showPlusMenu: Bool = false
    @State private var isRecording: Bool = false
    @State private var statusIsLive: Bool = false
    @State private var appearAnim: Bool = false
    @State private var showTemporaryChat: Bool = false
    @State private var isOffline: Bool = false

    // Streaming states (reduced)
    @State private var streamingLastChunk: [UUID: String] = [:]
    @State private var streamingRevealProgress: [UUID: Double] = [:]
    @State private var streamingChunkSerial: [UUID: Int] = [:]
    @State private var streamingIsLong: [UUID: Bool] = [:]

    // Scroll helpers
    @State private var autoscrollEnabled: Bool = true
    @State private var pendingScrollTarget: UUID? = nil

    // Model selection
    @AppStorage("ora.model") private var selectedModel: String = ServerConfig.defaultModel()
    private let availableModels: [String] = [
        "openai/gpt-oss-7b", "openai/gpt-oss-20b", "openai/gpt-oss-120b"
    ]

    // Web
    @State private var showWebSearch: Bool = false
    @State private var webQuery: String = ""

    // Photos & OCR
    @State private var showPhotoPicker: Bool = false
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var pickedImage: UIImage? = nil
    @State private var isRunningOCR: Bool = false
    @State private var ocrErrorMessage: String? = nil

    // ZIP picker
    @State private var showZipPicker: Bool = false
    @State private var pickedZipURL: URL? = nil

    // Connection Settings
    @State private var showConnectionSettings: Bool = false
    @State private var editingBaseURL: String = ServerConfig.baseURLString
    @State private var connectionProbeResult: String = ""
    @State private var isProbing: Bool = false

    // Privacy scope
    enum PrivacyScope: String, CaseIterable { case everyone = "全員", meOnly = "自分のみ" }
    @AppStorage("ora.privacy") private var privacyRaw: String = PrivacyScope.everyone.rawValue
    private var privacy: PrivacyScope { PrivacyScope(rawValue: privacyRaw) ?? .everyone }

    // Dangerous words auto-downgrade pill
    @State private var showPrivacyDowngradePill: Bool = false

    // Debounced persistence
    @State private var saveDebounceWorkItem: DispatchWorkItem? = nil

    var body: some View {
        GeometryReader { geo in
            let screenW = geo.size.width
            let drawerW = screenW * 0.82
            let offsetX = drawerProgress * drawerW

            ZStack(alignment: .leading) {
                // Drawer under-layer
                drawerView
                    .frame(width: drawerW)
                    .offset(x: -drawerW + offsetX)

                // Content plane
                ZStack {
                    mainChat(screenW: screenW)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.clear)
                }
                .offset(x: offsetX)
                .safeAreaInset(edge: .top) { topBar.padding(.horizontal, 12) }
                .safeAreaInset(edge: .bottom) { composerGroup.frame(height: 56).padding(.horizontal, 12).padding(.bottom, 10) }

                // Left-edge catcher (open)
                if drawerProgress <= 0.001 {
                    Color.clear.frame(width: 28).frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .highPriorityGesture(edgeDragGesture(drawerWidth: drawerW))
                }

                // Close overlay
                if drawerProgress > 0.001 {
                    Color.clear.ignoresSafeArea().padding(.leading, drawerW)
                        .contentShape(Rectangle())
                        .onTapGesture { animateDrawer(to: 0) }
                        .highPriorityGesture(edgeDragGesture(drawerWidth: drawerW))
                }

                // Vertical separator
                if drawerProgress > 0.001 {
                    Rectangle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.10))
                        .frame(width: 1)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.2), radius: 4, x: 2, y: 0)
                        .offset(x: offsetX)
                }
            }
            .background(
                ZStack {
                    GlassBackdropLayer().allowsHitTesting(false)
                        .opacity(colorScheme == .dark ? 0.65 : 0.45)
                    (colorScheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.05))
                        .allowsHitTesting(false)
                }.ignoresSafeArea()
            )
            .compositingGroup()
            .onAppear { onAppearSetup() }
            .sheet(isPresented: $showTemporaryChat) { TemporaryChatSheet() }
            .sheet(isPresented: $showWebSearch) {
                let url = safeSearchURL(webQuery) ?? URL(string: "https://search.brave.com")!
                SafariView(url: url)
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { newItem in handlePhotoItemChange(newItem) }
            .sheet(isPresented: $showZipPicker) { DocumentPicker(types: [UTType.zip]) { self.pickedZipURL = $0 } }
            .sheet(isPresented: $showConnectionSettings) {
                ConnectionSettingsSheet(
                    baseURLText: $editingBaseURL,
                    onSave: { newURL in
                        let normalized = ServerConfig.normalize(urlString: newURL)
                        ServerConfig.storedBaseURLString = normalized
                        editingBaseURL = normalized
                    },
                    onPing: { Task { await runConnectionProbe(showInSheet: true) } },
                    currentProbe: $connectionProbeResult,
                    isProbing: $isProbing
                )
            }
            .overlay(alignment: .top) {
                if isRunningOCR { 
                    ProgressPill(text: "OCR中…")
                        .padding(.top, 12)
                }
                if showPrivacyDowngradePill {
                    ProgressPill(text: "危険語を検知したため『自分のみ』に切替")
                        .padding(.top, isRunningOCR ? 44 : 12)
                }
            }
            .alert(item: Binding(get: { ocrErrorMessage.map { AlertMessage(message: $0) } }, set: { _ in ocrErrorMessage = nil })) { msg in
                Alert(title: Text("エラー"), message: Text(msg.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    // MARK: - Setup & Persistence

    private func onAppearSetup() {
        if reduceMotion { appearAnim = true } else { withAnimation(.easeOut(duration: 0.22)) { appearAnim = true } }
        requestNotificationAuthorizationIfNeeded()
        loadThreads()
        ensureInitialThread()
        // Warm-up ping (non-fatal)
        Task { let endpoint = ServerConfig.url(appending: "/v1/chat/completions") ?? ServerConfig.baseURL; _ = try? await performRequestWithRetry(url: endpoint, key: "message", value: "ping", variant: .json, retries: 1) }
    }

    private let threadsKey = "ora.threads.v1"

    private func loadThreads() {
        guard let data = UserDefaults.standard.data(forKey: threadsKey) else {
            // Seed initial thread
            let initialMsg = Msg(id: UUID(), text: "新しいチャットを開始しました。質問を入力してください。", isUser: false)
            let thread = ChatThread(id: UUID(), title: placeholderTitle, messages: [initialMsg], updatedAt: Date())
            threads = [thread]
            currentThreadID = thread.id
            messages = thread.messages
            return
        }
        do {
            let decoded = try JSONDecoder().decode([ChatThread].self, from: data)
            threads = decoded.sorted { $0.updatedAt > $1.updatedAt }
            if let first = threads.first { currentThreadID = first.id; messages = first.messages }
        } catch {
            // Corrupted: reset safely
            UserDefaults.standard.removeObject(forKey: threadsKey)
            let initialMsg = Msg(id: UUID(), text: "新しいチャットを開始しました。質問を入力してください。", isUser: false)
            let thread = ChatThread(id: UUID(), title: placeholderTitle, messages: [initialMsg], updatedAt: Date())
            threads = [thread]
            currentThreadID = thread.id
            messages = thread.messages
        }
    }

    private func saveThreadsDebounced() {
        saveDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [threads] in
            do {
                let data = try JSONEncoder().encode(threads)
                UserDefaults.standard.set(data, forKey: threadsKey)
            } catch {
                // ignore
            }
        }
        saveDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func ensureInitialThread() {
        if threads.isEmpty {
            let initialMsg = Msg(id: UUID(), text: "新しいチャットを開始しました。質問を入力してください。", isUser: false)
            let thread = ChatThread(id: UUID(), title: placeholderTitle, messages: [initialMsg], updatedAt: Date())
            threads = [thread]
            currentThreadID = thread.id
            messages = thread.messages
        } else if currentThreadID == nil {
            currentThreadID = threads.first?.id
            if let t = threads.first { messages = t.messages }
        }
    }

    private func syncCurrentMessagesToThread() {
        guard let id = currentThreadID, let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].messages = messages
        threads[idx].updatedAt = Date()
        let updated = threads.remove(at: idx)
        threads.insert(updated, at: 0)
        saveThreadsDebounced()
    }

    // MARK: - Main Chat

    private func mainChat(screenW: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { m in
                        if m.isUser {
                            bubble(id: m.id, text: m.text, isUser: true, maxWidth: screenW * 0.84)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .id(m.id)
                        } else {
                            bubble(id: m.id, text: m.text, isUser: false, maxWidth: screenW * 0.78)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(m.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .background(Color.clear)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .onChange(of: pendingScrollTarget) { id in
                guard autoscrollEnabled, let id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: inputFocused) { focused in
                if focused, let last = messages.last {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            // Left: menu
            Button { let target: CGFloat = drawerProgress < 0.5 ? 1 : 0; animateDrawer(to: target); playSoftHaptic() } label: {
                Image(systemName: drawerProgress > 0.001 ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
                    .frame(width: 36, height: 36)
                    .background(chipGlassCircle())
                    .overlay(Circle().stroke(borderStroke(colorScheme), lineWidth: 1))
            }.buttonStyle(.plain).accessibilityLabel("メニュー")

            // Center: title chip -> Menu
            Menu {
                Section("接続設定") {
                    Button("Base URL を編集…") { editingBaseURL = ServerConfig.baseURLString; showConnectionSettings = true }
                    Button("接続テスト") { Task { await runConnectionProbe() } }
                }
                Section("ツール") {
                    Button("Web検索を開く") { webQuery = inputText; showWebSearch = true }
                    Button("写真からテキスト抽出") { showPhotoPicker = true }
                    Button("ZIPを開く") { showZipPicker = true }
                }
                Section("モデル") {
                    Picker("モデル", selection: $selectedModel) {
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentTitle())
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
                    Text(statusIsLive ? "● Connected • gpt-next" : "● Syncing • gpt-next")
                        .font(.caption2)
                        .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8).opacity(0.8))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 10)
                .background(glassCapsule(tintOpacity: 0.14))
                .overlay(Capsule().stroke(borderStroke(colorScheme), lineWidth: 1))
                .overlay(Capsule().inset(by: 0.5).strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.18), lineWidth: 1).blendMode(.screen).opacity(0.9))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }

            // Right: plus -> Temporary chat
            Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { showTemporaryChat.toggle() }; playSoftHaptic() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
                    .frame(width: 36, height: 36)
                    .background(chipGlassCircle())
                    .overlay(Circle().stroke(borderStroke(colorScheme), lineWidth: 1))
            }.buttonStyle(.plain).accessibilityLabel("一時チャット")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func currentTitle() -> String {
        if let id = currentThreadID, let t = threads.first(where: { $0.id == id }) { return t.title }
        return placeholderTitle
    }

    // MARK: - Bubble & Message Body

    @ViewBuilder private func messageBodyView(_ text: String) -> some View {
        if let attr = try? AttributedString(markdown: text) {
            Text(attr)
        } else {
            Text(text)
        }
    }

    @ViewBuilder private func streamingMessageBodyView(id: UUID, text: String, isUser: Bool) -> some View {
        if !isUser, let last = streamingLastChunk[id], !last.isEmpty, text.hasSuffix(last), (try? AttributedString(markdown: text)) == nil {
            let baseText = String(text.dropLast(last.count))
            let progress = streamingRevealProgress[id] ?? 1.0
            let serial = streamingChunkSerial[id] ?? 0
            VStack(alignment: .leading, spacing: 0) {
                Text(baseText).font(.body).foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
                Text(last).id(serial).font(.body).foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8)).mask(
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: CGFloat(min(progress, 1.0))),
                        .init(color: .clear, location: CGFloat(min(progress + 0.001, 1.0)))
                    ], startPoint: .leading, endPoint: .trailing)
                )
            }
        } else {
            messageBodyView(text).font(.body).foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
        }
    }

    @ViewBuilder private func bubble(id: UUID, text: String, isUser: Bool, maxWidth: CGFloat) -> some View {
        let isAssistant = !isUser
        let isLong = isAssistant ? (streamingIsLong[id] ?? (text.count >= 100)) : false
        if isAssistant && isLong {
            VStack(alignment: .leading, spacing: 0) {
                streamingMessageBodyView(id: id, text: text, isUser: isUser)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, -16)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                    streamingMessageBodyView(id: id, text: text, isUser: isUser)
                        .font(.body)
                        .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.6 : 0.15), radius: 1, x: 0, y: 1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(glassCapsule(tintOpacity: 0.10))
                        .overlay(Capsule().stroke(borderStroke(colorScheme), lineWidth: 1))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: maxWidth, alignment: isUser ? .trailing : .leading)
                        .layoutPriority(1)

                    Text("\(Date(), format: .dateTime.hour().minute()) · \(isUser ? "Sent" : (statusIsLive ? "Live" : "Delivered"))")
                        .font(.caption2)
                        .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8).opacity(0.7))
                        .frame(maxWidth: maxWidth, alignment: isUser ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    // MARK: - Composer

    private var composerGroup: some View {
        let isActive = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRecording
        return ZStack {
            glassCapsule(tintOpacity: isActive ? 0.24 : 0.14)
                .overlay(Capsule().stroke(borderStroke(colorScheme), lineWidth: 1))
                .overlay(Capsule().inset(by: 0.5).strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.18), lineWidth: 1).blendMode(.screen).opacity(0.9))
                .clipShape(Capsule())
                .shadow(color: Color.accentColor.opacity(isActive ? 0.18 : 0.0), radius: 18, x: 0, y: 1)

            HStack(spacing: 8) {
                // Settings chip (privacy sub menu)
                Menu {
                    Section("公開範囲") {
                        Button("全員", action: { privacyRaw = PrivacyScope.everyone.rawValue })
                        Button("自分のみ", action: { privacyRaw = PrivacyScope.meOnly.rawValue })
                    }
                    Section("その他") {
                        Button("設定を閉じる", action: { showPlusMenu = false })
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
                        .frame(width: 36, height: 36)
                        .background(chipGlassCircle())
                        .overlay(Circle().stroke(borderStroke(colorScheme), lineWidth: 1))
                }.buttonStyle(.plain).accessibilityLabel("設定")

                // TextEditor with placeholder
                ZStack(alignment: .leading) {
                    if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("質問してみましょう")
                            .font(.system(size: 15))
                            .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8).opacity(0.7))
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $inputText)
                        .font(.system(size: 15))
                        .frame(minHeight: 44, maxHeight: 140)
                        .scrollIndicators(.never)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .focused($inputFocused)
                        .onTapGesture { inputFocused = true }
                }
                .frame(maxWidth: .infinity)
                .accessibilityValue("複数行の入力")

                // Right: Mic or Send
                if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { isRecording.toggle(); playSoftHaptic() } label: {
                        Image(systemName: isRecording ? "mic.circle.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isRecording ? .red : fgPrimary(colorScheme, alphaDark: 0.8))
                            .frame(width: 36, height: 36)
                            .background(chipGlassCircle())
                            .overlay(Circle().stroke(borderStroke(colorScheme), lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel(isRecording ? "録音停止" : "録音開始")
                } else {
                    Button(action: { if reduceMotion { withAnimation(.easeOut(duration: 0.12)) {} } else { withAnimation(.spring(response: 0.28, dampingFraction: 0.22)) {} } sendCurrentInput() }) {
                        Image(systemName: privacy == .everyone ? "paperplane.fill" : "lock.square.stack.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(privacy == .everyone ? Color.accentColor : Color.orange)
                            .frame(width: 36, height: 36)
                            .background(chipGlassCircle())
                            .overlay(Circle().stroke(borderStroke(colorScheme), lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("送信")
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func sendCurrentInput() {
        var text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Dangerous word detection (very simple heuristic)
        if containsDangerousWords(text) && privacy != .meOnly {
            privacyRaw = PrivacyScope.meOnly.rawValue
            showPrivacyDowngradePill = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { showPrivacyDowngradePill = false }
        }
        let user = Msg(id: UUID(), text: text, isUser: true)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.20)) {
            messages.append(user)
            pendingScrollTarget = user.id
            syncCurrentMessagesToThread()
        }
        inputText = ""

        // Private mode: do not send to server
        if privacy == .meOnly { return }

        Task { await sendToBackend(text) }
        Task { await requestTitleIfNeeded(basedOn: text) }
    }

    private func containsDangerousWords(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let keywords = ["password", "api key", "secret", "ssh", "token", "住所", "電話", "クレジット", "card", "pwd"]
        return keywords.contains { lowered.contains($0) }
    }

    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    // MARK: - Networking

    private static let networkSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: config)
    }()

    private enum RequestVariant { case openAIChatJSON, json, formURLEncoded, getQuery }

    private struct ChatResponse: Decodable { let reply: String?; let message: String?; let error: String? }

    private func bestText(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) {
            for s in [decoded.reply, decoded.message, decoded.error] { if let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t } }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data, options: []) {
            if let dict = obj as? [String: Any] {
                for key in ["reply", "message", "content", "error", "text", "output"] {
                    if let v = dict[key] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
                }
                if let choices = dict["choices"] as? [[String: Any]], let first = choices.first {
                    if let msg = first["message"] as? [String: Any], let content = msg["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return content }
                    if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return content }
                }
            }
            if let arr = obj as? [Any] { if let firstStr = arr.compactMap({ $0 as? String }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return firstStr } }
        }
        if let s = String(data: data, encoding: .utf8) { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { return t } }
        return nil
    }

    private func performRequest(url: URL, key: String, value: String, variant: RequestVariant) async throws -> (Int, Data) {
        var finalURL = url
        var req = URLRequest(url: finalURL)

        switch variant {
        case .openAIChatJSON:
            let body: [String: Any] = [
                "model": selectedModel,
                "messages": [["role": "user", "content": value]],
                "temperature": 0.7,
                // NOTE: Do not send invalid negative max_tokens
            ]
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        case .json:
            var body: [String: Any] = [key: value]
            body["model"] = selectedModel
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        case .formURLEncoded:
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedVal = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            let body = "\(encodedKey)=\(encodedVal)"
            req.httpBody = body.data(using: .utf8)
        case .getQuery:
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: key, value: value))
            comps.queryItems = items
            if let u = comps.url { finalURL = u }
            req = URLRequest(url: finalURL)
            req.httpMethod = "GET"
        }

        req.setValue("application/json, text/plain;q=0.7, */*;q=0.2", forHTTPHeaderField: "Accept")
        req.setValue("ORA-Mobile/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.timeoutInterval = 30

        let (data, resp) = try await ContentView.networkSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if let s = String(data: data, encoding: .utf8) {
            print("[NET ←][\(variant) \(key)] status=\(status) bytes=\(data.count) preview=\(s.prefix(160))")
        } else {
            print("[NET ←][\(variant) \(key)] status=\(status) bytes=\(data.count) (non-utf8)")
        }
        return (status, data)
    }

    private func performRequestWithRetry(url: URL, key: String, value: String, variant: RequestVariant, retries: Int = 1) async throws -> (Int, Data) {
        let transientCodes: Set<URLError.Code> = [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet]
        var lastError: Error?
        for attempt in 0...retries {
            do { return try await performRequest(url: url, key: key, value: value, variant: variant) }
            catch {
                lastError = error
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && transientCodes.contains(URLError.Code(rawValue: ns.code)) && attempt < retries {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                } else { throw error }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func isLikelyErrorPayload(_ text: String) -> Bool {
        let t = text.lowercased()
        let hints = ["unexpected endpoint or method", "method not allowed", "not found", "invalid endpoint", "invalid method", "error:", "bad request", "405", "404"]
        return hints.contains { t.contains($0) }
    }

    private func sendToBackend(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let endpoint = ServerConfig.url(appending: "/v1/chat/completions") ?? ServerConfig.baseURL
        do {
            // 1st attempt: JSON {message, model}
            var (status, data) = try await performRequestWithRetry(url: endpoint, key: "message", value: trimmed, variant: .json, retries: 1)
            if !(200...299).contains(status) {
                // 2nd attempt: OpenAI compatible
                (status, data) = try await performRequestWithRetry(url: endpoint, key: "message", value: trimmed, variant: .openAIChatJSON, retries: 1)
            }

            guard (200...299).contains(status) else {
                let preview = bestText(from: data) ?? (String(data: data, encoding: .utf8) ?? "")
                await appendReply("サーバーエラー (\(status)): \(String(preview.prefix(200)))\n接続先: \(endpoint.absoluteString)")
                return
            }

            if let reply = bestText(from: data), !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if isLikelyErrorPayload(reply) { await appendReply("サーバー応答エラー: \(reply)\n接続先: \(endpoint.absoluteString)") }
                else { await streamReply(reply) }
            } else {
                await appendReply("空の応答でした。\n接続先: \(endpoint.absoluteString)")
            }
        } catch {
            await showOfflineBannerTemporarily()
            let ns = error as NSError
            let summary = ns.domain == NSURLErrorDomain ? "ネットワークエラー (\(URLError.Code(rawValue: ns.code)))" : ns.localizedDescription
            await appendReply("エラー: \(summary)\n接続先: \(endpoint.absoluteString)")
        }
    }

    // Title generation (guarded)
    private func requestTitleIfNeeded(basedOn userText: String) async {
        guard let id = currentThreadID, let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        let currentTitle = threads[idx].title
        guard currentTitle == placeholderTitle || currentTitle.isEmpty else { return }

        let sanitizedInput = sanitizeTitle(userText)
        guard !sanitizedInput.isEmpty else { return }

        let prompt = "次のテキストをもとに、スレッドの短い日本語タイトルを1つ作成してください。\n条件：\n文字数は 最大20文字（全角換算）。\n出力はタイトルの文字列だけ（修飾なし）。\n体言止めで簡潔に。\n入力：\n" + userText
        let endpoint = ServerConfig.url(appending: "/v1/chat/completions") ?? ServerConfig.baseURL
        do {
            let (status, data) = try await performRequestWithRetry(url: endpoint, key: "message", value: prompt, variant: .openAIChatJSON, retries: 1)
            guard (200...299).contains(status) else { return }
            let serverRaw = bestText(from: data)
            let serverClean = serverRaw.map(sanitizeTitle) ?? ""
            let serverClipped = clipToMaxChars(serverClean, max: 20)
            let fallbackClipped = clipToMaxChars(sanitizedInput, max: 20)
            let candidate = !serverClipped.isEmpty ? serverClipped : (!fallbackClipped.isEmpty ? fallbackClipped : nil)
            if let title = candidate, title != placeholderTitle { await animateTitleChange(to: title) }
        } catch {
            let fallbackClipped = clipToMaxChars(sanitizedInput, max: 20)
            if !fallbackClipped.isEmpty, fallbackClipped != placeholderTitle { await animateTitleChange(to: fallbackClipped) }
        }
    }

    private func clipToMaxChars(_ s: String, max: Int) -> String { s.count <= max ? s : String(s.prefix(max)) }

    private func sanitizeTitle(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutNewlines = trimmed.replacingOccurrences(of: "\n", with: " ")
        let disallowed = CharacterSet.controlCharacters.union(.punctuationCharacters).union(.symbols)
        let filteredScalars = withoutNewlines.unicodeScalars.filter { scalar in
            if disallowed.contains(scalar) { return false }
            if scalar.properties.isEmoji { return false }
            return true
        }
        return String(String.UnicodeScalarView(filteredScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private func animateTitleChange(to finalTitle: String) async {
        guard let id = currentThreadID, let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        let target = finalTitle
        var i = 0
        while i < target.count {
            let step = min(Int.random(in: 1...3), target.count - i)
            i += step
            let partial = String(target.prefix(i))
            if let j = threads.firstIndex(where: { $0.id == id }) {
                threads[j].title = partial
                threads[j].updatedAt = Date()
                let updated = threads.remove(at: j)
                threads.insert(updated, at: 0)
            }
            try? await Task.sleep(nanoseconds: 24_000_000)
        }
        if let j = threads.firstIndex(where: { $0.id == id }) {
            threads[j].title = target
            threads[j].updatedAt = Date()
            let updated = threads.remove(at: j)
            threads.insert(updated, at: 0)
        }
        saveThreadsDebounced()
    }

    // MARK: - Streaming (lighter)

    private func streamReply(_ full: String) async {
        let L = full.count
        let id = await MainActor.run { appendAssistantPlaceholder() }
        let isLong = L >= 160
        await MainActor.run { self.streamingIsLong[id] = isLong }

        var buffer = ""
        var i = 0
        let chars = Array(full)

        while i < chars.count {
            let remaining = chars.count - i
            // Coarse chunking to reduce UI churn
            let step = min(isLong ? 24 : 8, remaining)
            let end = i + step
            let newChunk = String(chars[i..<end])
            buffer.append(contentsOf: newChunk)

            await MainActor.run {
                if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[idx].text = buffer
                    self.streamingLastChunk[id] = newChunk
                    self.streamingRevealProgress[id] = 1.0
                    self.streamingChunkSerial[id] = (self.streamingChunkSerial[id] ?? 0) + 1
                    self.pendingScrollTarget = id
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(isLong ? 40_000_000 : 20_000_000))
            i = end
        }

        await MainActor.run {
            self.streamingLastChunk[id] = nil
            self.streamingIsLong[id] = nil
            self.streamingRevealProgress[id] = nil
        }
        postLLMNotification(title: "新しい返信", body: String(full.prefix(80)))
        await MainActor.run { syncCurrentMessagesToThread() }
    }

    @MainActor private func appendReply(_ text: String) {
        self.messages.append(.init(id: UUID(), text: text, isUser: false))
        self.pendingScrollTarget = self.messages.last?.id
        syncCurrentMessagesToThread()
    }

    @MainActor private func appendAssistantPlaceholder() -> UUID {
        let id = UUID()
        self.messages.append(.init(id: id, text: "", isUser: false))
        self.pendingScrollTarget = id
        syncCurrentMessagesToThread()
        return id
    }

    // MARK: - Offline banner

    @MainActor private func showOfflineBannerTemporarily() async {
        withAnimation(.easeOut(duration: 0.12)) { self.isOffline = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { withAnimation(.easeOut(duration: 0.12)) { self.isOffline = false } }
    }

    // MARK: - Connection tools

    private func openNgrok() {
        #if canImport(UIKit)
        if let url = URL(string: ServerConfig.baseURLString), UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url) }
        #endif
    }

    @MainActor private func runConnectionProbe(showInSheet: Bool = false) async {
        isProbing = true
        defer { isProbing = false }
        var report: [String] = []
        let endpoint = ServerConfig.url(appending: "/v1/chat/completions") ?? ServerConfig.baseURL
        report.append("[Probe] Endpoint: \(endpoint.absoluteString)")
        do {
            let (status, data) = try await performRequest(url: endpoint, key: "message", value: "ping", variant: .json)
            let bodyPreview: String
            if let s = String(data: data, encoding: .utf8) {
                bodyPreview = String(s.prefix(160))
            } else {
                bodyPreview = "(non-utf8 \(data.count) bytes)"
            }
            report.append("[OK] status=\(status) body=\(bodyPreview)")
        } catch {
            let ns = error as NSError
            let summary = ns.domain == NSURLErrorDomain ? "ネットワークエラー (\(URLError.Code(rawValue: ns.code)))" : ns.localizedDescription
            report.append("[NG] error=\(summary)")
        }
        let text = report.joined(separator: "\n")
        if showInSheet { connectionProbeResult = text } else { await appendReply(text) }
    }

    // MARK: - Drawer

    private var drawerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Search
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8).opacity(0.7))
                    TextField("検索", text: $drawerSearchText)
                        .textInputAutocapitalization(.none)
                        .disableAutorrection(true)
                        .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
                        .onChange(of: drawerSearchText) { q in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if q == drawerSearchText { drawerSearchDebounced = q } }
                        }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(surfaceBackground(RoundedRectangle(cornerRadius: 12, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(borderStroke(colorScheme), lineWidth: 1))
                .padding(.top, 12)

                // New chat
                Button(action: { newChat() }) {
                    drawerRow(title: "新規チャット", isHighlighted: false, leadingIcon: "plus").frame(minHeight: 44)
                }.buttonStyle(.plain).padding(.top, 8)

                Text("チャット履歴")
                    .font(.caption)
                    .foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8).opacity(0.7))
                    .padding(.top, 8).padding(.horizontal, 8)

                ForEach(filteredThreads()) { t in
                    drawerRow(title: t.title, isHighlighted: currentThreadID == t.id)
                        .onTapGesture { selectThread(t.id) }
                }

                Divider().padding(.vertical, 8)

                // Quick links
                drawerRow(title: "ChatGPT", isHighlighted: true).onTapGesture { selectSection("ChatGPT") }

                Divider().padding(.vertical, 8)

                // Account row
                HStack(spacing: 12) {
                    Circle().fill(fgPrimary(colorScheme, alphaDark: 0.8).opacity(0.15)).frame(width: 32, height: 32)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("you@example.com").font(.footnote).foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
                        Text("Standard").font(.caption2).foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8).opacity(0.7))
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
                .onTapGesture { statusIsLive.toggle(); playSoftHaptic() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, max(12, safeBottomInset()))
        }
        .scrollIndicators(.never)
        .background(Color.clear)
    }

    private func drawerRow(title: String, isHighlighted: Bool = false, leadingIcon: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let leading = leadingIcon {
                Image(systemName: leading).font(.system(size: 14, weight: .semibold)).foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8))
            }
            Text(title).foregroundStyle(fgPrimary(colorScheme, alphaDark: 0.8)).padding(.vertical, 12)
            Spacer()
        }
        .padding(.horizontal, 12)
        .background { isHighlighted ? AnyView(surfaceBackground(RoundedRectangle(cornerRadius: 16, style: .continuous))) : AnyView(Color.clear) }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(isHighlighted ? borderStroke(colorScheme) : Color.clear, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(isHighlighted ? highlightFace(colorScheme) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func selectSection(_ name: String) {
        // no-op for now; keep UX
        playSoftHaptic(); animateDrawer(to: 0)
    }

    private func newChat() {
        let initialMsg = Msg(id: UUID(), text: "新しいチャットを開始しました。質問を入力してください。", isUser: false)
        let thread = ChatThread(id: UUID(), title: placeholderTitle, messages: [initialMsg], updatedAt: Date())
        threads.insert(thread, at: 0)
        currentThreadID = thread.id
        messages = thread.messages
        animateDrawer(to: 0)
        playSoftHaptic()
        saveThreadsDebounced()
    }

    private func filteredThreads() -> [ChatThread] {
        let q = drawerSearchDebounced.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = threads.sorted { $0.updatedAt > $1.updatedAt }
        guard !q.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(q) } }
    }

    private func selectThread(_ id: UUID) {
        guard let t = threads.first(where: { $0.id == id }) else { return }
        currentThreadID = id
        messages = t.messages
        animateDrawer(to: 0)
        playSoftHaptic()
    }

    // MARK: - Gestures

    private func edgeDragGesture(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let startX = value.startLocation.x
                let dx = value.translation.width
                let dy = value.translation.height
                let isHorizontal = abs(dx) > abs(dy) * 1.15
                #if canImport(UIKit)
                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                #else
                let isPad = false
                #endif
                let allowedStartX: CGFloat = isPad ? 32 : 24
                let isOpeningAttempt = (drawerProgress == 0) && (startX <= allowedStartX)
                let isClosingAttempt = (drawerProgress > 0)
                guard (isOpeningAttempt || isClosingAttempt) && isHorizontal else { return }
                var next: CGFloat = drawerProgress
                if isOpeningAttempt { next = max(0, min(dx / drawerWidth, 1)) }
                else { next = max(0, min((drawerProgress * drawerWidth + dx) / drawerWidth, 1)) }
                drawerProgress = next
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let isHorizontal = abs(dx) > abs(dy) * 1.15
                guard isHorizontal else { return }
                let predicted = value.predictedEndTranslation.width
                let velocityX = (predicted - value.translation.width) * 10
                let shouldOpen: Bool
                if abs(velocityX) > 420 { shouldOpen = velocityX > 0 } else { shouldOpen = drawerProgress >= 0.30 }
                animateDrawer(to: shouldOpen ? 1 : 0)
            }
    }

    private func animateDrawer(to target: CGFloat) {
        if target >= 0.999 { dismissKeyboard(); inputFocused = false }
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.1)
        withAnimation(animation) { drawerProgress = max(0, min(target, 1)) }
        let nowOpen = drawerProgress >= 0.999
        let nowClosed = drawerProgress <= 0.001
        if nowOpen != lastHapticStateOpen { playSoftHaptic(); lastHapticStateOpen = nowOpen }
        else if nowClosed && lastHapticStateOpen { playSoftHaptic(); lastHapticStateOpen = false }
    }

    private func playSoftHaptic() {
        #if canImport(UIKit)
        let gen = UIImpactFeedbackGenerator(style: .soft)
        gen.prepare(); gen.impactOccurred()
        #endif
    }

    // MARK: - Tokens

    private func fgPrimary(_ scheme: ColorScheme, alphaDark: Double = 0.8) -> Color { scheme == .dark ? Color.white.opacity(alphaDark) : Color(red: 0.067, green: 0.067, blue: 0.067) }
    private func borderStroke(_ scheme: ColorScheme) -> Color { (scheme == .dark ? Color.white : Color.black).opacity(scheme == .dark ? 0.12 : 0.10) }
    private func surfaceSolid(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.118) : Color(red: 0.949, green: 0.949, blue: 0.969) }

    private func surfaceBackground<S: InsettableShape>(_ shape: S) -> some View {
        Group {
            if reduceTransparency { shape.fill(surfaceSolid(colorScheme)) }
            else { shape.fill(Color.clear).background(.ultraThinMaterial, in: shape) }
        }
    }

    @ViewBuilder private func chipGlassCircle() -> some View {
        if #available(iOS 18.0, *), !reduceTransparency {
            Color.clear.glassEffect(.regular.tint(Color.accentColor.opacity(0.12)).interactive(), in: .circle)
        } else { surfaceBackground(Circle()) }
    }

    @ViewBuilder private func glassCapsule(tintOpacity: Double = 0.14) -> some View {
        if #available(iOS 18.0, *), !reduceTransparency {
            Color.clear.glassEffect(.regular.tint(Color.accentColor.opacity(tintOpacity)).interactive(), in: .capsule)
        } else {
            Capsule().fill(Color.clear).background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func highlightFace(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.118, opacity: 0.08) : Color(red: 0.949, green: 0.949, blue: 0.969, opacity: 0.08)
    }

    // MARK: - Utilities

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

    // MARK: - Notifications

    private func requestNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    private func shouldNotify() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState != .active
        #else
        return true
        #endif
    }

    private func postLLMNotification(title: String, body: String) {
        guard shouldNotify() else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                center.add(request)
            default: break
            }
        }
    }

    // MARK: - Photos & OCR

    private func handlePhotoItemChange(_ newItem: PhotosPickerItem?) {
        guard let item = newItem else { return }
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                    pickedImage = ui
                    await recognizeText(in: ui)
                }
            } catch {
                ocrErrorMessage = "写真の読み込みに失敗しました"
            }
        }
    }

    @MainActor private func recognizeText(in image: UIImage) {
        isRunningOCR = true
        defer { isRunningOCR = false }
        guard let cg = image.cgImage else { return }
        let request = VNRecognizeTextRequest { req, _ in
            let text = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
            self.inputText += (self.inputText.isEmpty ? "" : "\n") + text
        }
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { ocrErrorMessage = "OCRに失敗しました" }
    }

    // MARK: - Web

    private func safeSearchURL(_ query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !q.isEmpty else { return nil }
        return URL(string: "https://search.brave.com/search?q=\(q)")
    }
}

// MARK: - Small UI helpers

private struct ProgressPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .foregroundStyle(Color.white)
    }
}

private struct AlertMessage: Identifiable { let id = UUID(); let message: String }

// Subtle animated backdrop to feed Liquid Glass refraction
private struct GlassBackdropLayer: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince1970
            let p = t.truncatingRemainder(dividingBy: 16) / 16
            ZStack {
                AngularGradient(
                    gradient: Gradient(colors: [Color.cyan, Color.blue, Color.purple, Color.pink, Color.orange, Color.yellow, Color.cyan]),
                    center: .center,
                    angle: .degrees(360 * p)
                ).blur(radius: 36)
                LinearGradient(colors: [Color.white.opacity(0.10), Color.black.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing).blendMode(.overlay)
                RadialGradient(colors: [Color.white.opacity(0.22), .clear], center: .init(x: 0.35 + 0.20 * sin(p * .pi * 2), y: 0.65 + 0.20 * cos(p * .pi * 2)), startRadius: 10, endRadius: 260).blendMode(.softLight)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - UIKit wrappers

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        // Future: config.entersReaderIfAvailable = false (default)
        let vc = SFSafariViewController(url: url, configuration: config)
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    var onPick: (URL) -> Void
    init(types: [UTType], onPick: @escaping (URL) -> Void) { self.types = types; self.onPick = onPick }
    func makeCoordinator() -> Coord { Coord(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { guard let u = urls.first else { return }; onPick(u) }
    }
}

// MARK: - Connection Settings Sheet

private struct ConnectionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var baseURLText: String
    var onSave: (String) -> Void
    var onPing: () -> Void
    @Binding var currentProbe: String
    @Binding var isProbing: Bool

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Base URL")) {
                    TextField("https://...", text: $baseURLText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                }
                if !currentProbe.isEmpty {
                    Section(header: Text("接続テスト結果")) {
                        ScrollView { Text(currentProbe).font(.footnote).textSelection(.enabled) }
                            .frame(maxHeight: 180)
                    }
                }
            }
            .navigationTitle("接続設定")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(isProbing ? "テスト中…" : "接続テスト") { onPing() }.disabled(isProbing)
                        Button("保存") { onSave(baseURLText); dismiss() }
                    }
                }
            }
        }
    }
}

// MARK: - Temporary Chat Sheet (non-persistent)

struct TemporaryChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var messages: [Msg] = [ .init(id: UUID(), text: "一時チャットを開始しました。ログには保存されません。", isUser: false) ]
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    private func fgPrimary(_ scheme: ColorScheme, alphaDark: Double = 0.8) -> Color { return scheme == .dark ? Color.white.opacity(alphaDark) : Color(red: 0.067, green: 0.067, blue: 0.067) }

    private func addMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(Msg(id: UUID(), text: trimmed, isUser: true))
        inputText = ""
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(messages) { msg in
                                HStack {
                                    if msg.isUser {
                                        Spacer()
                                        Text(msg.text)
                                            .padding(10)
                                            .background(Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.15))
                                            .foregroundColor(fgPrimary(colorScheme))
                                            .clipShape(RoundedRectangle(cornerRadius: 18))
                                    } else {
                                        Text(msg.text)
                                            .padding(10)
                                            .background(Color.secondary.opacity(colorScheme == .dark ? 0.25 : 0.10))
                                            .foregroundColor(fgPrimary(colorScheme))
                                            .clipShape(RoundedRectangle(cornerRadius: 18))
                                        Spacer()
                                    }
                                }
                                .id(msg.id)
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                    .onChange(of: messages.count) { _ in if let last = messages.last { DispatchQueue.main.async { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } } }
                }
                Divider()
                HStack {
                    TextField("メッセージを入力", text: $inputText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(colorScheme == .dark ? 0.25 : 0.10)))
                        .focused($inputFocused)
                    Button { addMessage() } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.15).clipShape(Circle()))
                    }.buttonStyle(.plain)
                }
                .padding()
            }
            .navigationTitle("一時チャット")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("閉じる") { dismiss() } } }
        }
    }
}

// MARK: - Preview

#Preview("iPhone 15 Pro – Light & Dark") {
    Group {
        ContentView().environment(\.colorScheme, .light)
        ContentView().environment(\.colorScheme, .dark)
    }
    .previewDevice("iPhone 17 Pro Max")
}

