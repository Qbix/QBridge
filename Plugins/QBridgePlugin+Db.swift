import Foundation
import SQLite3

extension QBridgePlugin {

	// MARK: - IndexedDB Methods

	@objc func dbOpen(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let name = args[1] as? String,
			  let version = args[2] as? NSNumber else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let oldVersion = (gDatabaseVersion[name] as? NSNumber)?.intValue ?? 0
		var errMsg: NSString? = nil
		let ok = QDB.ensureDatabaseOpen(name, version: version, error: &errMsg)
		guard ok else {
			let message = errMsg as String? ?? "Failed to open DB"
			bridge.sendEvent(callbackId ?? "", data: ["error": message])
			return
		}

		var storeNames = [String]()
		if let meta = gDatabaseMetadata[name] as? [String: Any],
		   let stores = meta["objectStores"] as? [String: Any] {
			storeNames = Array(stores.keys)
		}

		let upgrade = version.intValue > oldVersion
		let response: [String: Any] = [
			"name": name,
			"storeNames": storeNames,
			"upgrade": upgrade,
			"oldVersion": oldVersion,
			"newVersion": version,
			"metadata": gDatabaseMetadata[name] ?? [:]
		]

		bridge.sendEvent(callbackId ?? "", data: ["result": response])
	}

	@objc func dbDeleteDatabase(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 2, let name = args[1] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		// First, close it via QDB to release any active handles.
		let closeError = QDB.closeDatabase(withName: name)
		if !closeError.isEmpty {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Failed to close DB: \(closeError)"])
			return
		}

		// Then delete it via QDB instead of manually using FileManager or sqlite
		let deleteError = QDB.deleteDatabase(withName: name)
		if !deleteError.isEmpty {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Failed to delete DB: \(deleteError)"])
			return
		}

		// Clean up global metadata safely
		gDatabaseMetadata.removeObject(forKey: name)
		gDatabaseVersion.removeObject(forKey: name)
		gDatabaseMap.removeObject(forKey: name)

		bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
	}


	@objc func dbClose(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 2, let dbName = args[1] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let errorMsg = QDB.closeDatabase(withName: dbName)
		if !errorMsg.isEmpty {
			bridge.sendEvent(callbackId ?? "", data: ["error": errorMsg])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
		}
	}

	@objc func dbClear(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		do {
			try QDB.clearStore(inDatabase: dbName, store: storeName)
			bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
		} catch {
			let msg = "Failed to clear store \(storeName) in database \(dbName): \(error.localizedDescription)"
			bridge.sendEvent(callbackId ?? "", data: ["error": msg])
		}
	}

	@objc func dbCount(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		var err: NSError? = nil
		let count = QDB.countRecords(inDatabase: dbName, store: storeName, error: &err)
		if let err = err {
			bridge.sendEvent(callbackId ?? "", data: ["error": err.localizedDescription])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": count])
		}
	}

	@objc func dbDeleteAllDatabases(_ args: [Any], callbackId: String?, bridge: QBridge) {
		let errorMsg = QDB.deleteAllDatabasesAndTheirFiles()
		if !errorMsg.isEmpty {
			bridge.sendEvent(callbackId ?? "", data: ["error": errorMsg])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
		}
	}

	@objc func dbUseNative(_ args: [Any], callbackId: String?, bridge: QBridge) {
		if args.isEmpty {
			bridge.sendEvent(callbackId ?? "", data: ["result": ["useNative": gUseNative.boolValue]])
			return
		}

		if let flag = args.first as? NSNumber {
			gUseNative = ObjCBool(flag.boolValue)
			bridge.sendEvent(callbackId ?? "", data: ["result": ["useNative": gUseNative.boolValue]])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Argument must be boolean"])
		}
	}


	
	@objc func dbGet(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 4,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let keyOrRange = args[3]
		var error: NSError?

		// Correct Objective-C bridged name:
		let result = QDB.getRecordsFromDatabase(dbName,
												store: storeName,
												keyOrRange: keyOrRange,
												error: &error)

		if let err = error {
			bridge.sendEvent(callbackId ?? "", data: ["error": err.localizedDescription])
			return
		}

		if let arr = result as? [Any] {
			bridge.sendEvent(callbackId ?? "", data: ["result": arr])
		} else if let str = result as? String {
			bridge.sendEvent(callbackId ?? "", data: ["result": str])
		} else if let num = result as? NSNumber {
			bridge.sendEvent(callbackId ?? "", data: ["result": num])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": NSNull()])
		}
	}


