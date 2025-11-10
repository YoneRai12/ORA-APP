// 全文差し替え。前の機能は維持しつつ、楽観的描画とレイアウト安定化を追加しています。
import SwiftUI
import SwiftData
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(FluidGlassKit)
import FluidGlassKit
#endif
import UserNotifications

private let moveFromTrailing: AnyTransition =
    .move(edge: Edge.trailing).combined(with: .opacity)
private let moveFromLeading: AnyTransition =
    .move(edge: Edge.leading).combined(with: .opacity)

// 一時的に上部ブラー帯を無効化
private let showTopOverlayBlur: Bool = false

struct ConversationDetailView: View {
    @EnvironmentObject var session: AuthSession
    @Environment(\.modelContext) private var context
    let conversation: Conversation

    @Query private var settingsList: [AppSettings]
    @State private var inputText: String = ""
    @State private var isSending: Bool = false

    // Web検索（MCP）使用トグル
    @State private var useWebSearch: Bool = false

    // 思考レベル（＝temperature マッピング）
    @State private var thinkLevel: ThinkLevel = .med

    // ChatService は状態監視しないため State ではなく固定インスタンス
    private let chatService = ChatService()

    // SwiftData からの実データ
    @Query private var messages: [Message]

    // 楽観的描画用のステージング
    @State private var stagedMessages: [Message] = []

    // 送信後にキーボードを閉じるためのフォーカス管理
    @FocusState private var inputFocused: Bool
    @State private var isToolRunning: Bool = false

    // 通知の前面表示用デリゲート（前面通知は不要になったため使用しないが保持）
    @State private var notifDelegate = ForegroundNotificationDelegate()

    #if canImport(ActivityKit)
    @State private var liveActivity: Activity<ChatActivityAttributes>? = nil
    #endif

    init(conversation: Conversation) {
        self.conversation = conversation
        let convID = conversation.id
        let sortDescriptors: [SortDescriptor<Message>] = [
            SortDescriptor(\Message.createdAt, order: .forward)
        ]
        self._messages = Query(
            filter: #Predicate<Message> { $0.conversationID == convID },
            sort: sortDescriptors
        )
    }

    // Query + Staged をマージして描画（重複IDは排除）
    private var mergedMessages: [Message] {
        var map: [UUID: Message] = [:]
        for m in messages { map[m.id] = m }
        for s in stagedMessages { map[s.id] = s }
        return map.values.sorted(by: { $0.createdAt < $1.createdAt })
    }

    // Query 側が更新されたら、staged から重複を除去（反映済みのものを掃除）
    private var queryMessageIDs: [UUID] { messages.map { $0.id } }

    var body: some View {
        Group {
            switch session.state {
            case .signedIn:
                signedInContent
            default:
                SignInView()
            }
        }
        .onChange(of: queryMessageIDs) { _, newIDs in
            // SwiftData に反映されたメッセージは staged から除去
            stagedMessages.removeAll { newIDs.contains($0.id) }
        }
    }

    private var signedInContent: some View {
        mainContent
            .navigationTitle(conversation.title.isEmpty ? "NEWchat" : conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            #if canImport(FluidGlassKit)
            .toolbarBackground(Color.clear, for: .navigationBar)
            #else
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            #endif
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .background(Color(.systemBackground).ignoresSafeArea())
            .onAppear {
                print("[Chat] View appeared. convID=\(conversation.id) messages=\(messages.count)")
                applySettingsToService()
                setupNotifications()
            }
            .onChange(of: settingsFingerprint) { _, _ in
                applySettingsToService()
            }
            .onChange(of: thinkLevel) { _, newValue in
                chatService.updateConfig(
                    wsURL: chatService.wsURL,
                    httpURL: chatService.httpURL,
                    think: newValue,
                    googleAPIKey: chatService.googleAPIKey,
                    googleCSEID: chatService.googleCSEID
                )
                persistThinkLevel(newValue)
            }
            // 左上ボタンでドロワー開閉（通知を送る → RootGateView が受けて開く）
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        NotificationCenter.default.post(name: .init("ora.toggleDrawer"), object: nil)
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("メニューを開く")
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomBar(
                    inputText: $inputText,
                    thinkLevel: $thinkLevel,
                    useWebSearch: $useWebSearch,
                    isToolRunning: isToolRunning,
                    onSend: { msg in
                        print("[Chat] onSend tapped. text=\(msg)")
                        inputFocused = false
                        dismissKeyboard()
                        inputText = msg
                        sendMessage()
                    },
                    onMic: { }
                )
            }
    }

