import SwiftUI
import SwiftData

struct ChatListView: View {
    @EnvironmentObject var session: AuthSession
    @Environment(\.modelContext) private var context

    // 会話一覧（新しい更新が上）
    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    // NavigationStack のパス（会話IDのみを運ぶ軽量ルート）
    @State private var path: [Route] = []

    // Drawer からの選択（オプション）
    @Binding var selectedConversationID: UUID?

    // ルート定義
    private struct Route: Hashable {
        let conversationID: UUID
    }

    init(selectedConversationID: Binding<UUID?> = .constant(nil)) {
        self._selectedConversationID = selectedConversationID
    }

    var body: some View {
        Group {
            switch session.state {
            case .signedIn:
                NavigationStack(path: $path) {
                    content
                        .navigationTitle("チャット")
                        .navigationDestination(for: Route.self) { route in
                            if let conv = conversations.first(where: { $0.id == route.conversationID }) {
                                ConversationDetailView(conversation: conv)
                                    .environmentObject(session)
                            } else {
                                Text("会話が見つかりませんでした").foregroundStyle(.secondary)
                            }
                        }
                }
                .onChange(of: selectedConversationID) { _, newID in
                    guard let id = newID else { return }
                    // すでに表示中なら何もしない
                    if path.last?.conversationID == id { return }
                    // 目的の会話が存在するなら push
                    if conversations.contains(where: { $0.id == id }) {
                        path = [Route(conversationID: id)]
                    }
                }

            default:
                SignInView()
            }
        }
    }

    private var content: some View {
        List {
            Section {
                Button {
                    addConversationAndOpen()
                } label: {
                    Label("新規チャット", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
            }

            Section(header: Text("会話履歴")) {
                ForEach(conversations, id: \.id) { conv in
                    NavigationLink(value: Route(conversationID: conv.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conv.title.isEmpty ? "NEWchat" : conv.title)
                                .font(.headline)
                            Text(conv.updatedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addConversationAndOpen()
                } label: {
                    Label("新規チャット", systemImage: "plus")
                }
                .accessibilityLabel("新規チャット")
            }
        }
    }

    private func addConversationAndOpen() {
        let conv = Conversation(id: UUID(), title: "NEWchat", createdAt: .now, updatedAt: .now)
        context.insert(conv)
        try? context.save()
        path = [Route(conversationID: conv.id)]
        selectedConversationID = conv.id
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let conv = conversations[index]
            let cid = conv.id
            let fd = FetchDescriptor<Message>(predicate: #Predicate { $0.conversationID == cid })
            if let msgs = try? context.fetch(fd) {
                msgs.forEach { context.delete($0) }
            }
            context.delete(conv)
        }
        try? context.save()
    }
}

#Preview {
    NavigationStack {
        ChatListView()
    }
    .environmentObject(AuthSession())
    .modelContainer(for: [Conversation.self, Message.self, AppSettings.self], inMemory: true)
}
