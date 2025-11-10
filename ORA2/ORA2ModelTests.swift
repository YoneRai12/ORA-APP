//
//  ORA2ModelTests.swift
//  ORA2Tests
//
//  Created by VIBE-STACK on 2025/09/08.
//

#if canImport(XCTest)

import XCTest
import SwiftData

#if canImport(ORA_Mobile)
@testable import ORA_Mobile
#elseif canImport(ORA2)
@testable import ORA2
#endif

final class ORA2ModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeInMemoryContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Conversation.self, Message.self, AppSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        return (container, context)
    }

    // MARK: - Tests

    func testSaveAndFetchModels() throws {
        let (_, context) = try makeInMemoryContainer()

        let settings = AppSettings(id: UUID(), wsURL: "wss://ws", httpURL: "https://http", thinkLevel: .med)
        context.insert(settings)

        let conv = Conversation(id: UUID(), title: "Test", createdAt: Date.now, updatedAt: Date.now)
        context.insert(conv)

        let m1 = Message(id: UUID(), conversationID: conv.id, role: .user, text: "hello", createdAt: Date.now)
        let m2 = Message(id: UUID(), conversationID: conv.id, role: .assistant, text: "world", createdAt: Date.now)
        context.insert(m1)
        context.insert(m2)

        try context.save()

        let convs = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(convs.count, 1)

        let msgs = try context.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(msgs.count, 2)

        let sets = try context.fetch(FetchDescriptor<AppSettings>())
        XCTAssertEqual(sets.count, 1)
    }

    func testFilterMessagesByConversationID_UsingCapturedUUID() throws {
        let (_, context) = try makeInMemoryContainer()

        // 会話A/Bを作成し、それぞれにメッセージを保存
        let convA = Conversation(id: UUID(), title: "A", createdAt: .now, updatedAt: .now)
        let convB = Conversation(id: UUID(), title: "B", createdAt: .now, updatedAt: .now)
        context.insert(convA)
        context.insert(convB)

        context.insert(Message(id: UUID(), conversationID: convA.id, role: .user, text: "A-1", createdAt: .now))
        context.insert(Message(id: UUID(), conversationID: convA.id, role: .assistant, text: "A-2", createdAt: .now))
        context.insert(Message(id: UUID(), conversationID: convB.id, role: .user, text: "B-1", createdAt: .now))

        try context.save()

        // ここが重要：#Predicate 内で会話ID(UUID)を先にキャプチャして使う
        let targetID = convA.id
        let fdA = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversationID == targetID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let msgsA = try context.fetch(fdA)
        XCTAssertEqual(msgsA.count, 2)
        XCTAssertTrue(msgsA.allSatisfy { $0.conversationID == targetID })

        let targetIDB = convB.id
        let fdB = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversationID == targetIDB }
        )
        let msgsB = try context.fetch(fdB)
        XCTAssertEqual(msgsB.count, 1)
        XCTAssertEqual(msgsB.first?.text, "B-1")
    }

    func testUpdateConversationTimestampOnNewMessage() throws {
        let (_, context) = try makeInMemoryContainer()

        var conv = Conversation(id: UUID(), title: "Time", createdAt: .now, updatedAt: .now)
        context.insert(conv)
        try context.save()

        let before = conv.updatedAt
        // 新規メッセージ（ユーザー）
        let msg = Message(id: UUID(), conversationID: conv.id, role: .user, text: "Hi", createdAt: .now)
        context.insert(msg)
        // 画面実装と同様、更新時刻を今に
        conv.updatedAt = .now

        try context.save()

        // フェッチして確認
        let convs = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(convs.count, 1)
        guard let fetched = convs.first else {
            return XCTFail("Conversation not found")
        }
        XCTAssertTrue(fetched.updatedAt >= before)
    }

    func testDeleteConversationAndRelatedMessagesManually() throws {
        let (_, context) = try makeInMemoryContainer()

        let conv = Conversation(id: UUID(), title: "DeleteTarget", createdAt: .now, updatedAt: .now)
        context.insert(conv)
        let m1 = Message(id: UUID(), conversationID: conv.id, role: .user, text: "X", createdAt: .now)
        let m2 = Message(id: UUID(), conversationID: conv.id, role: .assistant, text: "Y", createdAt: .now)
        context.insert(m1)
        context.insert(m2)
        try context.save()

        // 関連メッセージを先に削除（カスケードを自前で表現）
        let cid = conv.id
        let relatedFD = FetchDescriptor<Message>(predicate: #Predicate { $0.conversationID == cid })
        let related = try context.fetch(relatedFD)
        related.forEach { context.delete($0) }

        // 会話自体を削除
        context.delete(conv)
        try context.save()

        let leftMsgs = try context.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(leftMsgs.count, 0)

        let leftConvs = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(leftConvs.count, 0)
    }
}

#endif
