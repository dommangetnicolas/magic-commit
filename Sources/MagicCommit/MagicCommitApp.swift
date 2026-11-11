import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, even when run as a bare binary (`swift run`).
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct MagicCommitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ProjectStore()

    init() {
        CLI.runIfRequested() // exits when a CLI command was given
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
        } label: {
            let count = store.attentionCount
            if count > 0 {
                Label("\(count)", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "wand.and.stars")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
