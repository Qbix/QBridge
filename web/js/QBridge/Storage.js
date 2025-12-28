/* QBridge/Storage.js
 *
 * Native-backed localStorage/sessionStorage using QBridge.
 * Ported 1:1 from Cordova Storage shim.
 */

(function (global) {

	const SERVICE = "QBridgePlugin";

	const QBridge = global.QBridge;
	if (!QBridge) {
		throw new Error("QBridge must be loaded before QBridge/Storage.js");
	}

	const normalizeKey = (k) => String(k);

	const localStore = {};
	let sessionStore = {};

	let _loaded = false;
	let _sessionId = null;
	let _lastSessionId = null;

	// Track keys modified since last persist
	const _dirtyKeys = new Set();

	const original = {
		localStorage: global.localStorage,
		sessionStorage: global.sessionStorage
	};

	// -------------------------------------------------------------
	// Native persistence
	// -------------------------------------------------------------

	function save() {
		if (_dirtyKeys.size === 0) return;

		const delta = {};
		for (const k of _dirtyKeys) {
			if (k in localStore) {
				delta[k] = localStore[k];
			} else {
				delta[k] = null; // deletion
			}
		}
		_dirtyKeys.clear();

		QBridge.exec(
			null,
			null,
			SERVICE,
			"storageSave",
			[delta]
		);
	}

	function load() {
		return new Promise((resolve, reject) => {
			QBridge.exec(
				function (data) {
					try {
						const hasPriorBackup =
							data &&
							data.localStorage &&
							Object.keys(data.localStorage).length > 0;

						if (!hasPriorBackup && typeof original.localStorage === "object") {
							// Initial import from browser storage
							for (let i = 0; i < original.localStorage.length; i++) {
								const k = original.localStorage.key(i);
								localStore[k] = original.localStorage.getItem(k);
							}
							_dirtyKeys.clear();
							for (const k in localStore) _dirtyKeys.add(k);
							save();
						} else {
							Object.assign(localStore, data.localStorage || {});
						}

						_sessionId = data.sessionId || 0;
						_lastSessionId =
							Number(original.localStorage.getItem("__sessionId")) || 0;

						if (_sessionId !== _lastSessionId) {
							sessionStore = {};
							original.localStorage.setItem(
								"__sessionId",
								String(_sessionId)
							);
						}

						_loaded = true;
						resolve();
					} catch (e) {
						reject(e);
					}
				},
				function (err) {
					reject(err);
				},
				SERVICE,
				"storageLoad",
				[]
			);
		});
	}

	// -------------------------------------------------------------
	// Storage proxy
	// -------------------------------------------------------------

	function makeStorage(store, trackChange, nativeStorage) {
		return new Proxy(store, {
			get(target, prop) {
				if (prop === "getItem")
					return (k) =>
						target.hasOwnProperty(k) ? target[k] : null;

				if (prop === "setItem")
					return (k, v) => {
						const key = normalizeKey(k);
						const val = String(v);
						target[key] = val;
						try { nativeStorage.setItem(key, val); } catch {}
						if (trackChange) {
							_dirtyKeys.add(key);
							save();
						}
					};

				if (prop === "removeItem")
					return (k) => {
						const key = normalizeKey(k);
						delete target[key];
						try { nativeStorage.removeItem(key); } catch {}
						if (trackChange) {
							_dirtyKeys.add(key);
							save();
						}
					};

				if (prop === "clear")
					return () => {
						for (const k in target) {
							if (trackChange) _dirtyKeys.add(k);
							delete target[k];
						}
						try { nativeStorage.clear(); } catch {}
						if (trackChange) save();
					};

				if (prop === "key")
					return (i) => Object.keys(target)[i] || null;

				if (prop === "length")
					return Object.keys(target).length;

				if (!isNaN(prop))
					return Object.keys(target)[Number(prop)] || null;

				const key = normalizeKey(prop);
				return target.hasOwnProperty(key) ? target[key] : null;
			},

			set(target, prop, value) {
				const key = normalizeKey(prop);
				const val = String(value);
				target[key] = val;
				try { nativeStorage.setItem(key, val); } catch {}
				if (trackChange) {
					_dirtyKeys.add(key);
					save();
				}
				return true;
			},

			deleteProperty(target, prop) {
				const key = normalizeKey(prop);
				delete target[key];
				try { nativeStorage.removeItem(key); } catch {}
				if (trackChange) {
					_dirtyKeys.add(key);
					save();
				}
				return true;
			},

			has(target, prop) {
				return prop in target;
			},

			ownKeys(target) {
				return Reflect.ownKeys(target);
			},

			getOwnPropertyDescriptor(target, prop) {
				if (prop in target) {
					return {
						configurable: true,
						enumerable: true,
						value: target[prop],
						writable: true
					};
				}
			}
		});
	}

	// -------------------------------------------------------------
	// Public API
	// -------------------------------------------------------------

	const api = {
		original,

		_loaded: () => _loaded,
		_sessionId: () => _sessionId,

		load,

		replace() {
			if (!_loaded) {
				console.warn("QBridge.Storage: not loaded yet");
				return;
			}

			Object.defineProperty(global, "localStorage", {
				get() {
					return makeStorage(localStore, true, original.localStorage);
				},
				configurable: true,
				enumerable: true
			});

			Object.defineProperty(global, "sessionStorage", {
				get() {
					return makeStorage(sessionStore, false, original.sessionStorage);
				},
				configurable: true,
				enumerable: true
			});
		},

		async loadAndReplace(callback) {
			await api.load();
			api.replace();
			if (typeof callback === "function") callback();
		}
	};

	// -------------------------------------------------------------
	// Export
	// -------------------------------------------------------------

	global.QBridge.Storage = api;

})(typeof window !== "undefined" ? window : globalThis);
