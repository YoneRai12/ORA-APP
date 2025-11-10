import SwiftUI
import SwiftData

struct RootGateView: View {
    @EnvironmentObject var session: AuthSession
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    @StateObject private var router = ChatRouter()
    @State private var drawerOpen = false

    var body: some View {
        switch session.state {
        case .unknown:
            ProgressView()
                .task {
                    session.configure()
                    await session.restore()
                }

        case .signedOut:
            SignInView()

        case .signedIn:
            DrawerHost(isOpen: $drawerOpen) {
                DrawerMenuView {
                    withAnimation(.spring) { drawerOpen = false }
                }
                .environmentObject(router)
            } content: {
                SignedInContent(
                    conversations: conversations,
                    selectedConversationID: router.selectedConversationID
                )
                .environmentObject(session)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(.spring) { drawerOpen.toggle() }
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                    }
                }
            }
            .environmentObject(router)
            // ConversationDetailView など子画面からの「開け」の通知を受ける
            .onReceive(NotificationCenter.default.publisher(for: .init("ora.toggleDrawer"))) { _ in
                withAnimation(.spring) { drawerOpen.toggle() }
            }
        }
    }
}

private struct SignedInContent: View {
    @Environment(\.modelContext) private var context
    let conversations: [Conversation]
    let selectedConversationID: UUID?

    var body: some View {
        if let conv = currentConversation() {
            ConversationDetailView(conversation: conv)
        } else {
            let conv = ensureConversation()
            ConversationDetailView(conversation: conv)
        }
    }

    private func currentConversation() -> Conversation? {
        if let id = selectedConversationID,
           let hit = conversations.first(where: { $0.id == id }) {
            return hit
        }
        return conversations.first
    }

    private func ensureConversation() -> Conversation {
        if let first = conversations.first {
            return first
        } else {
            let new = Conversation(id: UUID(), title: "NEWchat", createdAt: .now, updatedAt: .now)
            context.insert(new)
            try? context.save()
            return new
        }
    }
}
