import Foundation
import UIKit

class QBridgeUtils {
	static func log(_ msg: String) {
		NSLog("[QBridge] %@", msg)
	}

	static func appInfo() -> [String: Any] {
		let info = Bundle.main.infoDictionary ?? [:]
		return [
			"name": info["CFBundleName"] as? String ?? "",
			"version": info["CFBundleShortVersionString"] as? String ?? "",
			"build": info["CFBundleVersion"] as? String ?? "",
			"platform": "iOS"
		]
	}

	static func uuid() -> String { UUID().uuidString }
}
