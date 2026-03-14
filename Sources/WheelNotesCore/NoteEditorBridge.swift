import AppKit
import Foundation
import WebKit
import WheelSupport

@MainActor
public final class NoteEditorBridge: QueuedScriptBridge {
    public var onReady: (() -> Void)?
    public var onDocumentChanged: ((NoteDocument) -> Void)?
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

    public func loadDocumentIfNeeded(_ document: NoteDocument, force: Bool = false) {
        guard let fingerprint = fingerprint(for: document),
              force || fingerprint != lastDocumentFingerprint else {
            return
        }

        lastDocumentFingerprint = fingerprint
        sendCommand("loadDocument", payload: DocumentPayload(document: document.root))
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
            guard let document = decodeDocument(payload) else {
                onEditorError?("Editor sent an invalid document payload.")
                return
            }
            lastDocumentFingerprint = fingerprint(for: document)
            onDocumentChanged?(document)
        case "editorError":
            onEditorError?(payload["message"] as? String ?? "Unknown editor error")
        default:
            break
        }
    }

    public override func reportBridgeError(_ message: String) {
        onEditorError?(message)
    }

    private func decodeDocument(_ payload: [String: Any]) -> NoteDocument? {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let payload = try JSONDecoder().decode(DocumentPayload.self, from: data)
            return NoteDocument(root: payload.document)
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
    let document: [String: AnyCodable]
}

private struct SourcePayload: Codable {
    let source: NotePageSource
}

private struct EmptyPayload: Codable {}