    // 分割したメインビュー（メッセージリストのみスクロール）
    private var mainContent: some View {
        VStack(spacing: 0) {
            // 簡易診断：件数が 0 のままなら保存/取得どちらかが詰まっている
            Text("msgs: \(mergedMessages.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            MessagesListView(conversationID: conversation.id, messages: mergedMessages)
                .background(Color(.systemBackground))
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    inputFocused = false
                    dismissKeyboard()
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func setupNotifications() {
        Notify.requestAuthorization()
    }

    private func applySettingsToService() {
        let wsBase = settingsList.first?.wsURL ?? ""
        let httpBase = settingsList.first?.httpURL ?? ""
        let ws = wsBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppConst.defaultWS : wsBase
        let http = httpBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppConst.defaultHTTP : httpBase
        let think = settingsList.first?.thinkLevel ?? .med
        let gKey = settingsList.first?.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gCx  = settingsList.first?.googleCSEID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if thinkLevel != think {
            thinkLevel = think
        }
        chatService.updateConfig(wsURL: ws, httpURL: http, think: think, googleAPIKey: gKey, googleCSEID: gCx)
    }

    private func persistThinkLevel(_ level: ThinkLevel) {
        guard let settings = settingsList.first else { return }
        if settings.thinkLevel != level {
            settings.thinkLevel = level
            try? context.save()
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else {
            inputFocused = false
            dismissKeyboard()
            return
        }

        let store = ConversationStore.shared
        let cid = conversation.id
        if messages.isEmpty || conversation.title.isEmpty || conversation.title == "NEWchat" {
            store.reset(for: cid)
        }

        isSending = true
        isToolRunning = useWebSearch

        inputFocused = false
        dismissKeyboard()

        // 1) ユーザーメッセージを即時に楽観的描画へ追加
        let userMsg = Message(id: UUID(), conversationID: conversation.id, role: .user, text: text, createdAt: .now)
        stagedMessages.append(userMsg)

        // 1') SwiftData に保存（失敗してもUIは出る）
        do {
            context.insert(userMsg)
            conversation.updatedAt = .now
            try context.save()
            print("[Chat] Saved user message: \(userMsg.id)")
        } catch {
            print("[Chat][ERROR] Failed to save user message: \(error)")
        }

        // 送信直後に最下部へ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .init("ora.scrollToBottom"), object: conversation.id)
        }

        // 入力欄をクリア
        inputText = ""

        // 1'') タイトル自動生成（初回のみ／未設定またはNEWchat時）— フォールバックを必ず行う
        let currentTitle = (conversation.title as String?) ?? ""
        if currentTitle.isEmpty || currentTitle == "NEWchat" {
            let snapshot = text
            Task.detached { [cid = conversation.id] in
                let generated = await TitleService.generateTitle(from: snapshot)
                await MainActor.run {
                    if conversation.id == cid {
                        let safe = generated.trimmingCharacters(in: .whitespacesAndNewlines)
                        conversation.title = safe.isEmpty ? deriveTitleFallback(from: snapshot, reply: "") : safe
                        conversation.updatedAt = .now
                        try? context.save()
                    }
                }
            }
        }

        Task {
            chatService.updateConfig(
                wsURL: chatService.wsURL,
                httpURL: chatService.httpURL,
                think: thinkLevel,
                googleAPIKey: chatService.googleAPIKey,
                googleCSEID: chatService.googleCSEID
            )

            // 履歴初期化（未初期化の場合）
            if store.history(for: cid).isEmpty {
                let seeded = mergedMessages // ここは merged を利用（楽観的分も含む）
                    .sorted(by: { $0.createdAt < $1.createdAt })
                    .map { m -> ChatMessage in
                        switch m.role {
                        case .user: return .user(m.text)
                        case .assistant: return .assistant(m.text)
                        case .system: return .system(m.text)
                        }
                    }
                for m in seeded {
                    store.append(m, to: cid)
                }
            }
            store.append(.user(text), to: cid)

            #if canImport(ActivityKit)
            if #available(iOS 16.1, *) {
                liveActivity = ChatActivityController.start(title: conversation.title.isEmpty ? "NEWchat" : conversation.title)
                ChatActivityController.update(liveActivity, phase: .sending, progress: 0.1, hint: "送信中")
                if useWebSearch {
                    ChatActivityController.update(liveActivity, phase: .searching, progress: 0.4, hint: "検索中")
                }
            }
            #endif

            do {
                let reply = try await chatService.chatTurn(
                    conversationID: cid,
                    history: store.history(for: cid),
                    enableTools: useWebSearch
                )

                #if canImport(ActivityKit)
                if #available(iOS 16.1, *) {
                    ChatActivityController.update(liveActivity, phase: .generating, progress: 0.8, hint: "生成中")
                }
                #endif

                // 2) 返答を即時に楽観的描画へ追加
                let assistantMsg = Message(
                    id: UUID(),
                    conversationID: conversation.id,
                    role: .assistant,
                    text: reply,
                    createdAt: .now
                )
                await MainActor.run {
                    stagedMessages.append(assistantMsg)
                }

                // 2') SwiftData に保存（フォールバックも堅く）
                try await MainActor.run {
                    do {
                        context.insert(assistantMsg)
                        let t = (conversation.title as String?) ?? ""
                        if (t.isEmpty || t == "NEWchat"),
                           messages.first(where: { $0.role == .assistant }) == nil {
                            let newTitle = deriveTitleFallback(from: text, reply: reply)
                            conversation.title = newTitle.isEmpty ? "NEWchat" : newTitle
                        }
                        conversation.updatedAt = .now
                        try context.save()
                        print("[Chat] Saved assistant message: \(assistantMsg.id)")
                    } catch {
                        print("[Chat][ERROR] Failed to save assistant message: \(error)")
                    }
                }

                // 返信受信時にも最下部へ
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: .init("ora.scrollToBottom"), object: conversation.id)
                }

                // 通知（バックグラウンド時のみ）
                Notify.replyArrived(body: reply)

                #if canImport(ActivityKit)
                if #available(iOS 16.1, *) {
                    ChatActivityController.end(liveActivity, successText: reply)
                }
                #endif
            } catch {
                // エラーも即時描画のうえ保存
                let assistantMsg = Message(
                    id: UUID(),
                    conversationID: conversation.id,
                    role: .assistant,
                    text: "エラーが発生しました: \(error.localizedDescription)",
                    createdAt: .now
                )
                await MainActor.run {
                    stagedMessages.append(assistantMsg)
                }
                await MainActor.run {
                    do {
                        context.insert(assistantMsg)
                        conversation.updatedAt = .now
                        try context.save()
                        print("[Chat] Saved error message: \(assistantMsg.id)")
                    } catch {
                        print("[Chat][ERROR] Failed to save error message: \(assistantMsg.id)")
                    }
                }

                #if canImport(ActivityKit)
                if #available(iOS 16.1, *) {
                    ChatActivityController.end(liveActivity, successText: "エラー")
                }
                #endif
            }

            await MainActor.run {
                isSending = false
                isToolRunning = false
            }
        }
    }

    // 明示的にキーボードを閉じる（UIKit 経由）
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func deriveTitleFallback(from user: String, reply: String) -> String {
        let base = user.isEmpty ? reply : user
        let s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLen = 16
        if s.isEmpty { return "NEWchat" }
        return s.count <= maxLen ? s : String(s.prefix(maxLen)) + "…"
    }
}

