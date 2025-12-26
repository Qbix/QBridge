import UIKit

@objc public class QBridgePluginCloser: NSObject {
	@objc public static func close(_ controller: UIViewController?) {
		if let controller = controller {
			controller.dismiss(animated: true, completion: nil)
			return
		}

		if let window = UIApplication.shared.keyWindow,
		   let rootVC = window.rootViewController {
			rootVC.dismiss(animated: true, completion: nil)
		}
	}
}
