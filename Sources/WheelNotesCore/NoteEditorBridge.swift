import AppKit
import Foundation
import WebKit
import WheelSupport

@MainActor
public final class NoteEditorBridge: QueuedScriptBridge {
    public var onReady: (() -> Void)?
    public var onDocumentChanged: ((UUID, NoteDocument) -> Void)?
    public var onEditorError: ((String) -> Void)?

    private var lastDocumentFingerprint: String?
    private var activeNoteID: UUID?

    public init() {
        super.init(messageHandlerName: "noteEditorBridge", javaScriptReceiver: "NoteEditor")
    }

    public override func detach() {
        super.detach()
        lastDocumentFingerprint = nil
        activeNoteID = nil
    }

    public func activate(noteID: UUID) {
        if activeNoteID != noteID {
            activeNoteID = noteID
            lastDocumentFingerprint = nil
        }
    }

    public func loadDocumentIfNeeded(noteID: UUID, document: NoteDocument, force: Bool = false) {
        guard let fingerprint = fingerprint(for: document),
              force || fingerprint != lastDocumentFingerprint else {
            return
        }

        lastDocumentFingerprint = fingerprint
        sendCommand("loadDocument", payload: DocumentPayload(noteID: noteID, document: document.root))
    }

    public func focusEditor() {
        requestNativeFocus()
        sendCommand("focusEditor", payload: EmptyPayload())
    }

    public func insertSourceBlock(_ source: NotePageSource) {
        sendCommand("insertSourceBlock", payload: SourcePayload(source: source))
    }

    public override func bridgeDidBecomeReady() {
        onReady?()
    }

    public override func didReceiveMessage(type: String, payload: [String: Any]) {
        switch type {
        case "documentChanged":
            guard let payload = decodeDocumentPayload(payload) else {
                onEditorError?("Editor sent an invalid document payload.")
                return
            }
            guard payload.noteID == activeNoteID else {
                return
            }

            let document = NoteDocument(root: payload.document)
            lastDocumentFingerprint = fingerprint(for: document)
            onDocumentChanged?(payload.noteID, document)
        case "editorError":
            onEditorError?(payload["message"] as? String ?? "Unknown editor error")
        default:
            break
        }
    }

    public override func reportBridgeError(_ message: String) {
        onEditorError?(message)
    }

    private func decodeDocumentPayload(_ payload: [String: Any]) -> DocumentPayload? {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return try JSONDecoder().decode(DocumentPayload.self, from: data)
        } catch {
            return nil
        }
    }

    private func fingerprint(for document: NoteDocument) -> String? {
        document.canonicalJSONString
    }

    private func requestNativeFocus() {
        NSApp.activate(ignoringOtherApps: true)

        guard let webView = attachedWebView else { return }
        focus(webView)

        if webView.window == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusAttachedWebViewIfNeeded()
            }
        }
    }

    private func focusAttachedWebViewIfNeeded() {
        guard let webView = attachedWebView else { return }
        focus(webView)
    }

    private func focus(_ webView: WKWebView) {
        guard let window = webView.window else { return }
        window.makeKeyAndOrderFront(nil)

        if window.firstResponder !== webView {
            _ = window.makeFirstResponder(webView)
        }
    }
}

private struct DocumentPayload: Codable {
    let noteID: UUID
    let document: [String: AnyCodable]
}

private struct SourcePayload: Codable {
    let source: NotePageSource
}

private struct EmptyPayload: Codable {}