// 設定の“指紋”を作って1本監視に集約
private extension ConversationDetailView {
    var settingsFingerprint: String {
        guard let s = settingsList.first else { return "nil" }
        return [
            s.wsURL,
            s.httpURL,
            String(describing: s.thinkLevel),
            s.googleAPIKey,
            s.googleCSEID
        ].joined(separator: "§")
    }
}

// MARK: - Messages List

private struct MessagesListView: View {
    let conversationID: UUID
    let messages: [Message]

    private var messageIDs: [UUID] { messages.map { $0.id } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages, id: \.id) { message in
                            MessageRowView(message: message)
                                .id(message.id)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                }
                .overlay(alignment: .top) {
                    if showTopOverlayBlur {
                        VisualEffectBlur(style: .systemUltraThinMaterialDark)
                            .frame(height: 20)
                            .mask(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.20), .clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .overlay(
                                LinearGradient(
                                    colors: [.black.opacity(0.12), .clear, .clear, .black.opacity(0.12)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .allowsHitTesting(false)
                    }
                }
                .background(Color(.systemBackground))
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: messageIDs) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollToBottom(proxy: proxy, animated: true)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .init("ora.scrollToBottom"))) { note in
                    guard let cid = note.object as? UUID, cid == conversationID else { return }
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = messages.last?.id else { return }
        withAnimation(animated ? .easeOut(duration: 0.22) : nil) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

private struct ToolRunningIndicator: View {
    let isRunning: Bool

    var body: some View {
        Group {
            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("検索中…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                EmptyView()
            }
        }
    }
}

// ユーザーは右寄せ・枠付き。アシスタントは枠なしでフル幅。ダブルタップでコピー。
private struct MessageRowView: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.text)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundColor(.primary)
                        .onTapGesture(count: 2) {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = message.text
                            #endif
                        }
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = message.text
                        #endif
                    }
            }
        case .system:
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// 追加: UIKitのブラーをSwiftUIで使う薄いラッパー
fileprivate struct VisualEffectBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style
    fileprivate func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    fileprivate func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

