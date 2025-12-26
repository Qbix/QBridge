import Foundation
import WebKit

@objc public class QBridge: NSObject, WKScriptMessageHandler {
    // MARK: - Shared singleton
    @objc public static let shared: QBridge = {
        let instance = QBridge()
        return instance
    }()

    // MARK: - Properties
    @objc public var webView: WKWebView?    // keep this strong
    @objc public weak var extensionContext: NSExtensionContext?
    @objc public weak var presentingController: UIViewController? 
    public var configPath: String?

    // MARK: - Private init (prevent multiple)
    private override init() {
        super.init()
    }

    // MARK: - Attach once
    @objc public func attach(to webView: WKWebView, configPath: String? = nil) {
        guard self.webView !== webView else {
            QBridgeUtils.log("QBridge already attached to this WKWebView")
            return
        }
        self.webView = webView
        self.configPath = configPath
        webView.configuration.userContentController.add(self, name: "QBridge")
        QBridgeUtils.log("QBridge attached to WKWebView (configPath: \(configPath ?? "none"))")
    }

    // MARK: - WKScriptMessageHandler
    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        handleMessage(dict)
    }

    // MARK: - Message routing
    @objc public func handleMessage(_ msg: [String: Any]) {
        let service = msg["service"] as? String ?? ""
        let action = msg["action"] as? String ?? ""
        let args   = msg["args"]
        let cbid   = msg["callbackId"] as? String
        QBridgeRegistry.route(service: service, action: action, args: args, callbackId: cbid, bridge: self)
    }

    // MARK: - Send event to JS
    @objc public func sendEvent(_ callbackId: String, data: [String: Any], keepCallback: Bool = false) {
        guard let webView = self.webView else {
            QBridgeUtils.log("QBridge.sendEvent: webView is nil")
            return
        }

        var payload: [String: Any] = [
            "callbackId": callbackId,
            "data": data
        ]

        // Only include keepCallback if true — just like Cordova
        if keepCallback {
            payload["keepCallback"] = true
        }

        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: json, encoding: .utf8) else {
            QBridgeUtils.log("QBridge.sendEvent: JSON serialization failed")
            return
        }

        let script = "window.QBridge && QBridge.onNative(\(jsonStr))"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    @objc public func handleAppClipLaunch(url: URL) {
        QBridgeUtils.log("App Clip launched with URL: \(url.absoluteString)")

        guard let webView = self.webView else {
            QBridgeUtils.log("handleAppClipLaunch: webView is nil, retrying...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.handleAppClipLaunch(url: url)
            }
            return
        }

        let js = """
        window.QBridgeLaunchData = { url: '\(url.absoluteString)' };
        console.log('[QBridge] Set QBridgeLaunchData:', window.QBridgeLaunchData);
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    QBridgeUtils.log("Error setting QBridgeLaunchData JS: \(error)")
                } else {
                    QBridgeUtils.log("QBridgeLaunchData set successfully.")
                }
            }
        }
    }
}
