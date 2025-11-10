import Foundation
import Combine   // ← 必須

final class ChatRouter: ObservableObject {
    // Conversation.id が UUID のため合わせる
    @Published var selectedConversationID: UUID? = nil
}

// 通知名はここに1カ所だけ定義
extension Notification.Name {
    static let selectConversation = Notification.Name("selectConversation")
}
