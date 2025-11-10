//
//  SettingsView.swift
//  ORA Mobile
//
//  Created by VIBE-STACK on 2025/09/08.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]

    @State private var wsURL: String = ""
    @State private var httpURL: String = ""
    @State private var thinkLevel: ThinkLevel = .med

    @State private var googleAPIKey: String = ""
    @State private var googleCSEID: String = ""

    var body: some View {
        Form {
            Section(header: Text("接続設定")) {
                TextField("WebSocket URL", text: $wsURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("HTTP URL", text: $httpURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section(header: Text("思考レベル")) {
                Picker("レベル", selection: $thinkLevel) {
                    ForEach(ThinkLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section(header: Text("Google カスタム検索 (任意)")) {
                TextField("API Key", text: $googleAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("検索エンジンID (cx)", text: $googleCSEID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("未設定の場合は DuckDuckGo を使用します。").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("保存") {
                    save()
                }
            } footer: {
                Text(AppConst.privacyText)
            }
        }
        .navigationTitle("設定")
        .onAppear(perform: load)
    }

    private func load() {
        let current = settingsList.first
        wsURL = current?.wsURL ?? AppConst.defaultWS
        httpURL = current?.httpURL ?? AppConst.defaultHTTP
        thinkLevel = current?.thinkLevel ?? .med
        googleAPIKey = current?.googleAPIKey ?? ""
        googleCSEID = current?.googleCSEID ?? ""
        if current == nil {
            // 無ければ作成（念のため）
            let s = AppSettings(id: UUID(), wsURL: wsURL, httpURL: httpURL, thinkLevel: thinkLevel, googleAPIKey: googleAPIKey, googleCSEID: googleCSEID)
            context.insert(s)
            try? context.save()
        }
    }

    private func save() {
        let s: AppSettings
        if let existing = settingsList.first {
            s = existing
        } else {
            s = AppSettings(id: UUID(), wsURL: wsURL, httpURL: httpURL, thinkLevel: thinkLevel, googleAPIKey: googleAPIKey, googleCSEID: googleCSEID)
            context.insert(s)
        }
        s.wsURL = wsURL
        s.httpURL = httpURL
        s.thinkLevel = thinkLevel
        s.googleAPIKey = googleAPIKey
        s.googleCSEID = googleCSEID
        try? context.save()
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Conversation.self, Message.self, AppSettings.self], inMemory: true)
}
