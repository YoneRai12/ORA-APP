//
//  AppConst.swift
//  ORA Mobile
//
//  Created by SwiftUI Assistant on 2025/09/08.
//

import Foundation

enum AppConst {
    // ngrok のベースURL（末尾スラあり/なし両対応）
    // ChatService 側で /v1/chat/completions を付けて利用します。
    static let defaultWS: String = "wss://380033854d6a.ngrok-free.app" // 使う場合は /ws などに拡張
    static let defaultHTTP: String = "https://380033854d6a.ngrok-free.app"

    // 設定画面フッターなどに表示する文言
    static let privacyText: String =
    """
    このアプリはチャット内容をローカルに保存します。接続先URLは設定から変更可能です。詳細はプライバシーポリシーをご確認ください。
    """
}
