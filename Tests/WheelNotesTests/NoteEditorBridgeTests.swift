import Testing
@testable import WheelNotesCore

@Suite("NoteEditorBridge")
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
}
