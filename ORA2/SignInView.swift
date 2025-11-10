import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

struct SignInView: View {
    @EnvironmentObject var session: AuthSession
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var presenter: UIViewController?
    @State private var configured: Bool = false

    // 診断用フラグ（GoogleSignIn がリンクされているかをコンパイル時に判定）
    private var googleSignInLinked: Bool {
        #if canImport(GoogleSignIn)
        true
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.02).ignoresSafeArea()

            VStack(spacing: 20) {
                Text("ORA にサインイン")
                    .font(.largeTitle.bold())

                // 診断（必要なら非表示にしてOK）
                diagnostics

                Button {
                    Task { await signIn() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "g.circle")
                        Text(loading ? "Signing in..." : "Sign in with Google")
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || !googleSignInLinked)

                if let msg = errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)
                }

                #if DEBUG
                // 開発用スキップ（DEBUG ビルドのみ表示）
                VStack(spacing: 8) {
                    Button {
                        devBypass()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                            Text("Dev Skip（サインインをスキップ）")
                                .fontWeight(.semibold)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: 280)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Text("開発用ダミーサインイン。Releaseでは表示されません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                #endif
            }
            .padding(.horizontal, 16)
        }
        // 1) UIViewControllerRepresentable で確実に presenter を保持
        .background(ControllerFinder(controller: $presenter))
        // 2) フォールバック: onAppear でも presenter を試行取得
        .onAppear {
            if presenter == nil {
                presenter = findTopMostViewController()
            }
        }
        // 3) 起動時に一度 configure 実行（clientID 未設定だとUIが出ない）
        .task {
            if !configured {
                session.configure()
                configured = true
            }
        }
    }

    // 簡易診断ビュー
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(googleSignInLinked ? .green : .red).frame(width: 8, height: 8)
                Text("GoogleSignIn linked: \(googleSignInLinked ? "YES" : "NO")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if canImport(GoogleSignIn)
            let hasConfig = (GIDSignIn.sharedInstance.configuration != nil)
            HStack {
                Circle().fill(hasConfig ? .green : .orange).frame(width: 8, height: 8)
                Text("GID configuration: \(hasConfig ? "SET" : "MISSING")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
            HStack {
                Circle().fill(presenter == nil ? .orange : .green).frame(width: 8, height: 8)
                Text("Presenter: \(presenter == nil ? "nil" : "OK")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @MainActor
    private func signIn() async {
        #if canImport(UIKit)
        guard googleSignInLinked else {
            errorMessage = "GoogleSignIn パッケージがアプリにリンクされていません。Xcode の Package Dependencies で Add to Target を確認してください。"
            print("[SignIn] GoogleSignIn not linked to target.")
            return
        }
        // presenter を最終確認（両経路で取れない場合の保険）
        let vc = presenter ?? findTopMostViewController()
        guard let vc else {
            errorMessage = "Presenter not found. Please try again."
            print("[SignIn] presenter == nil")
            return
        }

        loading = true
        // clientID 未設定だと UI が出ないことがあるため保険で再設定
        session.configure()

        await session.signIn(presenting: vc)
        loading = false
        #endif
    }

    #if DEBUG
    @MainActor
    private func devBypass() {
        // ダミーユーザーで強制サインイン
        let dummy = AuthSession.GoogleUser(
            id: "dev-\(UUID().uuidString.prefix(8))",
            name: "Dev User",
            email: "dev@example.com",
            avatarURL: nil
        )
        session.state = .signedIn(user: dummy)
        print("Dev bypass: signed in as \(dummy.email)")
    }
    #endif
}

// 現在の UIViewController を安全に取得するための不可視ブリッジ
private struct ControllerFinder: UIViewControllerRepresentable {
    @Binding var controller: UIViewController?

    func makeUIViewController(context: Context) -> FinderVC {
        FinderVC(onUpdate: { [weak contextCoordinator = context.coordinator] vc in
            contextCoordinator?.update(vc: vc)
        })
    }
    func updateUIViewController(_ uiViewController: FinderVC, context: Context) {}

    final class FinderVC: UIViewController {
        private let onUpdate: (UIViewController) -> Void
        init(onUpdate: @escaping (UIViewController) -> Void) {
            self.onUpdate = onUpdate
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onUpdate(self)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        private let parent: ControllerFinder
        init(parent: ControllerFinder) { self.parent = parent }
        func update(vc: UIViewController) {
            if parent.controller !== vc {
                parent.controller = vc
            }
        }
    }
}

// 追加のフォールバック取得（keyWindow 経由）
@MainActor
private func findTopMostViewController(_ base: UIViewController? = nil) -> UIViewController? {
    #if canImport(UIKit)
    let baseVC: UIViewController? = {
        if let base { return base }
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.compactMap { $0 as? UIWindowScene }.first
        let keyWindow = windowScene?.windows.first { $0.isKeyWindow }
        return keyWindow?.rootViewController
    }()

    func topVC(from root: UIViewController?) -> UIViewController? {
        guard let root = root else { return nil }
        if let nav = root as? UINavigationController {
            return topVC(from: nav.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topVC(from: tab.selectedViewController)
        }
        if let presented = root.presentedViewController {
            return topVC(from: presented)
        }
        return root
    }
    return topVC(from: baseVC)
    #else
    return nil
    #endif
}
