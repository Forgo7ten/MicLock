import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController {

    init() {
        let hostingController = NSHostingController(
            rootView: AboutView()
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 380,
                height: 300
            ),
            styleMask: [
                .titled,
                .closable
            ],
            backing: .buffered,
            defer: false
        )

        window.title = "关于 MicLock"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()

        // About 不需要 resize / minimize。
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAbout() {
        guard let window else { return }

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        // LSUIElement App 没有普通 Dock 激活流程；显示独立窗口时主动激活，
        // 保证 About 窗口能获得焦点。
        NSApp.activate()
    }
}
