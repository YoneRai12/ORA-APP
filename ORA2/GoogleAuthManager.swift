//
//  GoogleAuthManager.swift
//  ORA Mobile
//
//  Created by SwiftUI Assistant on 2025/09/10.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

#if canImport(GoogleSignIn)
final class GoogleAuthManager: ObservableObject {
    static let shared = GoogleAuthManager()
    @Published var user: GIDGoogleUser? = GIDSignIn.sharedInstance.currentUser

    // GoogleService-Info.plist が無い場合のフォールバック
    private let fallbackClientID = "165330457431-ht05ic78ubthlpkacba271qs8sc1vt6j.apps.googleusercontent.com"

    func signIn() async throws {
        #if canImport(UIKit)
        guard let scene = await UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            throw NSError(domain: "NoRootVC", code: -1)
        }
        let config = GIDConfiguration(clientID: fallbackClientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: root, configuration: config)
        await MainActor.run { self.user = result.user }
        #else
        throw NSError(domain: "UnsupportedPlatform", code: -2)
        #endif
    }

    func restoreIfPossible() async {
        if let restored = try? await GIDSignIn.sharedInstance.restorePreviousSignIn() {
            await MainActor.run { self.user = restored }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        user = nil
    }

    var accessToken: String? { user?.accessToken.tokenString }
    var idToken: String? { user?.idToken?.tokenString }
}
#endif

// シンプルなサインインボタン（存在する環境のみ表示）
struct GoogleSignInButton: View {
    var body: some View {
        #if canImport(GoogleSignIn)
        Button {
            Task { try? await GoogleAuthManager.shared.signIn() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "g.circle.fill")
                Text("Googleでログイン")
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        #else
        EmptyView()
        #endif
    }
}
