//
//  Models.swift
//  ORA Mobile
//
//  Created by VIBE-STACK on 2025/09/08.
//

import Foundation
import SwiftData

// 会話の役割
enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case system
}

// 思考レベル（例）
enum ThinkLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case med
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "低"
        case .med: return "中"
        case .high: return "高"
        }
    }
}

// 会話スレッド
@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// メッセージ
@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var role: MessageRole
    var text: String
    var createdAt: Date

    init(id: UUID, conversationID: UUID, role: MessageRole, text: String, createdAt: Date) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

// アプリ設定
@Model
final class AppSettings {
    @Attribute(.unique) var id: UUID
    var wsURL: String
    var httpURL: String
    var thinkLevel: ThinkLevel

    // Google CSE 用のキー（空文字で未設定）
    var googleAPIKey: String
    var googleCSEID: String

    init(id: UUID,
         wsURL: String,
         httpURL: String,
         thinkLevel: ThinkLevel,
         googleAPIKey: String = "",
         googleCSEID: String = "") {
        self.id = id
        self.wsURL = wsURL
        self.httpURL = httpURL
        self.thinkLevel = thinkLevel
        self.googleAPIKey = googleAPIKey
        self.googleCSEID = googleCSEID
    }
}
