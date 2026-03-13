import SwiftUI
import WebKit

public enum HostedWKWebViewLoad {
    case request(URLRequest)
    case htmlString(String, baseURL: URL?)
    case fileURL(URL, allowingReadAccessTo: URL)
}

public struct HostedWKWebViewSpec {
    public enum DataStorePolicy {
        case persistent
        case nonPersistent
    }

    public struct URLSchemeHandlerRegistration {
        public let scheme: String
        public let handler: WKURLSchemeHandler

        public init(scheme: String, handler: WKURLSchemeHandler) {
            self.scheme = scheme
            self.handler = handler
        }
    }

    public struct ScriptMessageHandlerRegistration {
        public let name: String
        public let handler: WKScriptMessageHandler

        public init(name: String, handler: WKScriptMessageHandler) {
            self.name = name
            self.handler = handler
        }
    }

    public var dataStorePolicy: DataStorePolicy = .persistent
    public var schemeHandlers: [URLSchemeHandlerRegistration] = []
    public var scriptMessageHandlers: [ScriptMessageHandlerRegistration] = []
    public var makeConfiguration: (() -> WKWebViewConfiguration)?
    public var makeWebView: ((WKWebViewConfiguration) -> WKWebView)?
    public var configure: ((WKWebView) -> Void)?
    public var initialLoad: HostedWKWebViewLoad?
    public var teardown: ((WKWebView) -> Void)?

    public init(
        dataStorePolicy: DataStorePolicy = .persistent,
        schemeHandlers: [URLSchemeHandlerRegistration] = [],
        scriptMessageHandlers: [ScriptMessageHandlerRegistration] = [],
        makeConfiguration: (() -> WKWebViewConfiguration)? = nil,
        makeWebView: ((WKWebViewConfiguration) -> WKWebView)? = nil,
        configure: ((WKWebView) -> Void)? = nil,
        initialLoad: HostedWKWebViewLoad? = nil,
        teardown: ((WKWebView) -> Void)? = nil
    ) {
        self.dataStorePolicy = dataStorePolicy
        self.schemeHandlers = schemeHandlers
        self.scriptMessageHandlers = scriptMessageHandlers
        self.makeConfiguration = makeConfiguration
        self.makeWebView = makeWebView
        self.configure = configure
        self.initialLoad = initialLoad
        self.teardown = teardown
    }
}

public enum WKWebViewHost {
    public static func build(spec: HostedWKWebViewSpec) -> WKWebView {
        let configuration = makeConfiguration(for: spec)
        let webView = spec.makeWebView?(configuration) ?? WKWebView(frame: .zero, configuration: configuration)
        attach(webView, spec: spec)
        return webView
    }

    public static func attach(_ webView: WKWebView, spec: HostedWKWebViewSpec) {
        registerScriptMessageHandlers(for: spec, on: webView)
        spec.configure?(webView)

        if let initialLoad = spec.initialLoad {
            load(initialLoad, into: webView)
        }
    }

    public static func dismantle(_ webView: WKWebView, spec: HostedWKWebViewSpec) {
        for registration in spec.scriptMessageHandlers {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: registration.name)
        }
        spec.teardown?(webView)
    }

    private static func makeConfiguration(for spec: HostedWKWebViewSpec) -> WKWebViewConfiguration {
        let configuration = spec.makeConfiguration?() ?? WKWebViewConfiguration()

        if spec.makeConfiguration == nil {
            configuration.websiteDataStore = {
                switch spec.dataStorePolicy {
                case .persistent:
                    return .default()
                case .nonPersistent:
                    return .nonPersistent()
                }
            }()
        }

        for registration in spec.schemeHandlers {
            configuration.setURLSchemeHandler(registration.handler, forURLScheme: registration.scheme)
        }

        return configuration
    }

    private static func registerScriptMessageHandlers(for spec: HostedWKWebViewSpec, on webView: WKWebView) {
        for registration in spec.scriptMessageHandlers {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: registration.name)
            webView.configuration.userContentController.add(registration.handler, name: registration.name)
        }
    }

    private static func load(_ load: HostedWKWebViewLoad, into webView: WKWebView) {
        switch load {
        case .request(let request):
            webView.load(request)
        case .htmlString(let html, let baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        case .fileURL(let fileURL, let readAccessURL):
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }
    }
}

public struct HostedWKWebView: NSViewRepresentable {
    public final class Coordinator {
        let spec: HostedWKWebViewSpec

        init(spec: HostedWKWebViewSpec) {
            self.spec = spec
        }
    }

    public let spec: HostedWKWebViewSpec
    public var update: ((WKWebView) -> Void)?

    public init(spec: HostedWKWebViewSpec, update: ((WKWebView) -> Void)? = nil) {
        self.spec = spec
        self.update = update
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(spec: spec)
    }

    public func makeNSView(context: Context) -> WKWebView {
        WKWebViewHost.build(spec: spec)
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        update?(nsView)
    }

    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        WKWebViewHost.dismantle(nsView, spec: coordinator.spec)
    }
}