// 入力バー背景のビネット（横・縦の両方向）
private struct EdgeVignette: View {
    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.18)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.12),
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .blendMode(BlendMode.plusDarker)
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
    }
}

// 入力バー背後に敷く“屈折の餌”
private struct GlassBackdropLayer: View {
    @State private var t: CGFloat = 0
    var body: some View {
        TimelineView(.animation) { ctx in
            let p = CGFloat((ctx.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 6)) / 6)
            ZStack {
                AngularGradient(
                    gradient: Gradient(colors: [.cyan, .blue, .purple, .pink, .orange, .yellow, .cyan]),
                    center: .center, angle: .degrees(360 * p)
                )
                .opacity(0.35)
                .blur(radius: 24)
                LinearGradient(colors: [.white.opacity(0.10), .black.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .blendMode(BlendMode.overlay)
                Rectangle()
                    .fill(.clear)
                    .overlay(
                        RadialGradient(colors: [.white.opacity(0.18), .clear],
                                       center: .init(x: 0.3 + 0.2 * sin(p*2*3.1415),
                                                     y: 0.7 + 0.2 * cos(p*2*3.1415)),
                                       startRadius: 10, endRadius: 220)
                    )
                    .blendMode(BlendMode.softLight)
            }
            .ignoresSafeArea(edges: .bottom)
            .transition(.opacity)
        }
        .frame(height: 140)
    }
}

// MARK: - 会話ストア（このファイル内に簡易実装）

private final class ConversationStore {
    static let shared = ConversationStore()
    private init() {}

    private var histories: [UUID: [ChatMessage]] = [:]
    private let lock = NSLock()

    func history(for id: UUID) -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return histories[id] ?? []
    }

    func reset(for id: UUID) {
        lock.lock()
        histories[id] = []
        lock.unlock()
    }

    func append(_ message: ChatMessage, to id: UUID) {
        lock.lock(); defer { lock.unlock() }
        var h = histories[id] ?? []
        h.append(message)
        histories[id] = h
        print("[\(id)] \(message.role.rawValue): \(message.content.prefix(120))")
    }
}

// MARK: - メッセージDTO（このファイル内に簡易実装）

private struct ChatToolCall: Codable, Hashable {
    let id: String
    let name: String
    let argumentsJSON: String
}

private struct ChatMessage: Codable, Hashable {
    enum Role: String, Codable { case system, user, assistant, tool }
    var role: Role
    var content: String
    var toolCallId: String? = nil
    var toolCalls: [ChatToolCall]? = nil
}

private extension ChatMessage {
    static func system(_ t: String) -> Self { .init(role: .system, content: t) }
    static func user(_ t: String) -> Self { .init(role: .user, content: t) }
    static func assistant(_ t: String) -> Self { .init(role: .assistant, content: t) }
    static func assistantWithToolCalls(_ t: String, _ calls: [ChatToolCall]) -> Self {
        .init(role: .assistant, content: t, toolCallId: nil, toolCalls: calls)
    }
    static func tool(content: String, toolCallId: String) -> Self {
        .init(role: .tool, content: content, toolCallId: toolCallId)
    }
}

// MARK: - MCP ブリッジ（Google CSE → DuckDuckGo フォールバック）

private enum MCP {
    enum Error: Swift.Error { case timeout, invalidURL, http(Int), decode }

