import UIKit
import Foundation

@objc(QbixGroupsBridgePlugin)
class QbixGroupsBridgePlugin: QBridgeBaseService {

	private var smsCallbackId: String?
	private var emailCallbackId: String?

	// MARK: - Helpers

	private func sendSuccess(_ callbackId: String?) {
		bridge.sendEvent(callbackId ?? "", data: ["result": ""])
	}

	private func sendError(_ callbackId: String?, _ error: String) {
		bridge.sendEvent(callbackId ?? "", data: ["error": error])
	}

	// ======================================================
	// MARK: - Share Extension Email / SMS completion handlers
	// ======================================================

	@objc func completeShareExtensionEmail(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let subject = arr[safe: 0] as? String ?? ""
		let body = arr[safe: 1] as? String ?? ""
		let attachmentStrings = arr[safe: 2] as? [String]
		let attachments = attachmentStrings?.compactMap { URL(string: $0) }

		guard let extensionContext = bridge.extensionContext else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Extension context not available"])
			return
		}

		let item = NSExtensionItem()
		item.attributedContentText = NSAttributedString(string: body)
		item.userInfo = ["subject": subject]

		if let attachments = attachments, !attachments.isEmpty {
			item.attachments = attachments.compactMap { NSItemProvider(contentsOf: $0) }
		}

		extensionContext.completeRequest(returningItems: [item] as [NSExtensionItem]?, completionHandler: nil)

		bridge.sendEvent(callbackId ?? "", data: ["result": "Email completion request sent"])
	}

	@objc func completeShareExtensionSms(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let body = arr[safe: 0] as? String ?? ""

		guard let extensionContext = bridge.extensionContext else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Extension context not available"])
			return
		}

		let item = NSExtensionItem()
		item.attributedContentText = NSAttributedString(string: body)
		item.userInfo = ["UTI": "public.text"]

		extensionContext.completeRequest(returningItems: [item] as [NSExtensionItem]?, completionHandler: nil)

		bridge.sendEvent(callbackId ?? "", data: ["result": "SMS completion request sent"])
	}

}

// MARK: - Safe Array Access
private extension Array {
	subscript(safe index: Int) -> Element? {
		return indices.contains(index) ? self[index] : nil
	}
}
