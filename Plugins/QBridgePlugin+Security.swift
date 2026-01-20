import Foundation
import Security
import DeviceCheck
import UIKit
import CryptoKit

extension QBridgePlugin {

	// MARK: - Identity configuration (loaded from UserDefaults)

	private struct IdentityConfig {

		let secureEnclaveTag: Data?
		let uuidAccount: String
		let uuidLegacyAccount: String
		let appAttestKeyIdAccount: String

		static func load() -> IdentityConfig {

			let defaults = UserDefaults.standard

			func value(_ key: String, _ fallback: String) -> String {
				defaults.string(forKey: key) ?? fallback
			}

			return IdentityConfig(
				secureEnclaveTag:
					defaults
						.string(forKey: "Q.Identity.SecureEnclaveTag")?.data(using: .utf8),

				uuidAccount:
					value(
						"Q.Identity.UUIDAccount",
						"com.qbix.groups.uuid"
					),

				uuidLegacyAccount:
					value(
						"Q.Identity.UUIDLegacyAccount",
						"com.yourapp.syncedUUID"
					),

				appAttestKeyIdAccount:
					value(
						"Q.Identity.AppAttestKeyIdAccount",
						"com.qbix.groups.appattest.keyid"
					)
			)
		}

		var isFullyConfigured: Bool {
			secureEnclaveTag != nil
		}
	}

	private var cfg: IdentityConfig {
		IdentityConfig.load()
	}

	// MARK: - Identity-scoped defaults keys

	private func identityDefaultsKey(_ suffix: String) -> String? {
		guard
			let tagData = cfg.secureEnclaveTag,
			let tag = String(data: tagData, encoding: .utf8)
		else {
			return nil
		}
		return "Q.Identity.\(tag).\(suffix)"
	}

	// MARK: - App Clip detection

