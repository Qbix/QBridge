import Foundation

@objc class QBridgeRegistry: NSObject {
	private struct Entry {
		let service: QBridgeService
		let actions: [String: (Any?, String?, QBridge) -> Void]
	}

	private static var services = [String: Entry]()

	static func register(service: QBridgeService, name: String) {
		let actions = service.collectActions()
		services[name] = Entry(service: service, actions: actions)
		QBridgeUtils.log("Registered QBridge service: \(name) with \(actions.count) actions")
	}

	static func route(service: String, action: String, args: Any?, callbackId: String?, bridge: QBridge) {
		guard let entry = services[service] else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Unknown service \(service)"])
			return
		}
		guard let handler = entry.actions[action] else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Unknown action \(service).\(action)"])
			return
		}
		handler(args, callbackId, bridge)
	}
}
