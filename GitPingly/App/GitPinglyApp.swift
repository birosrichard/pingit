import AppKit
import SwiftUI

@main
struct GitPinglyApp: App {
    var body: some Scene {
        MenuBarExtra("GitPingly", systemImage: "bell.badge") {
            Button("Quit GitPingly") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
