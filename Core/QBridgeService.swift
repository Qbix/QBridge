import Foundation
import ObjectiveC.runtime
import UIKit

// MARK: - Protocol
protocol QBridgeService: AnyObject {
	func collectActions() -> [String: (Any?, String?, QBridge) -> Void]
	var serviceName: String { get }
}

// MARK: - Base Class
class QBridgeBaseService: NSObject, QBridgeService {

	// The bridge that owns this service
	let bridge: QBridge

	// Computed service name (class name)
	var serviceName: String { String(describing: type(of: self)) }

	// MARK: - Init
	required init(bridge: QBridge) {
		self.bridge = bridge
		super.init()
	}

	convenience init(autoRegister bridge: QBridge) {
		self.init(bridge: bridge)
		let actions = collectActions()
		QBridgeRegistry.register(service: self, name: serviceName)
		QBridgeUtils.log("Auto-registered service \(serviceName) with \(actions.count) actions")
	}

	// MARK: - Action Collection (Cordova-style)
	func collectActions() -> [String: (Any?, String?, QBridge) -> Void] {
		var actions = [String: (Any?, String?, QBridge) -> Void]()
		var count: UInt32 = 0
		let cls: AnyClass = type(of: self)

		if let methodList = class_copyMethodList(cls, &count) {
			defer { free(methodList) }

			for i in 0..<Int(count) {
				let method = methodList[i]
				let sel = method_getName(method)
				let selName = NSStringFromSelector(sel)
				let argCount = method_getNumberOfArguments(method)

				// Match Cordova-style (obj, _cmd, args, callbackId)
				guard argCount == 4, selName.hasSuffix(":callbackId:") else { continue }

				// Verify ObjC argument types
				var arg1Type = ""
				var arg2Type = ""
				if let arg1Ptr = method_copyArgumentType(method, 2) {
					arg1Type = String(cString: arg1Ptr)
					free(arg1Ptr)
				}
				if let arg2Ptr = method_copyArgumentType(method, 3) {
					arg2Type = String(cString: arg2Ptr)
					free(arg2Ptr)
				}
				guard arg1Type.contains("@"), arg2Type.contains("@") else { continue }

				// Normalize action name
				var actionName = String(selName.dropLast(":callbackId:".count))
				if actionName.hasSuffix("WithArgs") {
					actionName.removeLast("WithArgs".count)
				}

				// Capture implementation
				let imp = class_getMethodImplementation(cls, sel)
				typealias Fn = @convention(c) (AnyObject, Selector, Any?, String?) -> Void
				let fn = unsafeBitCast(imp, to: Fn.self)

				// Wrap as closure
				actions[actionName] = { args, callbackId, bridge in
					fn(self, sel, args, callbackId)
				}
			}
		}

		return actions
	}
}
