import Foundation
import Security
import DeviceCheck
import UIKit
import CryptoKit

extension QBridgePlugin {

	// MARK: - Constants

	private static let identityKeyTag = "com.qbix.groups.secureenclave"
	private static let keychainGroup = "com.qbix.groups.keychainshare"

	private static let uuidAccount = "com.qbix.groups.uuid"
	private static let uuidLegacyAccount = "com.yourapp.syncedUUID"

	private static let appAttestKeyIdTag = "com.qbix.groups.appattest.keyid"

	// MARK: - App Clip detection

	private var isRunningInAppClip: Bool {
		if #available(iOS 14.0, *) {
			return Bundle.main.bundleURL.pathExtension == "appclip"
				|| Bundle.main.bundleURL.lastPathComponent.contains(".appclip")
		}
		return false
	}

	private var effectiveAccessGroup: String? {
		return isRunningInAppClip ? nil : Self.keychainGroup
	}

	// MARK: - Secure Enclave master key (load or create)

	private func loadIdentityPrivateKeyIfExists() -> SecKey? {

		var query: [String: Any] = [
			kSecClass as String: kSecClassKey,
			kSecAttrApplicationTag as String: Self.identityKeyTag,
			kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
			kSecReturnRef as String: true
		]

		if let group = effectiveAccessGroup {
			query[kSecAttrAccessGroup as String] = group
		}

		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)

		guard status == errSecSuccess, item != nil else {
			return nil
		}

		return (item as! SecKey)

	}

	private func createIdentityPrivateKey() throws -> SecKey {

		var attrs: [String: Any] = [
			kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
			kSecAttrKeySizeInBits as String: 256,
			kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
			kSecAttrIsPermanent as String: true,
			kSecAttrApplicationTag as String: Self.identityKeyTag,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]

		if let group = effectiveAccessGroup {
			attrs[kSecAttrAccessGroup as String] = group
		}

		var error: Unmanaged<CFError>?
		guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
			throw error!.takeRetainedValue()
		}

		return key
	}

	private func identityPublicKeyBase64(_ key: SecKey) -> String? {
		guard let pub = SecKeyCopyPublicKey(key),
			  let data = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
			return nil
		}
		return data.base64EncodedString()
	}

	// MARK: - UUID (unchanged)

	private func loadUUID(account: String, accessGroup: String?) -> String? {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true
		]
		if let group = accessGroup {
			query[kSecAttrAccessGroup as String] = group
		}
		var item: CFTypeRef?
		if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
		   let data = item as? Data {
			return String(data: data, encoding: .utf8)
		}
		return nil
	}

	private func storeUUID(_ uuid: String, account: String, accessGroup: String?) {
		let data = uuid.data(using: .utf8)!
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: account,
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]
		if let group = accessGroup {
			query[kSecAttrAccessGroup as String] = group
		}
		SecItemDelete(query as CFDictionary)
		SecItemAdd(query as CFDictionary, nil)
	}

	private func canonicalUUID() -> String {
		if let uuid = loadUUID(account: Self.uuidAccount, accessGroup: effectiveAccessGroup) {
			return uuid
		}
		if let legacy = loadUUID(account: Self.uuidLegacyAccount, accessGroup: nil) {
			storeUUID(legacy, account: Self.uuidAccount, accessGroup: effectiveAccessGroup)
			return legacy
		}
		let fresh = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
		storeUUID(fresh, account: Self.uuidAccount, accessGroup: effectiveAccessGroup)
		return fresh
	}

	// MARK: - App Attest (secondary identity)

	private func attestInternal(
		completion: @escaping ([String: Any]?, String?) -> Void
	) {
		guard DCAppAttestService.shared.isSupported else {
			completion(nil, "App Attest not supported")
			return
		}

		let timestamp = Int(Date().timeIntervalSince1970)

		let challenge: [String: Any] = [
			"type": "attest",
			"timestamp": timestamp
		]

		guard let canonical = QUtils.serialize(challenge) else {
			completion(nil, "Failed to serialize attestation challenge")
			return
		}

		let hash = Data(SHA256.hash(data: canonical.data(using: .utf8)!))
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
					completion(nil, error?.localizedDescription ?? "Attestation failed")
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

	// MARK: - Signing entry point (Master → App Attest → Create Master)

	@objc func sign(_ args: [Any], callbackId: String?, bridge: QBridge) {

		guard let payload = args.first as? [String: Any],
			  let canonical = QUtils.serialize(payload),
			  let data = canonical.data(using: .utf8) else {
			bridge.sendEvent(callbackId ?? "", data: ["error": "Invalid payload"])
			return
		}

		// 1. Existing Secure Enclave master key (continuity)
		if let key = loadIdentityPrivateKeyIfExists() {
			signWithKey(key, data: data, bridge: bridge, callbackId: callbackId)
			return
		}

		// 2. App Attest (preferred if no master key yet)
		attestInternal { attestData, attestError in
			if let attestData = attestData {
				bridge.sendEvent(callbackId ?? "", data: attestData)
				return
			}

			// 3. Create Secure Enclave master key as last resort
			do {
				let key = try self.createIdentityPrivateKey()
				self.signWithKey(key, data: data, bridge: bridge, callbackId: callbackId)
			} catch {
				bridge.sendEvent(
					callbackId ?? "",
					data: ["error": attestError ?? error.localizedDescription]
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

		var error: Unmanaged<CFError>?
		guard let sig = SecKeyCreateSignature(
			key,
			.ecdsaSignatureMessageX962SHA256,
			data as CFData,
			&error
		) as Data? else {
			bridge.sendEvent(callbackId ?? "", data: ["error": error!.takeRetainedValue().localizedDescription])
			return
		}

		var out: [String: Any] = [
			"signature": sig.base64EncodedString(),
			"interactive": false
		]

		if let pub = identityPublicKeyBase64(key) {
			out["publicKey"] = pub
		}

		bridge.sendEvent(callbackId ?? "", data: out)
	}

	// MARK: - App Attest key storage

	private func loadAppAttestKeyId() -> String? {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: Self.appAttestKeyIdTag,
			kSecReturnData as String: true
		]
		if let group = effectiveAccessGroup {
			query[kSecAttrAccessGroup as String] = group
		}
		var item: CFTypeRef?
		if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
		   let data = item as? Data {
			return String(data: data, encoding: .utf8)
		}
		return nil
	}

	private func storeAppAttestKeyId(_ keyId: String) {
		let data = keyId.data(using: .utf8)!
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrAccount as String: Self.appAttestKeyIdTag,
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]
		if let group = effectiveAccessGroup {
			query[kSecAttrAccessGroup as String] = group
		}
		SecItemDelete(query as CFDictionary)
		SecItemAdd(query as CFDictionary, nil)
	}
}