    static func run(name: String,
                    argsJSON: String,
                    timeoutSeconds: TimeInterval = 15,
                    googleAPIKey: String? = nil,
                    googleCSEID: String? = nil) async throws -> String {
        return try await withTimeout(seconds: timeoutSeconds) {
            if name != "web_search" {
                return "[\(name)] \(argsJSON)"
            }
            let query = (try? extractQuery(from: argsJSON)) ?? argsJSON

            // Google CSE が設定されていれば優先
            let key = (googleAPIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cx  = (googleCSEID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !cx.isEmpty {
                if let s = try? await googleCSESummary(query: query, apiKey: key, cx: cx), !s.isEmpty {
                    return s
                }
            }

            // フォールバック: DuckDuckGo
            let summary = try await duckDuckGoSummary(query: query)
            if summary.isEmpty {
                return "検索結果が見つかりませんでした（\(query)）。"
            }
            return summary
        }
    }

    private static func googleCSESummary(query: String, apiKey: String, cx: String) async throws -> String {
        var comps = URLComponents(string: "https://www.googleapis.com/customsearch/v1")!
        comps.queryItems = [
            .init(name: "key", value: apiKey),
            .init(name: "cx", value: cx),
            .init(name: "q", value: query)
        ]
        guard let url = comps.url else { throw Error.invalidURL }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct CSE: Decodable {
            struct Item: Decodable { let title: String; let link: String; let snippet: String? }
            let items: [Item]?
        }
        let cse = try JSONDecoder().decode(CSE.self, from: data)
        let lines = (cse.items ?? []).prefix(5).map { "・\($0.title) — \($0.link)\n\($0.snippet ?? "")" }
        return lines.isEmpty ? "" : lines.joined(separator: "\n\n")
    }

    private static func duckDuckGoSummary(query: String) async throws -> String {
        var comps = URLComponents(string: "https://api.duckduckgo.com/")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "format", value: "json"),
            .init(name: "no_redirect", value: "1"),
            .init(name: "no_html", value: "1"),
            .init(name: "skip_disambig", value: "1")
        ]
        guard let url = comps.url else { throw Error.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Error.invalidURL }
        guard (200..<300).contains(http.statusCode) else { throw Error.http(http.statusCode) }

        struct DDG: Decodable {
            struct Topic: Decodable { let Text: String?; let FirstURL: String? }
            let AbstractText: String?
            let AbstractURL: String?
            let Heading: String?
            let RelatedTopics: [Topic]?
        }
        let ddg = try JSONDecoder().decode(DDG.self, from: data)

        var lines: [String] = []
        if let heading = ddg.Heading, !heading.isEmpty {
            lines.append("【\(heading)】")
        }
        if let abs = ddg.AbstractText, !abs.isEmpty {
            lines.append(abs)
        }
        if let topics = ddg.RelatedTopics, !topics.isEmpty {
            let picks = topics.prefix(3)
            for t in picks {
                guard let text = t.Text, !text.isEmpty else { continue }
                if let url = t.FirstURL {
                    lines.append("・\(text) — \(url)")
                } else {
                    lines.append("・\(text)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func extractQuery(from json: String) throws -> String {
        struct Args: Decodable { let query: String? }
        let data = Data(json.utf8)
        let args = try JSONDecoder().decode(Args.self, from: data)
        return args.query ?? json
    }
}

private func withTimeout<T>(seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MCP.Error.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - ChatService（ツール実行ループ付き・このファイル内に簡易実装）

private final class ChatService {
    private(set) var wsURL: String = ""
    private(set) var httpURL: String = ""
    private(set) var think: ThinkLevel = .med

    // Google CSE 設定（ConversationDetailView から注入）
    private(set) var googleAPIKey: String = ""
    private(set) var googleCSEID: String = ""

    private let defaultModel = "openai/gpt-oss-20b"
    private let defaultMaxTokens: Int = -1
    private let defaultStream: Bool = false

    private let defaultSystem =
    """
    日本語で自然に応答するアシスタント。フォーマット指定は不要。

    【しりとり（LLMのみで実施）】
    - ユーザーが「しりとり」等と言ったら開始。状態は会話履歴だけで追跡。
    - 各ターンは日本語の単語を1つ返す。直前の語尾に続かない入力なら短く指摘。
    - 「ん」で終わったら負けを宣言。ユーザーが「終了」「やめる」で中止。

    【ツール利用】
    - クライアントからツール定義が渡り、かつ必要なときのみ tool_calls を返す。
    - 擬似フォーマット（<|channel|>…）は使わない。引数や擬似記号を通常メッセージに出さない。
    - クライアントの検索トグルがOFFのときは一切ツールを使わない。
    """

    func updateConfig(wsURL: String, httpURL: String, think: ThinkLevel, googleAPIKey: String, googleCSEID: String) {
        self.wsURL = wsURL
        self.httpURL = httpURL
        self.think = think
               self.googleAPIKey = googleAPIKey
        self.googleCSEID = googleCSEID
    }

    private func temperatureForThink(_ think: ThinkLevel) -> Double {
        switch think {
        case .low:  return 0.2
        case .med:  return 0.7
        case .high: return 1.0
        }
    }

    func chatTurn(conversationID: UUID,
                  history: [ChatMessage],
                  enableTools: Bool,
                  timeoutSeconds: TimeInterval = 30) async throws -> String {
        var hist: [ChatMessage] = history
        if hist.first?.role != .system {
            hist.insert(.system(defaultSystem), at: 0)
        }

        var lastToolSignature: String? = nil
        var loopCount = 0
        let maxToolIterations = 4

        while true {
            loopCount += 1
            if loopCount > maxToolIterations {
                ConversationStore.shared.append(.assistant("（内部安全装置）ツール呼び出しが連続したため停止しました。"), to: conversationID)
                return "内部保護により停止。もう一度試すか、検索OFFで再実行してください。"
            }

            let res: OpenAIChatCompletionsResponse = try await requestChat(
                messages: hist,
                enableTools: enableTools,
                timeoutSeconds: timeoutSeconds
            )

            guard let firstChoice: OpenAIChatCompletionsResponse.Choice = res.choices.first else {
                throw ChatError.emptyReply
            }
            let msg: OpenAIChatCompletionsResponse.Msg = firstChoice.message

            if !(msg.tool_calls ?? []).isEmpty {
                let calls: [ChatToolCall] = (msg.tool_calls ?? []).map {
                    ChatToolCall(id: $0.id ?? UUID().uuidString, name: $0.function.name, argumentsJSON: $0.function.arguments)
                }
                ConversationStore.shared.append(.assistant(msg.content ?? ""), to: conversationID)
                ConversationStore.shared.append(.assistantWithToolCalls("", calls), to: conversationID)

                for call in msg.tool_calls ?? [] {
                    let name = call.function.name
                    let args = call.function.arguments
                    let id = call.id ?? UUID().uuidString

                    let sig = "\(name)::\(args)"
                    if sig == lastToolSignature {
                        ConversationStore.shared.append(.tool(content: "（同一要求を検出: \(name)）結果を再利用します。", toolCallId: id), to: conversationID)
                    } else {
                        do {
                            let out = try await MCP.run(
                                name: name,
                                argsJSON: args,
                                timeoutSeconds: 15,
                                googleAPIKey: googleAPIKey,
                                googleCSEID: googleCSEID
                            )
                            ConversationStore.shared.append(.tool(content: out, toolCallId: id), to: conversationID)
                        } catch MCP.Error.timeout {
                            let out = "ツール実行がタイムアウトしました。後でもう一度お試しください。"
                            ConversationStore.shared.append(.tool(content: out, toolCallId: id), to: conversationID)
                        } catch {
                            let out = "ツール実行に失敗: \(error.localizedDescription)"
                            ConversationStore.shared.append(.tool(content: out, toolCallId: id), to: conversationID)
                        }
                        lastToolSignature = sig
                    }
                }

                hist = ConversationStore.shared.history(for: conversationID)
                if hist.first?.role != .system {
                    hist.insert(.system(defaultSystem), at: 0)
                }
                continue
            }

            let content = msg.content ?? ""
            ConversationStore.shared.append(.assistant(content), to: conversationID)
            return content
        }
    }

    // MARK: - HTTP Client

    private func requestChat(messages: [ChatMessage],
                             enableTools: Bool,
                             timeoutSeconds: TimeInterval) async throws -> OpenAIChatCompletionsResponse {
        let endpoint = buildCompletionsURL(from: httpURL)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var reqMsgs: [OpenAIChatCompletionsRequest.Message] = []
        reqMsgs.reserveCapacity(messages.count)
        for msg in messages {
            switch msg.role {
            case .tool:
                let m = OpenAIChatCompletionsRequest.Message(
                    role: "tool",
                    content: msg.content,
                    tool_call_id: msg.toolCallId,
                    tool_calls: nil
                )
                reqMsgs.append(m)
            case .assistant:
                let calls: [OpenAIChatCompletionsRequest.Message.ToolCall]? = msg.toolCalls?.map { tc in
                    OpenAIChatCompletionsRequest.Message.ToolCall(
                        id: tc.id,
                        type: "function",
                        function: .init(name: tc.name, arguments: tc.argumentsJSON)
                    )
                }
                let m = OpenAIChatCompletionsRequest.Message(
                    role: "assistant",
                    content: msg.content,
                    tool_call_id: nil,
                    tool_calls: calls
                )
                reqMsgs.append(m)
            case .user:
                let m = OpenAIChatCompletionsRequest.Message(
                    role: "user",
                    content: msg.content,
                    tool_call_id: nil,
                    tool_calls: nil
                )
                reqMsgs.append(m)
            case .system:
                let m = OpenAIChatCompletionsRequest.Message(
                    role: "system",
                    content: msg.content,
                    tool_call_id: nil,
                    tool_calls: nil
                )
                reqMsgs.append(m)
            }
        }

        let tools: [OpenAIChatCompletionsRequest.Tool]? = enableTools ? Tools.definitions : nil

        let payload = OpenAIChatCompletionsRequest(
            model: defaultModel,
            messages: reqMsgs,
            temperature: temperatureForThink(think),
            max_tokens: defaultMaxTokens,
            stream: defaultStream,
            tools: tools,
            tool_choice: (enableTools ? .auto : .none)
        )

        req.httpBody = try JSONEncoder().encode(payload)

        let session = URLSession(configuration: .default)
        let (data, resp) = try await withTimeout(seconds: timeoutSeconds) {
            try await session.data(for: req)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatError.server(status: http.statusCode, body: body)
        }
        return try JSONDecoder().decode(OpenAIChatCompletionsResponse.self, from: data)
    }

    private func buildCompletionsURL(from raw: String) -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) ||
           (s.hasPrefix("'") && s.hasSuffix("'")) ||
           (s.hasPrefix("`") && s.hasSuffix("`")) {
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: " ", with: "")

        if s.isEmpty { s = AppConst.defaultHTTP }
        if !s.contains("://") {
            if s.hasPrefix("localhost:") || s.hasPrefix("127.0.0.1") {
                s = "http://\(s)"
            } else {
                s = "https://\(s)"
            }
        }

        guard var comps = URLComponents(string: s), comps.host != nil else {
            return URL(string: AppConst.defaultHTTP + "/v1/chat/completions")!
        }

        let lower = comps.path.lowercased()
        if lower.hasSuffix("/v1/chat/completions") {
            return comps.url ?? URL(string: AppConst.defaultHTTP + "/v1/chat/completions")!
        }
        if lower.hasSuffix("/v1/chat") {
            comps.path += "/completions"
        } else if lower.hasSuffix("/chat/completions") {
            if !lower.contains("/v1/") {
                comps.path = comps.path.replacingOccurrences(of: "/chat/completions", with: "/v1/chat/completions")
            }
        } else if lower.hasSuffix("/chat") {
            let newPath = comps.path + "/completions"
            comps.path = newPath.contains("/v1/") ? newPath : "/v1" + newPath
        } else {
            let normalized = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
            comps.path = normalized + "/v1/chat/completions"
        }
        return comps.url ?? URL(string: AppConst.defaultHTTP + "/v1/chat/completions")!
    }

    // MARK: - DTOs

    struct OpenAIChatCompletionsRequest: Codable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool

        let tools: [Tool]?
        let tool_choice: ToolChoice?

        struct Message: Codable {
            let role: String
            let content: String?
            let tool_call_id: String?
            let tool_calls: [ToolCall]?

            struct ToolCall: Codable {
                let id: String
                let type: String
                let function: FunctionCall
            }

            struct FunctionCall: Codable {
                let name: String
                let arguments: String
            }
        }

        struct Tool: Codable {
            let type: String
            let function: Function

            struct Function: Codable {
                let name: String
                let description: String?
                let parameters: JSONSchema
            }
        }

        enum ToolChoice: Codable {
            case auto
            case none
            case function(name: String)

            func encode(to encoder: Encoder) throws {
                var s = encoder.singleValueContainer()
                switch self {
                case .auto:
                    try s.encode("auto")
                case .none:
                    try s.encode("none")
                case .function(let name):
                    struct FnChoice: Encodable {
                        let type: String = "function"
                        let function: Name
                        struct Name: Encodable { let name: String }
                    }
                    try s.encode(FnChoice(function: .init(name: name)))
                }
            }
            init(from decoder: Decoder) throws { self = .auto }
        }

        struct JSONSchema: Codable {
            let type: String
            let properties: [String: Property]?
            let required: [String]?

            struct Property: Codable {
                let type: String
                let description: String?
            }
        }
    }

    struct OpenAIChatCompletionsResponse: Codable {
        struct Choice: Codable {
            let index: Int?
            let message: Msg
            let finish_reason: String?
        }
        struct Msg: Codable {
            let role: String
            let content: String?
            let tool_calls: [ToolCall]?
        }
        struct ToolCall: Codable {
            let id: String?
            let type: String?
            let function: FunctionCall
        }
        struct FunctionCall: Codable {
            let name: String
            let arguments: String
        }
        let id: String?
        let object: String?
        let created: Int?
        let model: String?
        let choices: [Choice]
    }

    // MARK: - Errors

    private enum ChatError: LocalizedError {
        case invalidResponse
        case server(status: Int, body: String)
        case emptyReply
    }
}

private enum Tools {
    static let definitions: [ChatService.OpenAIChatCompletionsRequest.Tool] = [
        .init(
            type: "function",
            function: .init(
                name: "web_search",
                description: "Perform a web search and return relevant results for the given query.",
                parameters: .init(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "Search query string")
                    ],
                    required: ["query"]
                )
            )
        )
    ]
}

