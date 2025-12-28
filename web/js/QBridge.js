(function(global) {
	// -------------------------------------------------------------
	// Core QBridge
	// -------------------------------------------------------------
	var QBridge = {
		_callbacks: {},
		_callbackCounter: 0,

		exec: function(success, error, service, action, args) {
			var callbackId = "cb" + (++this._callbackCounter);
			if (success) this._callbacks[callbackId + ":success"] = success;
			if (error) this._callbacks[callbackId + ":error"] = error;

			var message = { service: service, action: action, args: args, callbackId: callbackId };

			// Native WKWebView bridge (App / App Clip)
			if (global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers.QBridge) {
				global.webkit.messageHandlers.QBridge.postMessage(message);
				return;
			}

			// Safari Web Extension fallback
			if (global.browser && global.browser.runtime && global.browser.runtime.sendMessage) {
				global.browser.runtime.sendMessage(message).then(
					function(result) {
						this._invokeCallback(callbackId, true, result);
					}.bind(this),
					function(err) {
						this._invokeCallback(callbackId, false, err);
					}.bind(this)
				);
				return;
			}

			// No bridge available
			console.warn("QBridge: no native handler for", service, action);
			this._invokeCallback(callbackId, false, "Bridge unavailable");
		},

		sendEvent: function(callbackId, data) {
			this._invokeCallback(callbackId, true, data);
		},

		_invokeCallback: function(callbackId, success, result) {
			var key = callbackId + (success ? ":success" : ":error");
			var cb = this._callbacks[key];
			if (cb) {
				try {
					cb(result); // Pass the data (success or error) to the callback
					this._cleanupCallback(callbackId);
				} catch (e) {
					console.error("Error invoking callback:", e);
				}
			}
		},

		_cleanupCallback: function(callbackId) {
			delete this._callbacks[callbackId + ":success"];
			delete this._callbacks[callbackId + ":error"];
		},

		// Add onNative method to handle native events
		onNative: function(eventData) {
			var callbackId = eventData.callbackId,
				data = eventData.data,
				event = eventData.event,
				keepCallback = eventData.keepCallback;

			// Check if the event data contains an error or success response
			var isSuccess = data && data.error == undefined; // Check if there's no error
			var callbackType = isSuccess ? ":success" : ":error";

			// Construct the callback key
			var callbackKey = callbackId + callbackType;

			// Find and invoke the callback
			var cb = this._callbacks[callbackKey];
			if (cb) {
				try {
					cb(data); // Pass the data (success or error) to the callback

					// If keepCallback is false, clean up the callback
					if (!keepCallback) {
						this._cleanupCallback(callbackId);
					}
				} catch (e) {
					console.error("Error invoking callback:", e);
				}
			} else {
				console.warn("Callback for " + callbackId + " not found.");
			}
		}
	};

	// -------------------------------------------------------------
	// Lightweight Module System (from AppClip variant)
	// -------------------------------------------------------------
	QBridge.modules = {};

	QBridge.define = function(id, factory) {
		if (QBridge.modules[id]) return;
		QBridge.modules[id] = { factory: factory, exports: {}, initialized: false };
	};

	QBridge.require = function(id) {
		var m = QBridge.modules[id];
		if (!m) throw new Error("Module " + id + " not found");
		if (!m.initialized) {
			m.factory(QBridge.require, m.exports, m);
			m.initialized = true;
		}
		return m.exports;
	};

	// -------------------------------------------------------------
	// Simple lifecycle (deviceready/pause/resume)
	// -------------------------------------------------------------
	function fireEvent(name) {
		document.dispatchEvent(new Event(name));
	}

	document.addEventListener("DOMContentLoaded", function() {
		fireEvent("deviceready");
	});

	window.addEventListener("focus", function() {
		fireEvent("resume");
	});

	window.addEventListener("blur", function() {
		fireEvent("pause");
	});
	
	// -------------------------------------------------------------
	// Hook window.close() to native dismissal
	// -------------------------------------------------------------
	(function () {
		const originalClose = window.close;
		window.close = function() {
			try {
				// Try native first
				if (global.QBridge) {
					QBridge.exec(
						() => {},
						() => {},
						"QBridgePlugin", // service name
						"close",          // action
						[]
					);
					return;
				}
				// Fallback to default
				originalClose && originalClose();
			} catch (e) {
				console.warn("window.close() failed:", e);
				originalClose && originalClose();
			}
		};
	})();


	// -------------------------------------------------------------
	// Expose globally (Cordova compat)
	// -------------------------------------------------------------
	var cordova = global.cordova || (global.cordova = {});
	cordova.exec = function() {
		QBridge.exec.apply(QBridge, arguments);
	};

	global.QBridge = QBridge;
})(typeof window !== "undefined" ? window : globalThis);
