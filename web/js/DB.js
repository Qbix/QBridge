/* QBridge/Db.js
 *
 * IndexedDB shim backed by QBridge native DB.
 * Promise-based, Cordova-compatible semantics.
 * Includes cursor support via native RPC cursors.
 */

(function (global) {

	const SERVICE = "QBridgePlugin";

	const QBridge = global.QBridge;
	if (!QBridge) {
		throw new Error("QBridge must be loaded before QBridge/Db.js");
	}

	// -------------------------------------------------------------
	// Helpers
	// -------------------------------------------------------------

	function nextTick(fn) {
		Promise.resolve().then(fn);
	}

	function parseResult(res) {
		if (res && typeof res === "object" && "result" in res) {
			res = res.result;
		}
		if (typeof res === "string") {
			try { return JSON.parse(res); } catch {}
		}
		if (Array.isArray(res) && res.every(v => typeof v === "string")) {
			try { return res.map(JSON.parse); } catch {}
		}
		return res;
	}

	function makeRequest(command, args = [], dbDuringUpgrade = null) {
		if (dbDuringUpgrade && dbDuringUpgrade._inVersionChangeTransaction) {
			dbDuringUpgrade._upgradePendingOps++;
		}

		return QBridge.exec(SERVICE, command, args)
			.then(res => parseResult(res))
			.finally(() => {
				if (dbDuringUpgrade && dbDuringUpgrade._inVersionChangeTransaction) {
					dbDuringUpgrade._upgradePendingOps--;
					dbDuringUpgrade._maybeFireUpgradeComplete();
				}
			});
	}

	// -------------------------------------------------------------
	// Event base
	// -------------------------------------------------------------

	function Evented() {
		this._listeners = {};
	}
	Evented.prototype.addEventListener = function (type, fn) {
		(this._listeners[type] ||= []).push(fn);
	};
	Evented.prototype.removeEventListener = function (type, fn) {
		const l = this._listeners[type];
		if (!l) return;
		const i = l.indexOf(fn);
		if (i >= 0) l.splice(i, 1);
	};
	Evented.prototype._emit = function (type, evt = {}) {
		evt.type = type;
		evt.target = this;
		const h = this["on" + type];
		if (typeof h === "function") h(evt);
		const l = this._listeners[type];
		if (l) l.slice().forEach(f => f(evt));
	};

	// -------------------------------------------------------------
	// Requests
	// -------------------------------------------------------------

	class IDBRequest extends Evented {
		constructor(source = null, transaction = null) {
			super();
			this.source = source;
			this.transaction = transaction;
			this.readyState = "pending";
			this.result = undefined;
			this.error = null;
		}
	}

	// -------------------------------------------------------------
	// Open request
	// -------------------------------------------------------------

	class IDBOpenRequest extends IDBRequest {
		constructor(name, version) {
			super();

			makeRequest("dbOpen", [name, version])
				.then(res => {
					const oldVersion = res.oldVersion || 0;
					const newVersion = res.newVersion || version;

					const db = new IDBDatabase(name, newVersion);
					api._metadata[name] = res.metadata || {
						name,
						version: newVersion,
						objectStores: {}
					};

					this.result = db;
					this.readyState = "done";

					if (res.upgrade) {
						db._inVersionChangeTransaction = true;
						this._emit("upgradeneeded", { oldVersion, newVersion });

						db._upgradeCompleteCallback = () => {
							db._inVersionChangeTransaction = false;
							this._emit("success");
						};

						nextTick(() => db._maybeFireUpgradeComplete());
					} else {
						this._emit("success");
					}
				})
				.catch(err => {
					this.error = err;
					this.readyState = "done";
					this._emit("error");
				});
		}
	}

	// -------------------------------------------------------------
	// Database
	// -------------------------------------------------------------

	class IDBDatabase extends Evented {
		constructor(name, version) {
			super();
			this.name = name;
			this.version = Number(version);
			this._inVersionChangeTransaction = false;
			this._upgradePendingOps = 0;
			this._upgradeCompleteCallback = null;
		}

		get objectStoreNames() {
			const meta = api._metadata[this.name];
			return withDOMStringList(Object.keys(meta?.objectStores || {}));
		}

		transaction(storeNames, mode = "readonly") {
			if (typeof storeNames === "string") storeNames = [storeNames];
			storeNames = [...new Set(storeNames)];

			const tx = new IDBTransaction(this, storeNames, mode);
			const refs = api._dbRefs[this.name] ||= { count: 0, closeRequested: false };
			refs.count++;

			tx._onFinal = () => {
				const r = api._dbRefs[this.name];
				if (!r) return;
				if (--r.count <= 0 && r.closeRequested && !this._inVersionChangeTransaction) {
					makeRequest("dbClose", [this.name]);
					delete api._dbRefs[this.name];
				}
			};

			return tx;
		}

		createObjectStore(name, options = {}) {
			if (!this._inVersionChangeTransaction) {
				throw new DOMException("", "InvalidStateError");
			}

			const store = new IDBObjectStore(this, name);
			makeRequest("dbCreateObjectStore", [this.name, name, options], this)
				.then(() => {
					api._metadata[this.name].objectStores[name] = {
						options,
						indexes: {}
					};
				});
			return store;
		}

		deleteObjectStore(name) {
			makeRequest("dbDeleteObjectStore", [this.name, name], this)
				.then(() => {
					delete api._metadata[this.name].objectStores[name];
				});
		}

		close() {
			const refs = api._dbRefs[this.name];
			if (!refs) return;

			if (refs.count <= 0 && !this._inVersionChangeTransaction) {
				makeRequest("dbClose", [this.name]);
				delete api._dbRefs[this.name];
			} else {
				refs.closeRequested = true;
			}
		}

		_maybeFireUpgradeComplete() {
			if (this._upgradePendingOps === 0 && this._upgradeCompleteCallback) {
				const cb = this._upgradeCompleteCallback;
				this._upgradeCompleteCallback = null;
				cb();
			}
		}
	}

	// -------------------------------------------------------------
	// Transaction
	// -------------------------------------------------------------

	class IDBTransaction extends Evented {
		constructor(db, storeNames, mode) {
			super();
			this.db = db;
			this.storeNames = storeNames;
			this.mode = mode;
			this._pendingOps = 0;
			this._completed = false;
		}

		objectStore(name) {
			if (!this.storeNames.includes(name)) {
				throw new Error("Store not in transaction");
			}
			const s = new IDBObjectStore(this.db, name);
			s.transaction = this;
			return s;
		}

		_maybeCommit() {
			if (this._pendingOps === 0 && !this._completed) {
				nextTick(() => this.commit());
			}
		}

		_finalize(err) {
			if (this._completed) return;
			this._completed = true;
			this._onFinal && this._onFinal();
			if (err) this._emit("error", { error: err });
			else this._emit("complete");
		}

		commit() {
			makeRequest("dbCommitTransaction", [])
				.then(() => this._finalize())
				.catch(e => this._finalize(e));
		}

		abort() {
			makeRequest("dbAbortTransaction", [])
				.then(() => this._finalize(new Error("aborted")));
		}
	}

	// -------------------------------------------------------------
	// Cursor
	// -------------------------------------------------------------

	class IDBCursor {
		constructor(request, cursorId, direction, keyOnly) {
			this._request = request;
			this._tx = request.transaction;
			this._cursorId = cursorId;

			this.direction = direction || "next";
			this.key = undefined;
			this.primaryKey = undefined;
			this.value = undefined;

			this._keyOnly = keyOnly;
			this._done = false;
			this._inProgress = false;
		}

		// -------------------------
		// Mutation helpers
		// -------------------------

		delete() {
			if (!this._tx || this._tx.mode === "readonly") {
				throw new DOMException("", "ReadOnlyError");
			}
			return this._request.source.delete(this.primaryKey);
		}

		update(value) {
			if (!this._tx || this._tx.mode === "readonly") {
				throw new DOMException("", "ReadOnlyError");
			}
			return this._request.source.put(value, this.primaryKey);
		}

		// -------------------------
		// Core cursor advancement
		// -------------------------

		_fetchNext(advanceCount) {
			if (this._done) {
				throw new DOMException("", "InvalidStateError");
			}
			if (this._inProgress) {
				throw new DOMException("", "InvalidStateError");
			}
			if (typeof advanceCount !== "number" || advanceCount <= 0) {
				throw new TypeError("advance count must be > 0");
			}

			this._inProgress = true;
			this._request.readyState = "pending";

			nextTick(() => {
				if (this._tx) this._tx._pendingOps++;

				makeRequest("dbCursorContinue", [
					this._cursorId,
					advanceCount
				])
					.then(res => {
						if (!res || res.done) {
							this._done = true;
							this._request.result = null;
						} else {
							this.key = res.key;
							this.primaryKey = res.key;
							if (!this._keyOnly) this.value = res.value;
							this._request.result = this;
						}

						this._request.readyState = "done";
						this._request._emit("success");
					})
					.catch(err => {
						this._done = true;
						this._request.error = err;
						this._request.readyState = "done";
						this._request._emit("error");
					})
					.finally(() => {
						this._inProgress = false;
						if (this._tx) {
							this._tx._pendingOps--;
							this._tx._maybeCommit();
						}
					});
			});
		}

		// -------------------------
		// Public IndexedDB API
		// -------------------------

		continue(key) {
			// Cordova parity: key-based continue not supported
			if (key !== undefined) {
				throw new DOMException("", "NotSupportedError");
			}
			this._fetchNext(1);
		}

		advance(count) {
			this._fetchNext(count);
		}
	}

	
	// -------------------------------------------------------------
	// Object store
	// -------------------------------------------------------------

	class IDBObjectStore {
		constructor(db, name) {
			this.db = db;
			this.dbName = db.name;
			this.name = name;
			this.transaction = null;
		}

		// -------------------------
		// Metadata
		// -------------------------

		get indexNames() {
			const meta = api._metadata[this.dbName]?.objectStores?.[this.name];
			return withDOMStringList(meta ? Object.keys(meta.indexes || {}) : []);
		}

		// -------------------------
		// Index management
		// -------------------------

		createIndex(name, keyPath, options = {}) {
			if (!this.db._inVersionChangeTransaction) {
				throw new DOMException("", "InvalidStateError");
			}

			const meta = api._metadata[this.dbName]?.objectStores?.[this.name];
			if (!meta) throw new DOMException("", "NotFoundError");

			if (meta.indexes?.[name]) {
				throw new DOMException("", "ConstraintError");
			}

			const req = new IDBRequest(this, this.transaction);

			makeRequest(
				"dbCreateIndex",
				[this.dbName, this.name, name, keyPath, options],
				this.db
			).then(() => {
				meta.indexes ||= {};
				meta.indexes[name] = {
					keyPath,
					unique: !!options.unique,
					multiEntry: !!options.multiEntry
				};

				req.readyState = "done";
				req._emit("success");
			}).catch(err => {
				req.error = err;
				req.readyState = "done";
				req._emit("error");
			});

			return req;
		}

		deleteIndex(name) {
			const req = new IDBRequest(this, this.transaction);

			makeRequest(
				"dbDeleteIndex",
				[this.dbName, this.name, name],
				this.db
			).then(() => {
				const meta = api._metadata[this.dbName]?.objectStores?.[this.name];
				if (meta?.indexes) delete meta.indexes[name];

				req.readyState = "done";
				req._emit("success");
			}).catch(err => {
				req.error = err;
				req.readyState = "done";
				req._emit("error");
			});

			return req;
		}

		index(name) {
			const meta = api._metadata[this.dbName]?.objectStores?.[this.name];
			if (!meta?.indexes?.[name]) {
				throw new DOMException("", "NotFoundError");
			}
			return new IDBIndex(this, name);
		}

		// -------------------------
		// Basic operations
		// -------------------------

		add(value, key) { return this._op("dbAdd", value, key); }
		put(value, key) { return this._op("dbPut", value, key); }
		delete(key) { return this._op("dbDelete", null, key); }
		get(key) { return this._op("dbGet", key); }
		getAll(query, count) { return this._op("dbGetAll", query, count); }
		getAllKeys(query, count) { return this._op("dbGetAllKeys", query, count); }
		clear() { return this._op("dbClear"); }
		count(key) { return this._op("dbCount", key); }

		// -------------------------
		// Cursor support
		// -------------------------

		openCursor(range, direction = "next") {
			return this._openCursor("dbOpenCursor", range, direction, false);
		}

		openKeyCursor(range, direction = "next") {
			return this._openCursor("dbOpenKeyCursor", range, direction, true);
		}

		_openCursor(cmd, range, direction, keyOnly) {
			const req = new IDBRequest(this, this.transaction);
			const tx = this.transaction;

			if (tx) tx._pendingOps++;

			makeRequest(cmd, [this.dbName, this.name, range, direction])
				.then(res => {
					if (!res || !res.cursorId) {
						req.result = null;
					} else {
						const cursor = new IDBCursor(req, res.cursorId, direction, keyOnly);
						cursor.key = res.key;
						cursor.primaryKey = res.key;
						if (!keyOnly) cursor.value = res.value;
						req.result = cursor;
					}

					req.readyState = "done";
					req._emit("success");

					if (tx) {
						tx._pendingOps--;
						tx._maybeCommit();
					}
				})
				.catch(err => {
					req.error = err;
					req.readyState = "done";
					req._emit("error");
					if (tx) tx.abort();
				});

			return req;
		}

		// -------------------------
		// Internal op helper
		// -------------------------

		_op(cmd, value, key) {
			const req = new IDBRequest(this, this.transaction);
			const tx = this.transaction;

			if (tx) tx._pendingOps++;

			makeRequest(cmd, [this.dbName, this.name, value, key])
				.then(res => {
					req.result = res;
					req.readyState = "done";
					req._emit("success");

					if (tx) {
						tx._pendingOps--;
						tx._maybeCommit();
					}
				})
				.catch(err => {
					req.error = err;
					req.readyState = "done";
					req._emit("error");
					if (tx) tx.abort();
				});

			return req;
		}
	}

	
	// -------------------------------------------------------------
	// Index
	// -------------------------------------------------------------

	class IDBIndex {
		constructor(store, name) {
			this.objectStore = store;
			this.name = name;
			this.transaction = store.transaction;
		}

		get(key) {
			return this._op("dbIndexGet", key);
		}

		getAll(query, count) {
			return this._op("dbIndexGetAll", query, count);
		}

		count(query) {
			return this._op("dbIndexCount", query);
		}

		openCursor(range, direction) {
			return this._openCursor("dbOpenIndexCursor", range, direction, false);
		}

		openKeyCursor(range, direction) {
			return this._openCursor("dbOpenIndexKeyCursor", range, direction, true);
		}

		_op(cmd, key, count) {
			const req = new IDBRequest(this, this.transaction);
			const tx = this.transaction;
			if (tx) tx._pendingOps++;

			makeRequest(cmd, [
				this.objectStore.db.name,
				this.objectStore.name,
				this.name,
				key,
				count
			])
				.then(res => {
					req.result = res;
					req.readyState = "done";
					req._emit("success");
					if (tx) {
						tx._pendingOps--;
						tx._maybeCommit();
					}
				})
				.catch(err => {
					req.error = err;
					req.readyState = "done";
					req._emit("error");
					if (tx) tx.abort();
				});

			return req;
		}

		_openCursor(cmd, range, direction, keyOnly) {
			const req = new IDBRequest(this, this.transaction);
			const tx = this.transaction;
			if (tx) tx._pendingOps++;

			makeRequest(cmd, [
				this.objectStore.db.name,
				this.objectStore.name,
				this.name,
				range,
				direction
			])
				.then(res => {
					if (!res || !res.cursorId) {
						req.result = null;
					} else {
						const cursor = new IDBCursor(req, res.cursorId, direction, keyOnly);
						cursor.key = res.key;
						cursor.primaryKey = res.primaryKey ?? res.key;
						if (!keyOnly) cursor.value = res.value;
						req.result = cursor;
					}
					req.readyState = "done";
					req._emit("success");
					if (tx) {
						tx._pendingOps--;
						tx._maybeCommit();
					}
				})
				.catch(err => {
					req.error = err;
					req.readyState = "done";
					req._emit("error");
					if (tx) tx.abort();
				});

			return req;
		}
	}


	// -------------------------------------------------------------
	// KeyRange
	// -------------------------------------------------------------

	class IDBKeyRange {
		static only(v) { return { only: v }; }
		static lowerBound(v, o) { return { lower: v, lowerOpen: o }; }
		static upperBound(v, o) { return { upper: v, upperOpen: o }; }
		static bound(l, u, lo, uo) {
			return { lower: l, upper: u, lowerOpen: lo, upperOpen: uo };
		}
	}

	// -------------------------------------------------------------
	// Public API
	// -------------------------------------------------------------

	const api = {
		open(name, version) {
			return new IDBOpenRequest(name, version);
		},

		deleteDatabase(name) {
			const req = new IDBRequest();
			makeRequest("dbDeleteDatabase", [name])
				.then(() => {
					req.readyState = "done";
					req._emit("success");
				})
				.catch(err => {
					req.error = err;
					req.readyState = "done";
					req._emit("error");
				});
			return req;
		},

		cmp(a, b) {
			return api.original.cmp(a, b);
		},

		IDBKeyRange,

		_dbRefs: {},
		_metadata: {}
	};

	// -------------------------------------------------------------
	// Replace global indexedDB
	// -------------------------------------------------------------

	api.replace = function () {
		api.original = global.indexedDB;
		Object.defineProperty(global, "indexedDB", {
			get() { return api; },
			configurable: true
		});
	};

	function withDOMStringList(arr) {
		arr.contains = function (v) { return this.includes(v); };
		return arr;
	}

	// -------------------------------------------------------------
	// Export
	// -------------------------------------------------------------

	global.QBridge.Db = api;

})(typeof window !== "undefined" ? window : globalThis);
