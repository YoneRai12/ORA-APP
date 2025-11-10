import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

#if !canImport(GoogleSignIn)
#warning("GoogleSignIn is not linked to this app target. Add the package and enable Add to Target for your app. (Xcode > Project > Package Dependencies)")
#endif

@MainActor
final class AuthSession: ObservableObject {

    enum AuthState: Equatable {
        case unknown
        case signedOut
        case signedIn(user: GoogleUser)
    }

    struct GoogleUser: Equatable {
        let id: String
        let name: String
        let email: String
        let avatarURL: URL?
    }

    @Published var state: AuthState = .unknown

    // デフォルトの iOS 用 Client ID（保険）
    private let fallbackClientID = "165330457431-ht05ic78ubthlpkacba271qs8sc1vt6j.apps.googleusercontent.com"

    // 直近に適用した clientID（再設定の無駄を避ける）
    private var appliedClientID: String?

    // 現在のリンク状態（診断用）
    static var isGoogleSignInLinked: Bool {
        #if canImport(GoogleSignIn)
        return true
        #else
        return false
        #endif
    }

    // 起動時に呼ぶ（clientID を構成）
    func configure() {
        #if canImport(GoogleSignIn)
        // 優先順:
        // 1) GoogleService-Info.plist の CLIENT_ID
        // 2) Info.plist の GIDClientID
        // 3) fallbackClientID
        let clientIDFromGoogleService = (Bundle.main.object(forInfoDictionaryKey: "CLIENT_ID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientIDFromInfoPlist = (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidate = [
            clientIDFromGoogleService,
            clientIDFromInfoPlist,
            fallbackClientID
        ].compactMap { $0 }.first { !$0.isEmpty }

        guard let clientID = candidate, !clientID.isEmpty else {
            print("AuthSession.configure: Missing ClientID. Set Info.plist > GIDClientID or GoogleService-Info.plist > CLIENT_ID.")
            return
        }

        // 既に同じ clientID で構成済みならスキップ
        if appliedClientID == clientID, GIDSignIn.sharedInstance.configuration != nil {
            print("AuthSession.configure: Already configured with same clientID.")
            return
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        appliedClientID = clientID
        print("AuthSession.configure: GID configuration set. clientID=\(clientID.prefix(8))…")
        #else
        // ライブラリ未リンク時の明示ログ（UI 側にも診断を表示済み）
        print("AuthSession.configure: GoogleSignIn is NOT linked to the app target. Please Add to Target in Package Dependencies.")
        #endif
    }

    // 前回サインインの復元
    func restore() async {
        print("AuthSession.restore: begin. isLinked=\(Self.isGoogleSignInLinked)")
        #if canImport(GoogleSignIn)
        // 未設定対策
        if GIDSignIn.sharedInstance.configuration == nil { configure() }

        if GIDSignIn.sharedInstance.hasPreviousSignIn() {
            do {
                let result = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                let user = result.user
                let profile = user.profile
                let g = GoogleUser(
                    id: user.userID ?? "",
                    name: profile?.name ?? "",
                    email: profile?.email ?? "",
                    avatarURL: profile?.imageURL(withDimension: 96)
                )
                withAnimation(.easeInOut(duration: 0.2)) {
                    state = .signedIn(user: g)
                }
                print("AuthSession.restore: restored. email=\(g.email)")
            } catch {
                print("AuthSession.restore: failed -> \(error.localizedDescription)")
                withAnimation(.easeInOut(duration: 0.2)) {
                    state = .signedOut
                }
            }
        } else {
            print("AuthSession.restore: no previous sign-in.")
            withAnimation(.easeInOut(duration: 0.2)) {
                state = .signedOut
            }
        }
        #else
        print("AuthSession.restore: GoogleSignIn not available. Defaulting to signedOut.")
        withAnimation(.easeInOut(duration: 0.2)) {
            state = .signedOut
        }
        #endif
    }

    // サインイン
    #if canImport(UIKit)
    func signIn(presenting vc: UIViewController) async {
        #if canImport(GoogleSignIn)
        // 未設定対策
        if GIDSignIn.sharedInstance.configuration == nil { configure() }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: vc)
            let user = result.user
            let profile = user.profile
            let g = GoogleUser(
                id: user.userID ?? "",
                name: profile?.name ?? "",
                email: profile?.email ?? "",
                avatarURL: profile?.imageURL(withDimension: 96)
            )
            // ここで .signedIn に遷移 → RootGateView が ChatListView を表示 or 直行
            withAnimation(.easeInOut(duration: 0.2)) {
                state = .signedIn(user: g)
            }
            print("AuthSession.signIn: success. email=\(g.email)")
        } catch {
            print("AuthSession.signIn: failed -> \(error.localizedDescription)")
            withAnimation(.easeInOut(duration: 0.2)) {
                state = .signedOut
            }
        }
        #else
        print("AuthSession.signIn: GoogleSignIn not linked. Cannot present sign-in UI.")
        withAnimation(.easeInOut(duration: 0.2)) {
            state = .signedOut
        }
        #endif
    }
    #endif

    // サインアウト
    func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #else
        print("AuthSession.signOut: GoogleSignIn not linked (no-op).")
        #endif
        withAnimation(.easeInOut(duration: 0.2)) {
            state = .signedOut
        }
        print("AuthSession.signOut: state -> signedOut")
    }

    // 将来の API 呼び出し用トークン取得（スタブ）
    func currentAccessToken() -> String? {
        #if canImport(GoogleSignIn)
        // 例: GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString
        return nil
        #else
        return nil
        #endif
    }

    // MARK: - DEBUG helpers

    #if DEBUG
    /// 開発中にサインインをスキップしてチャット画面へ遷移するためのヘルパー
    func devForceSignIn(name: String = "Dev User", email: String = "dev@example.com") {
        let dummy = GoogleUser(id: "dev-\(UUID().uuidString.prefix(8))", name: name, email: email, avatarURL: nil)
        withAnimation(.easeInOut(duration: 0.2)) {
            state = .signedIn(user: dummy)
        }
        print("AuthSession.devForceSignIn: signed in as \(email)")
    }
    #endif
}

