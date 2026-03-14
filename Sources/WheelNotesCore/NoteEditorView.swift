import AppKit
import SwiftUI
import WebKit
import WheelSupport

public struct NoteEditorView: View {
    let bridge: NoteEditorBridge

    public init(bridge: NoteEditorBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        HostedWKWebView(spec: spec)
    }

    private var spec: HostedWKWebViewSpec {
        HostedWKWebViewSpec(
            dataStorePolicy: .nonPersistent,
            scriptMessageHandlers: [
                .init(name: bridge.messageHandlerName, handler: bridge),
            ],
            makeWebView: { configuration in
                FocusFriendlyNoteEditorWebView(frame: .zero, configuration: configuration)
            },
            configure: { webView in
                webView.setValue(false, forKey: "drawsBackground")
                bridge.attach(to: webView)
            },
            initialLoad: initialLoad,
            teardown: { _ in
                bridge.detach()
            }
        )
    }

    private var initialLoad: HostedWKWebViewLoad {
        if let editorURL = NoteEditorResources.editorHTMLURL(),
           let directoryURL = NoteEditorResources.editorDirectoryURL() {
            return .fileURL(editorURL, allowingReadAccessTo: directoryURL)
        }

        return .htmlString(
            """
            <html>
              <body style="font-family: -apple-system; padding: 16px;">
                Note editor resources are missing. Build the note editor bundle to enable editing.
              </body>
            </html>
            """,
            baseURL: nil
        )
    }
}

private final class FocusFriendlyNoteEditorWebView: WKWebView {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
