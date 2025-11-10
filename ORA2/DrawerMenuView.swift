import SwiftUI
import SwiftData

struct DrawerMenuView: View {
    @Environment(\.modelContext) private var ctx
    @EnvironmentObject var router: ChatRouter
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("メニュー").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Button {
                let conv = Conversation(id: UUID(), title: "NEWchat", createdAt: .now, updatedAt: .now)
                ctx.insert(conv)
                try? ctx.save()
                router.selectedConversationID = conv.id
                onClose()
            } label: {
                Label("新規チャット", systemImage: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }

            Divider().opacity(0.4)

            if conversations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("履歴はまだありません").font(.subheadline.weight(.semibold))
                    Text("最初のメッセージ送信後、題名が自動生成されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(conversations) { conv in
                            Button {
                                router.selectedConversationID = conv.id
                                onClose()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "message.fill").opacity(0.7)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(conv.title.isEmpty ? "NEWchat" : conv.title)
                                            .font(.body.weight(.semibold))
                                            .lineLimit(1)
                                        Text(conv.updatedAt, style: .date)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                            }
                            Divider().opacity(0.15)
                        }
                    }
                }
            }
        }
        .background(LiquidGlassBackground())
        .padding(.top, 8)
    }
}
