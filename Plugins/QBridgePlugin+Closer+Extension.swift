import UIKit

@objc public class QBridgePluginCloser: NSObject {
    @objc public static func close(_ controller: UIViewController?) {
        guard let controller = controller else { return }
        
        // Try to get extensionContext via KVC (works for any extension view controller)
        if let context = controller.value(forKey: "extensionContext") as? NSExtensionContext {
            context.completeRequest(returningItems: [] as [Any]?, completionHandler: nil)
        } else {
            // Fallback for non-extension contexts
            controller.dismiss(animated: true, completion: nil)
        }
    }
}
