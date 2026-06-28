import SwiftUI
import AppKit
import AnvilUI

@main
struct AnvilAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup("anvil") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 520)
                .preferredColorScheme(.dark)
                .task { await model.start() }
                .onDisappear { model.stop() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}

/// Ensure a terminal-launched (`swift run`) process shows + foregrounds a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