	private var isRunningInAppClip: Bool {
		if #available(iOS 14.0, *) {
			return Bundle.main.bundleURL.pathExtension == "appclip"
		}
		return false
	}

	// MARK: - Secure Enclave identity key

	private func publicKeyBase64(_ key: SecKey) -> String? {
		guard
			let pub = SecKeyCopyPublicKey(key),
			let data =
				SecKeyCopyExternalRepresentation(pub, nil) as Data?
		else {
			return nil
		}
		return data.base64EncodedString()
	}

	// MARK: - UUID handling (PARITY VIA QConfig)

	/// Legacy compatibility stub.
	/// Kept so existing callers do not break.
	/// Parity behavior is delegated to QConfig.UUID().
	private func loadUUID(account: String) -> String? {
		return QConfig.uuid()
	}

	/// Legacy compatibility stub.
	/// UUID persistence is fully owned by QConfig.
	private func storeUUID(_ uuid: String, account: String) {
		// no-op by design
		// QConfig.UUID() handles storage, migration, and synchronization
	}

	/// Canonical UUID entry point.
	/// FULL PARITY with Objective-C implementation via QConfig.UUID().
	private func canonicalUUID() -> String {
		return QConfig.uuid()
	}


	// MARK: - App Attest (identity anchor)

	private func loadAppAttestKeyId() -> String? {

		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: cfg.appAttestKeyIdAccount,
			kSecReturnData as String: true
		]

		var item: CFTypeRef?
		guard
			SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
			let data = item as? Data
		else {
			return nil
		}

		return String(data: data, encoding: .utf8)
	}

	private func storeAppAttestKeyId(_ keyId: String) {

		let data = keyId.data(using: .utf8)!
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: cfg.appAttestKeyIdAccount,
			kSecValueData as String: data,
			kSecAttrAccessible as String:
				kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]

		SecItemDelete(query as CFDictionary)
		SecItemAdd(query as CFDictionary, nil)
	}

	// =========================================================
	// MARK: - Key Storage Types & Tag Parser
	// =========================================================
	
	static let keychainAccessGroup = "com.qbix.groups.keychainshare"
	
	enum KeyStorage {
		case secure
		case keychain
		case shared
	}
	
	private func parseKeyTag(_ tag: String) -> (storage: KeyStorage, interactive: Bool) {
		let interactive = tag.contains("@interactive")

		if tag.contains("@secure") {
			return (.secure, interactive)
		}
		if tag.contains("@keychain") {
			return (.keychain, interactive)
		}
		return (.shared, interactive)
	}

	// =========================================================
	// MARK: - Signing key (by tag) helper
	// =========================================================
		
	private func loadOrCreateSigningKey(
		tag: String,
		allowCreate: Bool
	) -> SecKey? {

		let tagData = tag.data(using: .utf8)!
		let parsed = parseKeyTag(tag)

		// -------------------------------------------------
		// 1) Try existing key (scoped by storage type)
		// -------------------------------------------------

		var query: [String: Any] = [
			kSecClass as String: kSecClassKey,
			kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
			kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
			kSecAttrApplicationTag as String: tagData,
			kSecReturnRef as String: true
		]

		if parsed.storage == .shared {
			query[kSecAttrAccessGroup as String] = QBridgePlugin.keychainAccessGroup
		}

		var item: CFTypeRef?
		if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess {
			return (item as! SecKey)
		}

		// -------------------------------------------------
		// 2) Creation (ONLY if explicitly allowed)
		// -------------------------------------------------

		guard allowCreate else {
			// Lookup-only call
			return nil
		}

		switch parsed.storage {

		case .secure:
			guard let access =
				SecAccessControlCreateWithFlags(
					nil,
					kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
					[],
					nil
				)
			else { return nil }

			let attrs: [String: Any] = [
				kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
				kSecAttrKeySizeInBits as String: 256,
				kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
				kSecAttrIsPermanent as String: true,
				kSecAttrApplicationTag as String: tagData,
				kSecAttrAccessControl as String: access
			]

			return SecKeyCreateRandomKey(attrs as CFDictionary, nil)

		case .keychain:
			let attrs: [String: Any] = [
				kSecClass as String: kSecClassKey,
				kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
				kSecAttrKeySizeInBits as String: 256,
				kSecAttrIsPermanent as String: true,
				kSecAttrApplicationTag as String: tagData,
				kSecAttrAccessible as String:
					kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			]

			return SecKeyCreateRandomKey(attrs as CFDictionary, nil)

		case .shared:
			let attrs: [String: Any] = [
				kSecClass as String: kSecClassKey,
				kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
				kSecAttrKeySizeInBits as String: 256,
				kSecAttrIsPermanent as String: true,
				kSecAttrApplicationTag as String: tagData,
				kSecAttrAccessible as String:
					kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
				kSecAttrAccessGroup as String: QBridgePlugin.keychainAccessGroup
			]

			return SecKeyCreateRandomKey(attrs as CFDictionary, nil)
		}
	}

	@objc func getAttestation(
		_ args: [Any],
		callbackId: String?,
		bridge: QBridge
	) {
		let payload = args.first as? [String: Any]
		let options = args.count > 1 ? args[1] as? [String: Any] : nil
		let tag = options?["keyTag"] as? String ?? "com.qbix.groups.key.default@shared"

		guard
			let payload = payload,
			let canonical = QUtils.serialize(payload),
			let _ = canonical.data(using: .utf8),
			let key = loadOrCreateSigningKey(tag: tag, allowCreate: true),
			let pub = SecKeyCopyPublicKey(key),
			let pubData =
				SecKeyCopyExternalRepresentation(pub, nil) as Data?
		else {
			bridge.sendEvent(
				callbackId ?? "",
				data: ["error": "Invalid payload or signing key"]
			)
			return
		}

		let signingKeyIdentityHash =
			Data(SHA256.hash(data: pubData))

		generateAssertionBundle(
			signingPublicKeyHash: signingKeyIdentityHash
		) { fields in
			bridge.sendEvent(
				callbackId ?? "",
				data: fields ?? [:]
			)
		}
	}


	// =========================================================
	// MARK: - Get Public Key (for encryption)
	// =========================================================

	@objc func getEncryptionKey(
		_ args: [Any],
		callbackId: String?,
		bridge: QBridge
	) {
		let options = args.first as? [String: Any]
		let tag = options?["keyTag"] as? String ?? "com.qbix.groups.key.default@shared"
		
		guard let key = loadOrCreateSigningKey(tag: tag, allowCreate: true),
			  let publicKey = SecKeyCopyPublicKey(key),
			  let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
		else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Could not export public key"])
			return
		}
		
		bridge.sendEvent(
			callbackId ?? "",
			data: [
				"publicKey": publicKeyData.base64EncodedString(),
				"format": "sec1",
				"curve": "P-256",
				"keyTag": tag
			]
		)
	}

	// =========================================================
	// MARK: - Decrypt (ECIES)
	// =========================================================

	@objc func decrypt(
		_ args: [Any],
		callbackId: String?,
		bridge: QBridge
	) {
		// Extract ciphertext and options
		guard let ciphertextBase64 = args.first as? String,
			  let ciphertext = Data(base64Encoded: ciphertextBase64)
		else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid ciphertext"])
			return
		}
		
		let options = args.count > 1 ? args[1] as? [String: Any] : nil
		let tag = options?["keyTag"] as? String ?? "com.qbix.groups.key.default@shared"
		
		// Use same key as signing (ECDSA + ECIES)
		guard let privateKey = loadOrCreateSigningKey(tag: tag, allowCreate: true) else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Key not found"])
			return
		}
		
		// Decrypt using ECIES
		var error: Unmanaged<CFError>?
		guard let plaintext = SecKeyCreateDecryptedData(
			privateKey,
			.eciesEncryptionStandardX963SHA256AESGCM,
			ciphertext as CFData,
			&error
		) as Data? else {
			let errorMsg = error?.takeRetainedValue().localizedDescription ?? "unknown"
			bridge.sendEvent(
				callbackId ?? "",
				data: ["error": "Decryption failed: \(errorMsg)"]
			)
			return
		}
		
		// Private key NEVER left device
		bridge.sendEvent(
			callbackId ?? "",
			data: [
				"plaintext": plaintext.base64EncodedString(),
				"Q.udid": canonicalUUID()
			]
		)
	}


	// =========================================================
	// MARK: - Initial App Attest key attestation (bootstrap only)
	// =========================================================

	private func hasSentAttestation(for keyId: String) -> Bool {
		UserDefaults.standard.bool(
			forKey: "Q.AppAttest.Attested.\(keyId)"
		)
	}

	private func markAttestationSent(for keyId: String) {
		UserDefaults.standard.set(
			true,
			forKey: "Q.AppAttest.Attested.\(keyId)"
		)
	}

	
	// =========================================================
	// MARK: - App Attest (assertion + optional key attestation)
	// =========================================================
	
	private func generateAssertionBundle(
		signingPublicKeyHash: Data,
		completion: @escaping ([String: Any]?) -> Void
	) {
		guard DCAppAttestService.shared.isSupported else {
			completion(nil)
			return
		}

		let timestamp = String(Int(Date().timeIntervalSince1970))

		let assertionHash =
			hashForAppAssert(
				signingPublicKeyHash: signingPublicKeyHash,
				timestamp: timestamp
			)

		let challenge = Data(
			SHA256.hash(data: timestamp.data(using: .utf8)!)
		)

		var keyId = loadAppAttestKeyId()
		var out: [String: Any] = [
			"Q.assert.timestamp": timestamp
		]

		let service = DCAppAttestService.shared

		var finished = false
		func finish(_ result: [String: Any]?) {
			guard !finished else { return }
			finished = true
			completion(result)
		}

		func generateAssertion(_ finalKeyId: String) {
			service.generateAssertion(
				finalKeyId,
				clientDataHash: assertionHash
			) { assertion, _ in
				guard let assertion = assertion else {
					finish(nil)
					return
				}
				out["Q.assert.assertion"] = assertion.base64EncodedString()
				out["Q.assert.attestationKeyId"] = finalKeyId
				finish(out)
			}
		}

		func maybeAttestAndFinish(_ finalKeyId: String) {
			if hasSentAttestation(for: finalKeyId) {
				generateAssertion(finalKeyId)
				return
			}

			service.attestKey(
				finalKeyId,
				clientDataHash: challenge
			) { attestation, _ in
				if let attestation = attestation {
					out["Q.assert.attestation"] =
						attestation.base64EncodedString()
					out["Q.assert.challenge"] =
						challenge.base64EncodedString()
					self.markAttestationSent(for: finalKeyId)
				}
				generateAssertion(finalKeyId)
			}
		}

		if keyId == nil {
			service.generateKey { id, _ in
				guard let id = id else {
					finish(nil)
					return
				}
				keyId = id
				self.storeAppAttestKeyId(id)
				maybeAttestAndFinish(id)
			}
			return
		}

		maybeAttestAndFinish(keyId!)
	}




	// MARK: - Public identity accessors (JS-facing)

	/// Legacy accessor for master identity public key.
	/// DEPRECATED: Use getEncryptionKey with explicit keyTag instead.
	/// This returns the Secure Enclave master key's public key if available.
	/// For tag-based identities, use getEncryptionKey().
	@objc func getPublicKey(
		_ args: [Any],
		callbackId: String?,
		bridge: QBridge
	) {

		let pub =
			identityDefaultsKey("PublicKey")
				.flatMap { UserDefaults.standard.string(forKey: $0) }

		bridge.sendEvent(
			callbackId ?? "",
			data: ["publicKey": pub as Any]
		)
	}
	
	// =========================================================
	// MARK: - Signature primitives (pure crypto)
	// =========================================================

	private func signatureWithKey(
		_ key: SecKey,
		data: Data
	) -> Data? {

		let digest = Data(SHA256.hash(data: data))
		return SecKeyCreateSignature(
			key,
			.ecdsaSignatureDigestX962SHA256,
			digest as CFData,
			nil
		) as Data?
	}

	// =========================================================
	// MARK: - Low-level signing (payload only, .m compatible)
	// =========================================================

	@objc func signature(
		_ args: [Any],
		callbackId: String?,
		bridge: QBridge
	) {

		let payload = args.first as? [String: Any]
		let options = args.count > 1 ? args[1] as? [String: Any] : nil
		let tag = options?["keyTag"] as? String ?? "com.qbix.groups.key.default@shared"
		let parsed = parseKeyTag(tag)
		let isInteractive = parsed.interactive

		guard
			let payload = payload,
			let canonical = QUtils.serialize(payload),
			let data = canonical.data(using: .utf8),
			let password = QConfig.applicationKey()
		else {
			bridge.sendEvent(
				callbackId ?? "",
				data: ["error": "Signing unavailable"]
			)
			return
		}

		let signingKey = loadOrCreateSigningKey(tag: tag, allowCreate: true)

		// -------------------------------------------------
		// 1) Try direct signing with signing key
		// -------------------------------------------------
		
		guard let key = signingKey else {
			// No signing key available at all
			bridge.sendEvent(
				callbackId ?? "",
				data: [
					"Q.hmac": hmacSha1(string: canonical, password: password),
					"Q.udid": canonicalUUID(),
					"Q.interactive": isInteractive,
					"Q.error": "Signing key unavailable"
				]
			)
			return
		}
		
		if let sig = signatureWithKey(key, data: data) {

			var out: [String: Any] = [
				"Q.hmac": hmacSha1(string: canonical, password: password),
				"Q.udid": canonicalUUID(),
				"Q.signature": sig.base64EncodedString(),
				"Q.interactive": isInteractive
			]

			let challenge = Data(
				SHA256.hash(
					data: "\(Date().timeIntervalSince1970)"
						.data(using: .utf8)!
				)
			)

			if let assertion = signatureWithKey(key, data: challenge) {
				out["Q.signing.assertion"] = assertion.base64EncodedString()
				out["Q.signing.challenge"] = challenge.base64EncodedString()
				out["Q.signing.hashAlg"] = "sha256"
			}

			bridge.sendEvent(callbackId ?? "", data: out)
			return
		}

		// -------------------------------------------------
		// 2) Direct signing failed, try App Attest
		// -------------------------------------------------

		if let pub = SecKeyCopyPublicKey(key),
		   let pubData =
				SecKeyCopyExternalRepresentation(pub, nil) as Data? {

			let signingKeyPublicKeyHash =
				Data(SHA256.hash(data: pubData))

			generateAssertionBundle(
				signingPublicKeyHash: signingKeyPublicKeyHash
			) { [self] fields in

				if let fields = fields,
				   let sig = signatureWithKey(key, data: data) {

					var out = fields
					out["Q.hmac"] = hmacSha1(string: canonical, password: password)
					out["Q.udid"] = canonicalUUID()
					out["Q.signature"] = sig.base64EncodedString()
					out["Q.interactive"] = isInteractive

					let challenge = Data(
						SHA256.hash(
							data: "\(Date().timeIntervalSince1970)"
								.data(using: .utf8)!
						)
					)

					if let assertion = signatureWithKey(key, data: challenge) {
						out["Q.signing.assertion"] = assertion.base64EncodedString()
						out["Q.signing.challenge"] = challenge.base64EncodedString()
						out["Q.signing.hashAlg"] = "sha256"
					}

					bridge.sendEvent(callbackId ?? "", data: out)
					return
				}

				// -------------------------------------------------
				// 3) App Attest failed, try Master key recovery
				// -------------------------------------------------

				if let master = self.createMasterKey(),
				   let pub = SecKeyCopyPublicKey(key),
				   let pubData =
						SecKeyCopyExternalRepresentation(pub, nil) as Data? {

					let signingKeyPublicKeyHash =
						Data(SHA256.hash(data: pubData))

					if let masterSig =
						signatureWithKey(master, data: signingKeyPublicKeyHash) {

						bridge.sendEvent(
							callbackId ?? "",
							data: [
								"Q.master.signature": masterSig.base64EncodedString(),
								"Q.master.authorized": true,
								"Q.hmac": hmacSha1(string: canonical, password: password),
								"Q.udid": canonicalUUID(),
								"Q.interactive": isInteractive
							]
						)
						return
					}
				}

				// -------------------------------------------------
				// 4) All paths failed
				// -------------------------------------------------

				bridge.sendEvent(
					callbackId ?? "",
					data: [
						"Q.hmac": hmacSha1(string: canonical, password: password),
						"Q.udid": canonicalUUID(),
						"Q.interactive": isInteractive,
						"Q.error": "Identity unavailable"
					]
				)
			}

			return
		}

		// -------------------------------------------------
		// Should not reach here (key exists but no public key export)
		// -------------------------------------------------

		bridge.sendEvent(
			callbackId ?? "",
			data: [
				"Q.hmac": hmacSha1(string: canonical, password: password),
				"Q.udid": canonicalUUID(),
				"Q.interactive": isInteractive,
				"Q.error": "Signing key unavailable"
			]
		)
	}



	// =========================================================
	// MARK: - High-level signing (wrapped payload + attestation)
	// =========================================================

	@objc func sign(
		_ args: [Any],
		callbackId: String?,
		bridge: QBridge
	) {

		guard
			cfg.isFullyConfigured,
			let payload = args.first as? [String: Any]
		else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Signing unavailable"])
			return
		}
		
		let options = args.count > 1 ? args[1] as? [String: Any] : nil
		
		let password = QConfig.applicationKey()

		let timestamp = String(Int(Date().timeIntervalSince1970))

		let appVersion =
			Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
		let build =
			Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

		let fullVersion =
			(appVersion != nil && build != nil)
				? "\(appVersion!) (\(build!))"
				: nil

		let wrapped: [String: Any] = [
			"Q.udid": canonicalUUID(),
			"Q.appId": Bundle.main.bundleIdentifier ?? "",
			"Q.fullVersion": fullVersion as Any,
			"Q.timestamp": timestamp,
			"Q.payload": payload
		]

		guard
			let canonical = QUtils.serialize(wrapped),
			let data = canonical.data(using: .utf8)
		else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Signing failed"])
			return
		}

		if let options = options {
			signature([wrapped, options], callbackId: callbackId, bridge: bridge)
		} else {
			signature([wrapped], callbackId: callbackId, bridge: bridge)
		}
	}


	private func loadMasterKey() -> SecKey? {
		guard let tag = cfg.secureEnclaveTag else { return nil }

		let query: [String: Any] = [
			kSecClass as String: kSecClassKey,
			kSecAttrApplicationTag as String: tag,
			kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
			kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
			kSecReturnRef as String: true
		]

		var item: CFTypeRef?
		guard
			SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
			let cf = item,
			CFGetTypeID(cf) == SecKeyGetTypeID()
		else {
			return nil
		}

		return (cf as! SecKey)
	}

	private func createMasterKey() -> SecKey? {
		guard let tag = cfg.secureEnclaveTag else { return nil }

		guard let access =
			SecAccessControlCreateWithFlags(
				nil,
				kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
				[],
				nil
			)
		else {
			return nil
		}

		let attrs: [String: Any] = [
			kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
			kSecAttrKeySizeInBits as String: 256,
			kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
			kSecAttrIsPermanent as String: true,
			kSecAttrApplicationTag as String: tag,
			kSecAttrAccessControl as String: access
		]

		var error: Unmanaged<CFError>?
		guard let key =
			SecKeyCreateRandomKey(attrs as CFDictionary, &error)
		else {
			return nil
		}

		// Persist public key once (non-authoritative)
		if let pub = publicKeyBase64(key),
		   let k = identityDefaultsKey("PublicKey") {

			let defaults = UserDefaults.standard
			if defaults.string(forKey: k) == nil {
				defaults.set(pub, forKey: k)
			}
		}

		return key
	}

	private func hmacSha1(
		string: String,
		password: String
	) -> String {
		var hmac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
		let key = password.data(using: .utf8)!
		let msg = string.data(using: .utf8)!

		key.withUnsafeBytes { k in
			msg.withUnsafeBytes { m in
				CCHmac(
					CCHmacAlgorithm(kCCHmacAlgSHA1),
					k.baseAddress,
					key.count,
					m.baseAddress,
					msg.count,
					&hmac
				)
			}
		}

		return hmac.map { String(format: "%02x", $0) }.joined()
	}

	// =========================================================
	// MARK: - App Attest identity hash (PARITY WITH QSignUtils)
	// =========================================================

	private func hashForAppAssert(
		signingPublicKeyHash: Data,
		timestamp: String
	) -> Data {
		var data = Data()
		data.append("QAppAssert".data(using: .utf8)!)
		data.append(0x09) // '\t'
		data.append("v1".data(using: .utf8)!)
		data.append(0x09)
		data.append(signingPublicKeyHash)
		data.append(0x09)
		data.append(timestamp.data(using: .utf8)!)
		return Data(SHA256.hash(data: data))
	}

	// =========================================================
	// MARK: - List key tags (metadata only, no key material)
	// =========================================================

	@objc func listKeyTags(
		_ args: [Any],
		callbackId: String?,
		bridge: QBridge
	) {
		let keys = listAllKeyTags()
		bridge.sendEvent(
			callbackId ?? "",
			data: [
				"keyTags": keys
			]
		)
	}

	private func listAllKeyTags() -> [[String: Any]] {

		var results: [[String: Any]] = []

		let query: [String: Any] = [
			kSecClass as String: kSecClassKey,
			kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
			kSecReturnAttributes as String: true,
			kSecReturnRef as String: true,
			kSecMatchLimit as String: kSecMatchLimitAll
		]

		var items: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &items)

		guard status == errSecSuccess,
			  let array = items as? [[String: Any]]
		else {
			return []
		}

		for item in array {

			guard
				let tagData = item[kSecAttrApplicationTag as String] as? Data,
				let tag = String(data: tagData, encoding: .utf8)
			else { continue }

			// Restrict to Qbix / Groups namespace only
			guard
				tag.hasPrefix("com.qbix.")
				|| tag.hasPrefix("groups.")
			else { continue }

			let parsed = parseKeyTag(tag)

			var entry: [String: Any] = [
				"tag": tag,
				"storage": parsed.storage == .secure
					? "secure"
					: parsed.storage == .keychain
						? "keychain"
						: "shared",
				"interactive": parsed.interactive
			]

			// Optional: include public key fingerprint (safe)
			if let keyRef = item[kSecValueRef as String],
			   CFGetTypeID(keyRef as CFTypeRef) == SecKeyGetTypeID() {

				let key = keyRef as! SecKey

				if let pub = SecKeyCopyPublicKey(key),
				   let pubData =
						SecKeyCopyExternalRepresentation(pub, nil) as Data? {
					// ...
				}
			}

			results.append(entry)
		}

		return results
	}


}