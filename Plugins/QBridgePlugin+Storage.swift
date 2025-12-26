import Foundation

extension QBridgePlugin {

	private func localStorageBackupPath() -> String {
		let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
		return "\(docs)/localStorageBackup.json"
	}

	private func sessionIdPath() -> String {
		let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
		return "\(docs)/sessionId.txt"
	}

	private func incrementSessionId() -> Int {
		let path = sessionIdPath()
		let fm = FileManager.default
		var current = "0"
		if fm.fileExists(atPath: path) {
			current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "0"
		}
		let next = (Int(current) ?? 0) + 1
		try? "\(next)".write(toFile: path, atomically: true, encoding: .utf8)
		return next
	}

	@objc func storageLoad(_ args: [Any], callbackId: String?, bridge: QBridge) {
		let path = localStorageBackupPath()
		var data: [String: Any] = [:]

		if FileManager.default.fileExists(atPath: path),
		   let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
		   let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
			data = parsed ?? [:]
		}

		let sessionId = incrementSessionId()
		let response: [String: Any] = [
			"localStorage": data,
			"sessionId": sessionId
		]

		bridge.sendEvent(callbackId ?? "", data: ["result": response])
	}

	@objc func storageSave(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard let delta = args.first as? [String: Any] else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid delta"])
			return
		}

		let path = localStorageBackupPath()
		var existing = [String: Any]()

		if let existingData = try? Data(contentsOf: URL(fileURLWithPath: path)),
		   let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
			existing = parsed ?? [:]
		}

		for (key, value) in delta {
			if value is NSNull {
				existing.removeValue(forKey: key)
			} else {
				existing[key] = value
			}
		}

		do {
			let json = try JSONSerialization.data(withJSONObject: existing)
			try json.write(to: URL(fileURLWithPath: path), options: .atomic)
			bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
		} catch {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Failed to write localStorageBackup.json"])
		}
	}
}
