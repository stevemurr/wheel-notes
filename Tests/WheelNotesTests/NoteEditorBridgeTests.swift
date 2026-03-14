import AppKit
import Testing
import WebKit
@testable import WheelNotesCore

@Suite("NoteEditorBridge", .serialized)
@MainActor
struct NoteEditorBridgeTests {
    @Test("Ready messages trigger the bridge callback")
    func readyCallback() {
        let bridge = NoteEditorBridge()
        var didBecomeReady = false
        bridge.onReady = { didBecomeReady = true }

        bridge.handleMessage(["type": "ready"])

        #expect(didBecomeReady)
    }

    @Test("Document changed messages decode tiptap document payloads")
    func decodesChangedDocument() {
        let bridge = NoteEditorBridge()
        var receivedText: String?
        bridge.onDocumentChanged = { document in
            receivedText = document.plainText()
        }

        bridge.handleMessage([
            "type": "documentChanged",
            "payload": [
                "document": [
                    "type": "doc",
                    "content": [
                        [
                            "type": "paragraph",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Hello from Tiptap",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])

        #expect(receivedText == "Hello from Tiptap")
    }

    @Test("Editor errors are forwarded")
    func forwardsEditorErrors() {
        let bridge = NoteEditorBridge()
        var message: String?
        bridge.onEditorError = { message = $0 }

        bridge.handleMessage([
            "type": "editorError",
            "payload": [
                "message": "boom",
            ],
        ])

        #expect(message == "boom")
    }

    @Test("Focusing the editor promotes the attached web view to first responder")
    func focusEditorPromotesAttachedWebView() async throws {
        _ = NSApplication.shared

        let bridge = NoteEditorBridge()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: WKWebViewConfiguration()
        )
        bridge.attach(to: webView)

        let contentView = NSView(frame: webView.frame)
        webView.frame = contentView.bounds
        contentView.addSubview(webView)

        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)

        bridge.focusEditor()
        try await Task.sleep(for: .milliseconds(50))

        #expect(window.firstResponder === webView)

        window.orderOut(nil)
    }
}