	@objc func dbAdd(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 5,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String,
			  let jsonValue = args[3] as? String,
			  let keyMap = args[4] as? [String: Any] else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let primaryKey = keyMap[""] as? String ?? ""
		let errMsg = QDB.putRecord(inDatabase: dbName,
								   store: storeName,
								   primaryKey: primaryKey,
								   jsonValue: jsonValue,
								   keyMap: keyMap,
								   insertMode: "INSERT")

		if !errMsg.isEmpty {
			bridge.sendEvent(callbackId ?? "", data: ["error": errMsg])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
		}
	}

	@objc func dbPut(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 5,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String,
			  let jsonValue = args[3] as? String,
			  let keyMap = args[4] as? [String: Any],
			  let primaryKey = keyMap[""] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid or missing primary key"])
			return
		}

		let errMsg = QDB.putRecord(inDatabase: dbName,
								   store: storeName,
								   primaryKey: primaryKey,
								   jsonValue: jsonValue,
								   keyMap: keyMap,
								   insertMode: "INSERT OR REPLACE")

		if !errMsg.isEmpty {
			bridge.sendEvent(callbackId ?? "", data: ["error": errMsg])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
		}
	}

	@objc func dbDelete(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 4,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String,
			  let primaryKey = args[3] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		do {
			try QDB.deleteRecord(fromDatabase: dbName,
								 store: storeName,
								 primaryKey: primaryKey)
			bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
		} catch {
			bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
		}
	}


	@objc func dbIndexGet(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 5,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String,
			  let indexName = args[3] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let keyOrRange = args[4]
		var error: NSError?

		let result = QDB.performIndexLookup(inDatabase: dbName,
											store: storeName,
											index: indexName,
											keyOrRange: keyOrRange,
											error: &error)

		if let err = error {
			bridge.sendEvent(callbackId ?? "", data: ["error": err.localizedDescription])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": result])
		}
	}

	@objc func dbIndexGetAll(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 5,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String,
			  let indexName = args[3] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let indexValue = args[4]
		var error: NSError?

		let results = QDB.performIndexGetAll(inDatabase: dbName,
											 store: storeName,
											 index: indexName,
											 indexValue: indexValue,
											 error: &error)

		if let err = error {
			bridge.sendEvent(callbackId ?? "", data: ["error": err.localizedDescription])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": results])
		}
	}

	@objc func dbIndexCount(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 5,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String,
			  let indexName = args[3] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let indexValue = args[4]
		var error: NSError?

		let count = QDB.performIndexCount(inDatabase: dbName,
										  store: storeName,
										  index: indexName,
										  indexValue: indexValue,
										  error: &error)

		if let err = error {
			bridge.sendEvent(callbackId ?? "", data: ["error": err.localizedDescription])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": count])
		}
	}


	@objc func dbGetAll(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let keyRange: Any = args.count > 3 ? args[3] : NSNull()
		let countLimit = (args.count > 4 ? args[4] : nil) as? NSNumber
		var error: NSError?

		let results = QDB.performGetAll(inDatabase: dbName,
										store: storeName,
										keyRange: keyRange,
										countLimit: countLimit ?? NSNumber(value: 0),
										error: &error)

		if let err = error {
			bridge.sendEvent(callbackId ?? "", data: ["error": err.localizedDescription])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": results])
		}
	}

	@objc func dbGetAllKeys(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let keyRange = args.count > 3 ? args[3] : nil
		let countLimit = (args.count > 4 ? args[4] : nil) as? NSNumber
		var error: NSError?

		let results = QDB.performGetAllKeys(inDatabase: dbName,
											store: storeName,
											keyRange: keyRange,
											countLimit: countLimit ?? NSNumber(value: 0),
											error: &error)

		if let err = error {
			bridge.sendEvent(callbackId ?? "", data: ["error": err.localizedDescription])
		} else {
			bridge.sendEvent(callbackId ?? "", data: ["result": results ?? []])
		}
	}


	@objc func dbCursorContinue(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 2, let cursorId = args[1] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid cursorId"])
			return
		}
		guard let rows = gCursors[cursorId] as? NSMutableArray else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid cursor"])
			return
		}

		if rows.count == 0 {
			bridge.sendEvent(callbackId ?? "", data: ["result": ["done": true]])
			return
		}

		let next = rows.firstObject as? [String: Any] ?? [:]
		rows.removeObject(at: 0)

		var response: [String: Any] = ["done": false]
		if let k = next["key"] { response["key"] = k }
		if let v = next["value"] { response["value"] = v }

		bridge.sendEvent(callbackId ?? "", data: ["result": response])
	}

	
	@objc func dbLoadMetadata(_ args: [Any], callbackId: String?, bridge: QBridge) {
		DispatchQueue.global(qos: .userInitiated).async {
			let fm = FileManager.default
			let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
			do {
				let files = try fm.contentsOfDirectory(atPath: docsDir)
				gDatabaseMetadata.removeAllObjects()
				gDatabaseVersion.removeAllObjects()

				for file in files where file.hasPrefix("QIDB_") && file.hasSuffix(".meta.json") {
					let dbName = file
						.replacingOccurrences(of: "QIDB_", with: "")
						.replacingOccurrences(of: ".meta.json", with: "")
					if !dbName.isEmpty {
						QDB.loadMetadata(forDatabase: dbName)
					}
				}

				let response: [String: Any] = ["databases": gDatabaseMetadata]
				bridge.sendEvent(callbackId ?? "", data: response)
			} catch {
				bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			}
		}
	}


	@objc func dbCreateObjectStore(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}
		let options = (args.count > 3 ? args[3] : [:]) as? [String: Any] ?? [:]

		DispatchQueue.global(qos: .userInitiated).async {
			var didCreate = ObjCBool(false)
			let errMsg = QDB.createObjectStore(inDatabase: dbName, storeName: storeName, options: options, didCreate: &didCreate)
			if !errMsg.isEmpty {
				bridge.sendEvent(callbackId ?? "", data: ["error": errMsg])
			} else {
				let resp: [String: Any] = [
					"storeCreated": didCreate.boolValue,
					"storeName": storeName,
					"dbName": dbName
				]
				bridge.sendEvent(callbackId ?? "", data: resp)
			}
		}
	}


	@objc func dbDeleteObjectStore(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		DispatchQueue.global(qos: .userInitiated).async {
			let result = QDB.deleteObjectStore(inDatabase: dbName, storeName: storeName)
			if result.isEmpty {
				bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
			} else {
				bridge.sendEvent(callbackId ?? "", data: ["error": result])
			}
		}
	}


	@objc func dbCreateIndex(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 5,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String,
			  let indexName = args[3] as? String,
			  let keyPath = args[4] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}
		let options = (args.count > 5 ? args[5] : [:]) as? [String: Any] ?? [:]

		DispatchQueue.global(qos: .userInitiated).async {
			var didCreate = ObjCBool(false)
			let errMsg = QDB.createIndex(inDatabase: dbName, store: storeName, index: indexName, keyPath: keyPath, options: options, didCreate: &didCreate)
			if !errMsg.isEmpty {
				bridge.sendEvent(callbackId ?? "", data: ["error": errMsg])
			} else {
				let resp: [String: Any] = [
					"indexCreated": didCreate.boolValue,
					"indexName": indexName,
					"storeName": storeName,
					"dbName": dbName
				]
				bridge.sendEvent(callbackId ?? "", data: resp)
			}
		}
	}


	@objc func dbDeleteIndex(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 4,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String,
			  let indexName = args[3] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		DispatchQueue.global(qos: .userInitiated).async {
			guard let meta = gDatabaseMetadata[dbName] as? NSMutableDictionary else {
				bridge.sendEvent(callbackId ?? "", data: ["error": "Database metadata not found"])
				return
			}
			guard let storeMeta = (meta["objectStores"] as? NSMutableDictionary)?[storeName] as? NSMutableDictionary else {
				bridge.sendEvent(callbackId ?? "", data: ["error": "Store not found"])
				return
			}
			let indexes = (storeMeta["indexes"] as? NSMutableDictionary) ?? NSMutableDictionary()
			if indexes[indexName] == nil {
				bridge.sendEvent(callbackId ?? "", data: ["error": "Index not found"])
				return
			}
			indexes.removeObject(forKey: indexName)
			storeMeta["indexes"] = indexes
			storeMeta["indexNames"] = indexes.allKeys
			(meta["objectStores"] as? NSMutableDictionary)?[storeName] = storeMeta
			QDB.saveMetadata(forDatabase: dbName)

			let errMsg = QDB.deleteIndex(inDatabase: dbName, store: storeName, index: indexName)
			if !errMsg.isEmpty {
				bridge.sendEvent(callbackId ?? "", data: ["error": errMsg])
			} else {
				bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
			}
		}
	}

	
	@objc func dbImportChunk(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[0] as? String,
			  let storeName = args[1] as? String,
			  let rows = args[2] as? [[String: Any]] else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let options = (args.count > 3 ? args[3] : [:]) as? [String: Any] ?? [:]

		DispatchQueue.global(qos: .userInitiated).async {
			let errMsg = QDB.importChunk(toDatabase: dbName,
										 storeName: storeName,
										 rows: rows,
										 options: options)

			// If QDB.importChunk returns a String ("" on success)
			if let err = errMsg as? String, !err.isEmpty {
				bridge.sendEvent(callbackId ?? "", data: ["error": err])
			}
			// If it’s nil (optional return), this handles both cases
			else if errMsg == nil {
				bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
			} else {
				bridge.sendEvent(callbackId ?? "", data: ["result": "OK"])
			}
		}
	}

	@objc func dbOpenCursor(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let keyRange = args.count > 3 ? args[3] : nil
		let direction = (args.count > 4 ? args[4] : "next") as? String ?? "next"

		DispatchQueue.global(qos: .userInitiated).async {
			let cursorId = "\(dbName):\(storeName):\(Date.timeIntervalSinceReferenceDate)"
			var errMsg: NSString? = nil

			// Call into QDB (handles SQL or storage internally)
			guard let results = QDB.openCursor(inDatabase: dbName,
											   store: storeName,
											   keyRange: keyRange,
											   direction: direction,
											   cursorId: cursorId,
											   error: &errMsg) as? [[String: Any]] else {
				let msg = errMsg as String? ?? "Unknown error"
				bridge.sendEvent(callbackId ?? "", data: ["error": msg])
				return
			}

			// Cache full result list for dbCursorContinue()
			gCursors[cursorId] = NSMutableArray(array: results)

			// Prepare first record response
			if let first = results.first {
				let resp: [String: Any] = [
					"cursorId": cursorId,
					"key": first["key"] ?? "",
					"value": first["value"] ?? ""
				]
				bridge.sendEvent(callbackId ?? "", data: resp)
			} else {
				let resp: [String: Any] = [
					"cursorId": cursorId,
					"result": NSNull()
				]
				bridge.sendEvent(callbackId ?? "", data: resp)
			}
		}
	}

	@objc func dbOpenKeyCursor(_ args: [Any], callbackId: String?, bridge: QBridge) {
		guard args.count >= 3,
			  let dbName = args[1] as? String,
			  let storeName = args[2] as? String else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid arguments"])
			return
		}

		let keyRange = args.count > 3 ? args[3] : nil
		let direction = (args.count > 4 ? args[4] : "next") as? String ?? "next"

		DispatchQueue.global(qos: .userInitiated).async {
			var cursorId: NSString?
			var errorStr: NSString?

			// QDB returns a dictionary of results or nil on error
			if let result = QDB.openKeyCursor(inDatabase: dbName,
											  storeName: storeName,
											  keyRange: keyRange,
											  direction: direction,
											  cursorId: &cursorId,
											  error: &errorStr) as? [String: Any],
			   errorStr == nil || errorStr!.length == 0 {
				// ✅ Force non-optional callbackId and proper dictionary type
				bridge.sendEvent(callbackId ?? "", data: result)
			} else {
				let errMsg = (errorStr as String?) ?? "Unknown error"
				bridge.sendEvent(callbackId ?? "", data: ["error": errMsg])
			}
		}
	}

}
