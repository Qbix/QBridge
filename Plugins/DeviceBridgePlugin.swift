import UIKit

@objc class DeviceBridgePlugin: QBridgeBaseService {

	@objc func info(_ args: Any?, callbackId: String?) {
		let device = UIDevice.current
		let info: [String: Any] = [
			"model": device.model,
			"systemVersion": device.systemVersion,
			"name": device.name
		]
		bridge.sendEvent(callbackId ?? "", data: info)
	}
}
