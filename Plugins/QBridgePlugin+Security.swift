import Foundation
import Security
import DeviceCheck
import UIKit
import CryptoKit

extension QBridgePlugin {

	// MARK: - Identity configuration

	private struct IdentityConfig {

		let secureEnclaveTag: Data
		let keychainGroup: String?
		let uuidAccount: String
		let uuidLegacyAccount: String
		let appAttestKeyIdAccount: String

		static func load() -> IdentityConfig {
			let defaults = UserDefaults.standard

			func str(_ key: String, _ fallback: String) -> String {
				return defaults.string(forKey: key) ?? fallback
			}

			return IdentityConfig(
				secureEnclaveTag:
					str("Q.Identity.SecureEnclaveTag",
						"com.qbix.groups.secure-enclave").data(using: .utf8)!,
				keychainGroup:
					defaults.string(forKey: "Q.Identity.KeychainGroup"),
				uuidAccount:
					str("Q.Identity.UUIDAccount", "com.qbix.groups.uuid"),
				uuidLegacyAccount:
					str("Q.Identity.UUIDLegacyAccount", "com.yourapp.syncedUUID"),
				appAttestKeyIdAccount:
					str("Q.Identity.AppAttestKeyIdAccount",
						"com.qbix.groups.appattest.keyid")
			)
		}
	}

	private var cfg: IdentityConfig { IdentityConfig.load() }

	// MARK: - App Clip detection

	private var isRunningInAppClip: Bool {
		if #available(iOS 14.0, *) {
			return Bundle.main.bundleURL.pathExtension == "appclip"
		}
		return false
	}

	private var effectiveKeychainGroup: String? {
		return isRunningInAppClip ? nil : cfg.keychainGroup
	}

	// MARK: - Secure Enclave key handling

	private func loadIdentityKey() -> SecKey? {

		let query: [String: Any] = [
			kSecClass as String: kSecClassKey,
			kSecAttrApplicationTag as String: cfg.secureEnclaveTag,
			kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
			kSecReturnRef as String: true
		]

		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
			return nil
		}

		return (item as! SecKey)
	}

	private func createIdentityKey() throws -> SecKey {

		let access =
			SecAccessControlCreateWithFlags(
				nil,
				kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
				.privateKeyUsage,
				nil
			)!

		let attrs: [String: Any] = [
			kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
			kSecAttrKeySizeInBits as String: 256,
			kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
			kSecAttrIsPermanent as String: true,
			kSecAttrApplicationTag as String: cfg.secureEnclaveTag,
			kSecAttrAccessControl as String: access
		]

		var error: Unmanaged<CFError>?
		guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
			throw error!.takeRetainedValue()
		}

		return key
	}

	private func publicKeyBase64(_ key: SecKey) -> String? {
		guard
			let pub = SecKeyCopyPublicKey(key),
			let data = SecKeyCopyExternalRepresentation(pub, nil) as Data?
		else { return nil }

		return data.base64EncodedString()
	}

	// MARK: - UUID handling

	private func loadUUID(account: String) -> String? {

		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true
		]

		if let group = effectiveKeychainGroup {
			query[kSecAttrAccessGroup as String] = group
		}

		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
			  let data = item as? Data
		else { return nil }

		return String(data: data, encoding: .utf8)
	}

	private func storeUUID(_ uuid: String, account: String) {

		let data = uuid.data(using: .utf8)!

		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: account,
			kSecValueData as String: data,
			kSecAttrAccessible as String:
				kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]

		if let group = effectiveKeychainGroup {
			query[kSecAttrAccessGroup as String] = group
		}

		SecItemDelete(query as CFDictionary)
		SecItemAdd(query as CFDictionary, nil)
	}

	private func canonicalUUID() -> String {

		if let uuid = loadUUID(account: cfg.uuidAccount) {
			return uuid
		}

		if let legacy = loadUUID(account: cfg.uuidLegacyAccount) {
			storeUUID(legacy, account: cfg.uuidAccount)
			return legacy
		}

		let fresh =
			UIDevice.current.identifierForVendor?.uuidString
			?? UUID().uuidString

		storeUUID(fresh, account: cfg.uuidAccount)
		return fresh
	}

	// MARK: - App Attest

	private func loadAppAttestKeyId() -> String? {

		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: cfg.appAttestKeyIdAccount,
			kSecReturnData as String: true
		]

		if let group = effectiveKeychainGroup {
			query[kSecAttrAccessGroup as String] = group
		}

		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
			  let data = item as? Data
		else { return nil }

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

		if let group = effectiveKeychainGroup {
			query[kSecAttrAccessGroup as String] = group
		}

		SecItemDelete(query as CFDictionary)
		SecItemAdd(query as CFDictionary, nil)
	}

	private func attest(completion: @escaping ([String: Any]?, String?) -> Void) {

		guard DCAppAttestService.shared.isSupported else {
			completion(nil, "App Attest not supported")
			return
		}

		let timestamp = Int(Date().timeIntervalSince1970)
		let payload = ["type": "attest", "timestamp": timestamp] as [String : Any]

		guard let canonical = QUtils.serialize(payload),
			  let data = canonical.data(using: .utf8)
		else {
			completion(nil, "Serialization failed")
			return
		}

		let hash = Data(SHA256.hash(data: data))
		let service = DCAppAttestService.shared

		let finish: (String) -> Void = { keyId in
			service.generateAssertion(keyId, clientDataHash: hash) { assertion, error in
				if let assertion = assertion {
					completion([
						"timestamp": timestamp,
						"attestation": assertion.base64EncodedString(),
						"keyId": keyId
					], nil)
				} else {
					completion(nil, error?.localizedDescription)
				}
			}
		}

		if let keyId = loadAppAttestKeyId() {
			finish(keyId)
			return
		}

		service.generateKey { keyId, error in
			guard let keyId = keyId else {
				completion(nil, error?.localizedDescription)
				return
			}
			self.storeAppAttestKeyId(keyId)
			finish(keyId)
		}
	}

	// MARK: - Signing entry point

	@objc func sign(_ args: [Any], callbackId: String?, bridge: QBridge) {

		guard
			let payload = args.first as? [String: Any],
			let canonical = QUtils.serialize(payload),
			let data = canonical.data(using: .utf8)
		else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid payload"])
			return
		}

		if let key = loadIdentityKey() {
			signWithKey(key, data: data, bridge: bridge, callbackId: callbackId)
			return
		}

		attest { attestData, error in
			if let attestData = attestData {
				bridge.sendEvent(callbackId ?? "", data: attestData)
				return
			}

			do {
				let key = try self.createIdentityKey()
				self.signWithKey(key, data: data, bridge: bridge, callbackId: callbackId)
			} catch {
				bridge.sendEvent(
					callbackId ?? "",
					data: ["error": error.localizedDescription]
				)
			}
		}
	}

	private func signWithKey(
		_ key: SecKey,
		data: Data,
		bridge: QBridge,
		callbackId: String?
	) {

		let digest = Data(SHA256.hash(data: data))
		var error: Unmanaged<CFError>?

		guard let sig =
			SecKeyCreateSignature(
				key,
				.ecdsaSignatureDigestX962SHA256,
				digest as CFData,
				&error
			) as Data?
		else {
			bridge.sendEvent(
				callbackId ?? "",
				data: ["error": error!.takeRetainedValue().localizedDescription]
			)
			return
		}

		var out: [String: Any] = [
			"signature": sig.base64EncodedString(),
			"interactive": false
		]

		if let pub = publicKeyBase64(key) {
			out["publicKey"] = pub
		}

		bridge.sendEvent(callbackId ?? "", data: out)
	}
}

