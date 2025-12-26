import Foundation

@objcMembers
public class QBridgeMessageRouter: NSObject {

	// MARK: - Singleton
	public static let shared = QBridgeMessageRouter()

	// MARK: - Objective-C entry point
	@objc public func routeWithService(_ service: String,
	                                   method: String,
	                                   args: Any?,
	                                   callback: String?,
	                                   bridge: QBridge) {
		self.routeSwift(service: service, method: method, args: args, callback: callback, bridge: bridge)
	}

	// MARK: - Core Swift implementation (NOT exposed to Obj-C)
	private func routeSwift(service: String,
	                        method: String,
	                        args: Any?,
	                        callback: String?,
	                        bridge: QBridge) {
		DispatchQueue.global(qos: .userInitiated).async {
			var errorMessage: String?

			do {
				if let targetClass = self.classForService(service) {
					try self.invoke(targetClass: targetClass,
					                method: method,
					                args: args,
					                callback: callback,
					                bridge: bridge)
					return
				} else {
					errorMessage = "Service \(service) not found"
				}
			} catch {
				errorMessage = error.localizedDescription
			}

			if let cb = callback {
				let payload = ["error": errorMessage ?? "Unknown error"]
				DispatchQueue.main.async {
					bridge.sendEvent(cb, data: payload)
				}
			}
		}
	}

	// MARK: - Service class lookup
	private func classForService(_ name: String) -> AnyClass? {
		if let cls = NSClassFromString(name) { return cls }

		let bridgedNames = [name.replacingOccurrences(of: "Cordova", with: "BridgePlugin")]
		for candidate in bridgedNames {
			if let cls = NSClassFromString(candidate) { return cls }
			if let bundleName = Bundle.main.infoDictionary?["CFBundleName"] as? String,
			   let qualified = NSClassFromString("\(bundleName).\(candidate)") {
				return qualified
			}
		}
		return nil
	}

	// MARK: - Invoke plugin handler
	private func invoke(targetClass: AnyClass,
                    method: String,
                    args: Any?,
                    callback: String?,
                    bridge: QBridge) throws {
    
		// Try to construct via init(bridge:) first
		var instance: AnyObject? = nil
		
		if let baseType = targetClass as? QBridgeBaseService.Type {
			instance = baseType.init(bridge: bridge)
		} else if let objType = targetClass as? NSObject.Type {
			instance = objType.init()
		}
		
		guard let service = instance else {
			NSLog("Could not instantiate \(targetClass) — no valid init() or init(bridge:)");
			throw NSError(domain: "QBridge",
						  code: -1,
						  userInfo: [NSLocalizedDescriptionKey:
							"Could not instantiate \(targetClass) — no valid init() or init(bridge:)"])
		}
		
		// Try with "WithArgs" first (the old convention)
		var selectorName = "\(method)WithArgs:callbackId:"
		var selector = NSSelectorFromString(selectorName)
		
		// If that doesn't work, try without "WithArgs"
		if !service.responds(to: selector) {
			selectorName = "\(method):callbackId:"
			selector = NSSelectorFromString(selectorName)
		}
		
		guard service.responds(to: selector) else {
			NSLog("Method \(method)WithArgs:callbackId: or \(method):callbackId: not found on \(targetClass)");
			throw NSError(domain: "QBridge",
						  code: -1,
						  userInfo: [NSLocalizedDescriptionKey:
							"Method \(method)WithArgs:callbackId: or \(method):callbackId: not found on \(targetClass)"])
		}
		
		// Call and capture result properly
		let result = service.perform(selector, with: args, with: callback)
	}


}
