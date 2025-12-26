import UIKit

@objc class ClipboardBridgePlugin: QBridgeBaseService {

	@objc func get(_ args: Any?, callbackId: String?) {
		let text = UIPasteboard.general.string ?? ""
		bridge.sendEvent(callbackId ?? "", data: ["text": text])
	}

	@objc func set(_ args: Any?, callbackId: String?) {
		if let dict = args as? [String: Any], let text = dict["text"] as? String {
			UIPasteboard.general.string = text
			bridge.sendEvent(callbackId ?? "", data: ["success": true])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Missing text"])
		}
	}
}
