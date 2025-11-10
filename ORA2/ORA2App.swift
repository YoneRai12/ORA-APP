//
//  ORA2App.swift
//  ORA Mobile
//
//  Created by VIBE-STACK on 2025/09/08.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
import SwiftData

// TEMP: Minimal stub to unblock build if the real UniversalScaffoldView isn't compiling or not in target.
private struct UniversalScaffoldView: View {
    var body: some View {
        Text("Boot")
            .padding()
    }
}

@main
struct ORA2App: App {
    // 後で復活
    // @StateObject private var session = AuthSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
            // .environmentObject(session) // 後で復活
            // .modelContainer(for: [Conversation.self, Message.self, AppSettings.self]) // 後で復活
            #if canImport(GoogleSignIn)
            .onOpenURL { url in
                _ = GIDSignIn.sharedInstance.handle(url)
            }
            #endif
        }
    }
}

#if canImport(UIKit)
#if canImport(GoogleSignIn)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}
#endif
#endif