// MARK: - Local Notify shim + バックグラウンドのみ通知

private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .list]
    }
}

private enum Notify {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    static func replyArrived(title: String = "ORA", body: String) {
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .active {
            // 前面では通知を出さない
            return
        }
        #endif
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let t = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        let r = UNNotificationRequest(identifier: "ora.reply.\(UUID().uuidString)", content: c, trigger: t)
        UNUserNotificationCenter.current().add(r)
    }
}

// MARK: - Local Live Activities shim

#if canImport(ActivityKit)
@available(iOS 16.1, *)
private struct ChatActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        var progress: Double
        var hint: String
    }
    enum Phase: String, Codable, Hashable { case sending, searching, generating, done }
    var conversationTitle: String
}

@available(iOS 16.1, *)
private enum ChatActivityController {
    static func start(title: String) -> Activity<ChatActivityAttributes>? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let attr = ChatActivityAttributes(conversationTitle: title)
        let content = ChatActivityAttributes.ContentState(phase: .sending, progress: 0.1, hint: "送信中")
        return try? Activity.request(attributes: attr, contentState: content)
    }
    static func update(_ a: Activity<ChatActivityAttributes>?, phase: ChatActivityAttributes.Phase, progress: Double, hint: String) {
        guard let a else { return }
        Task { await a.update(using: .init(phase: phase, progress: min(max(progress, 0.0), 1.0), hint: hint)) }
    }
    static func end(_ a: Activity<ChatActivityAttributes>?, successText: String) {
        guard let a else { return }
        Task { await a.end(using: .init(phase: .done, progress: 1.0, hint: "完了")) }
    }
}
#endif

