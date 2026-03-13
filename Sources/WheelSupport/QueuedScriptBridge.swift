import Foundation
import WebKit

@MainActor
open class QueuedScriptBridge: NSObject, WKScriptMessageHandler {
    public let messageHandlerName: String

    private let javaScriptReceiver: String
    private weak var webView: WKWebView?
    private var isReady = false
    private var queuedScripts: [String] = []

    public init(messageHandlerName: String, javaScriptReceiver: String) {
        self.messageHandlerName = messageHandlerName
        self.javaScriptReceiver = javaScriptReceiver
    }

    public func attach(to webView: WKWebView) {
        self.webView = webView
    }

    open func detach() {
        webView = nil
        isReady = false
        queuedScripts.removeAll()
    }

    public func sendCommand<Payload: Encodable>(_ command: String, payload: Payload) {
        guard let webView else { return }

        do {
            let data = try JSONEncoder().encode(payload)
            let json = String(decoding: data, as: UTF8.self)
            let escaped = JavaScriptEscaper.escape(json)
            let script = "window.\(javaScriptReceiver).receiveCommand('\(command)', JSON.parse('\(escaped)'));"

            if isReady {
                webView.evaluateJavaScript(script, completionHandler: nil)
            } else {
                queuedScripts.append(script)
            }
        } catch {
            reportBridgeError("Failed to encode \(messageHandlerName) payload: \(error.localizedDescription)")
        }
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == messageHandlerName,
              let body = message.body as? [String: Any] else {
            return
        }
        handleMessage(named: message.name, body: body)
    }

    public func handleMessage(_ body: [String: Any]) {
        handleMessage(named: messageHandlerName, body: body)
    }

    public func handleMessage(named name: String, body: [String: Any]) {
        guard name == messageHandlerName,
              let type = body["type"] as? String else {
            return
        }

        let payload = body["payload"] as? [String: Any] ?? [:]
        if type == "ready" {
            isReady = true
            flushQueuedScripts()
            bridgeDidBecomeReady()
            return
        }

        didReceiveMessage(type: type, payload: payload)
    }

    open func bridgeDidBecomeReady() {}

    open func didReceiveMessage(type: String, payload: [String: Any]) {}

    open func reportBridgeError(_ message: String) {}

    private func flushQueuedScripts() {
        guard let webView else { return }
        let scripts = queuedScripts
        queuedScripts.removeAll()
        for script in scripts {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}
