import Foundation

enum TitleService {
    struct Payload: Codable { let text: String }
    struct Resp: Codable { let title: String }

    /// ユーザーの最初の発話などから短いタイトルを生成
    static func generateTitle(from text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "新しいチャット" }

        // TODO: あなたのエンドポイントに差し替え
        // 例: AppConst.defaultHTTP + "/api/title"
        var req = URLRequest(url: URL(string: AppConst.defaultHTTP + "/api/title")!)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Payload(text: String(trimmed.prefix(1000))))

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let res = try? JSONDecoder().decode(Resp.self, from: data) {
                let t = res.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        } catch {
            // ネットワーク/デコード失敗時はフォールバック
        }

        // フォールバック：先頭32文字を簡易タイトルに
        return String(trimmed.prefix(32))
    }
}