// MARK: - ORA Input Options Panel

private struct ORAInputOptionsPanel: View {
    @Binding var thinkLevel: ThinkLevel
    @Binding var useWebSearch: Bool
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("入力オプション", systemImage: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("思考レベル")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Picker("", selection: $thinkLevel) {
                    ForEach(ThinkLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .background {
                    RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                }
            }

            Toggle(isOn: $useWebSearch) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text("Web検索（MCP）")
                }
                .font(.system(size: 15, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(.accentColor) // 白つぶれ回避
        }
        .padding(14)
        .background {
            let r = RoundedRectangle(cornerRadius: 18, style: .continuous)
            r.fill(.clear).oraLiquid(in: r)
        }
        .shadow(radius: 20, y: 8)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())          // ヒット領域拡大
        .highPriorityGesture(DragGesture()) // 横ドラッグを優先
    }
}

private struct BottomBar: View {
    @Binding var inputText: String
    @Binding var thinkLevel: ThinkLevel
    @Binding var useWebSearch: Bool
    let isToolRunning: Bool
    let onSend: (String) -> Void
    let onMic: () -> Void

    @State private var showOptions: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // 1) ツール実行インジケータ
            ToolRunningIndicator(isRunning: isToolRunning)
                .padding(.top, isToolRunning ? 4 : 0)
                .padding(.horizontal, 16)

            // 2) オプションカードを“入力欄の上”に配置
            if showOptions {
                ThinkLevelOverlay(
                    thinkLevel: $thinkLevel,
                    useWebSearch: $useWebSearch,
                    isPresented: $showOptions
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
                .padding(.horizontal, 16)
            }

            // 3) 入力バー（Liquid）
            LiquidInputField(
                text: $inputText,
                onSend: { triggerSend() },
                onMic: onMic,
                // リキッドグラスのポップアウト用に必要な Binding を渡す
                thinkLevel: $thinkLevel,
                useWebSearch: $useWebSearch,
                showOptions: $showOptions,
                onOptionsTap: { withAnimation(.spring) { showOptions.toggle() } }
            )
            .padding(.horizontal, 12)
            .zIndex(0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showOptions)
        .background(Color.clear.ignoresSafeArea(edges: .bottom))
    }

    private func triggerSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
    }
}

