import Foundation
import Contacts
import ContactsUI

@objcMembers
class QUsersBridgePlugin: QBridgeBaseService {

	// MARK: - Shared instances
	static let cm = QContactsManager()
	static let cu = QContactsUI()
	static var updates = [[String: Any]]()
	static let contactKeys: [String] = [
		CNContactTypeKey,
		CNContactEmailAddressesKey,
		CNContactPhoneNumbersKey,
		CNContactSocialProfilesKey,
		CNContactUrlAddressesKey,
		CNContactPostalAddressesKey,
		CNContactGivenNameKey,
		CNContactMiddleNameKey,
		CNContactFamilyNameKey,
		CNContactNamePrefixKey,
		CNContactNameSuffixKey,
		CNContactNicknameKey,
		CNContactOrganizationNameKey,
		CNContactJobTitleKey,
		CNContactBirthdayKey,
		CNContactDatesKey,
		CNContactImageDataAvailableKey,
		CNContactImageDataKey,
		CNContactThumbnailImageDataKey
	]
	static let socialProfileKeys = ["urlString", "username", "userIdentifier", "service"]

	// MARK: - Helpers
	private func sendError(_ callbackId: String?, _ message: String) {
		bridge.sendEvent(callbackId ?? "", data: ["error": message])
	}


	@objc func permission(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let requestIfNotAvailable = (arr.first as? Bool) ?? false

		Self.cm.permission(
			completionHandler: { granted, limited, status in
				let message: [Any] = [granted, limited, status.rawValue]
				self.bridge.sendEvent(callbackId ?? "", data: ["result": message])
			},
			requestIfNotAvailable: requestIfNotAvailable
		)
	}



	@objc func allContainers(args: Any?, callbackId: String?) {
		let containers = Self.cm.allContainers(ids: nil) ?? []
		let message = containers.map { QUsers.serializeContainer($0) }
		bridge.sendEvent(callbackId ?? "", data: ["result": message])
	}

	@objc func containerOfContact(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let contactId = arr.first as? String else {
			sendError(callbackId, "Missing contactId")
			return
		}

		let container = Self.cm.containerOfContact(withId: contactId)
		let message = container != nil ? QUsers.serializeContainer(container!) : [:]
		bridge.sendEvent(callbackId ?? "", data: ["result": message])
	}

	@objc func containerOfGroup(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let groupId = arr.first as? String else {
			sendError(callbackId, "Missing groupId")
			return
		}

		let container = Self.cm.containerOfGroup(withId: groupId)
		let message = container != nil ? QUsers.serializeContainer(container!) : [:]
		bridge.sendEvent(callbackId ?? "", data: ["result": message])
	}

	@objc func allGroups(args: Any?, callbackId: String?) {
		let groups = Self.cm.allGroups()
		let message = groups.map { QUsers.serializeGroup($0) }
		bridge.sendEvent(callbackId ?? "", data: ["result": message])
	}

	@objc func groupById(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let groupId = arr.first as? String else {
			sendError(callbackId, "Missing groupId")
			return
		}

		let group = Self.cm.groupById(groupId)
		let message = group != nil ? QUsers.serializeGroup(group!) : [:]
		bridge.sendEvent(callbackId ?? "", data: ["result": message])
	}

	@objc func groupsFromContainer(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let containerId = arr.first as? String else {
			sendError(callbackId, "Missing containerId")
			return
		}

		Self.cm.groupsFromContainer(containerId) { groups, error in
			guard let groups else {
				self.sendError(callbackId, error?.localizedDescription ?? "Unknown error")
				return
			}
			let message = groups.map { QUsers.serializeGroup($0) }
			self.bridge.sendEvent(callbackId ?? "", data: ["result": message])
		}
	}

	@objc func allContacts(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let options = (arr.first as? [String: Any]) ?? [:]

		let sortOrderNum = options["sortOrder"] as? NSNumber
		let unifyResultsNum = options["unifyResults"] as? NSNumber
		let keysToFetch = options["keysToFetch"] as? [String]
		let keysToExclude = options["keysToExclude"] as? [String]

		let sortOrder = CNContactSortOrder(rawValue: sortOrderNum?.intValue ?? CNContactSortOrder.none.rawValue) ?? .none
		let unifyResults = unifyResultsNum?.boolValue ?? false

		Self.cm.allContacts(
			sortOrder: sortOrder,
			unifyResults: unifyResults,
			keysToFetch: keysToFetch,
			keysToExclude: keysToExclude
		) { contacts, error in
			guard let contacts else {
				self.sendError(callbackId, error?.localizedDescription ?? "Unknown error")
				return
			}
			let message = contacts.map {
				QUsers.serializeContact($0, keysToFetch: keysToFetch, keysToExclude: keysToExclude)
			}
			self.bridge.sendEvent(callbackId ?? "", data: ["result": message])
		}
	}

	@objc func unifiedContactFromContactId(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let contactId = (arr.count > 0 ? arr[0] as? String : nil)
		let options = (arr.count > 1 ? arr[1] as? [String: Any] : nil) ?? [:]
		let keysToFetch = options["keysToFetch"] as? [String]
		let keysToExclude = options["keysToExclude"] as? [String]

		guard let contactId else {
			sendError(callbackId, "Missing contactId")
			return
		}

		let contact = Self.cm.unifiedContactById(contactId, keysToFetch: keysToFetch, keysToExclude: keysToExclude)
		if let contact {
			let message = QUsers.serializeContact(contact, keysToFetch: keysToFetch, keysToExclude: keysToExclude)
			bridge.sendEvent(callbackId ?? "", data: ["result": message])
		} else {
			sendError(callbackId, "Contact not found")
		}
	}
	
	@objc func contactById(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let contactId = (arr.count > 0 ? arr[0] as? String : nil)
		let options = (arr.count > 1 ? arr[1] as? [String: Any] : nil) ?? [:]

		let unifyResults = options["unifyResults"] as? Bool ?? false
		let keysToFetch = options["keysToFetch"] as? [String]
		let keysToExclude = options["keysToExclude"] as? [String]

		guard let contactId else {
			sendError(callbackId, "Missing contactId")
			return
		}

		let contact = Self.cm.contactById(contactId,
			unifyResults: unifyResults,
			keysToFetch: keysToFetch,
			keysToExclude: keysToExclude
		)

		let message = QUsers.serializeContact(contact, keysToFetch: keysToFetch, keysToExclude: keysToExclude)
		bridge.sendEvent(callbackId ?? "", data: ["result": message])
	}

	@objc func contactsByIds(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let contactIds = (arr.count > 0 ? arr[0] as? [String] : nil)
		let options = (arr.count > 1 ? arr[1] as? [String: Any] : nil) ?? [:]

		let unifyResults = options["unifyResults"] as? Bool ?? false
		let keysToFetch = options["keysToFetch"] as? [String]
		let keysToExclude = options["keysToExclude"] as? [String]

		let contacts = Self.cm.contactsByIds(
			contactIds ?? [],
			unifyResults: unifyResults,
			keysToFetch: keysToFetch,
			keysToExclude: keysToExclude
		)

		let messages = contacts.map { obj -> Any in
			if let c = obj as? CNContact {
				return QUsers.serializeContact(c, keysToFetch: keysToFetch, keysToExclude: keysToExclude)
			}
			return NSNull()
		}

		bridge.sendEvent(callbackId ?? "", data: ["result": messages])
	}

	@objc func containerIdFromContact(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let contactId = arr.first as? String else {
			sendError(callbackId, "Missing contactId")
			return
		}

		let containerId = Self.cm.containerIdFromContact(contactId)
		bridge.sendEvent(callbackId ?? "", data: ["result": containerId ?? ""])
	}

	@objc func contactsFromContainer(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []

		let containerId = (arr.count > 0 ? arr[0] as? String : nil)
		let unifyResults = (arr.count > 1 ? (arr[1] as? Bool) ?? false : false)
		let keysToFetch = (arr.count > 2 ? arr[2] as? [String] : nil)
		let keysToExclude = (arr.count > 3 ? arr[3] as? [String] : nil)

		Self.cm.contactsFromContainer(containerId ?? "",
			sortOrder: .userDefault,
			unifyResults: unifyResults,
			keysToFetch: keysToFetch,
			keysToExclude: keysToExclude
		) { contacts, error in
			guard let contacts else {
				self.sendError(callbackId, error?.localizedDescription ?? "Unknown error")
				return
			}
			let message = contacts.map {
				QUsers.serializeContact($0, keysToFetch: keysToFetch, keysToExclude: keysToExclude)
			}
			self.bridge.sendEvent(callbackId ?? "", data: ["result": message])
		}
	}

	@objc func contactsFromGroup(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let groupId = (arr.count > 0 ? arr[0] as? String : nil)
		let options = (arr.count > 1 ? arr[1] as? [String: Any] : nil) ?? [:]

		let sortOrder = CNContactSortOrder(rawValue: (options["sortOrder"] as? Int ?? CNContactSortOrder.userDefault.rawValue)) ?? .userDefault
		let unifyResults = options["unifyResults"] as? Bool ?? false
		let keysToFetch = options["keysToFetch"] as? [String]
		let keysToExclude = options["keysToExclude"] as? [String]

		Self.cm.contactsFromGroup(groupId ?? "",
			sortOrder: sortOrder,
			unifyResults: unifyResults,
			keysToFetch: keysToFetch,
			keysToExclude: keysToExclude
		) { contacts, error in
			guard let contacts else {
				self.sendError(callbackId, error?.localizedDescription ?? "Unknown error")
				return
			}
			let message = contacts.map {
				QUsers.serializeContact($0, keysToFetch: keysToFetch, keysToExclude: keysToExclude)
			}
			self.bridge.sendEvent(callbackId ?? "", data: ["result": message])
		}
	}

	@objc func contactIdsFromGroup(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let groupId = arr.first as? String, !groupId.isEmpty else {
			sendError(callbackId, "contactIdsFromGroup: Missing or invalid groupId")
			return
		}

		let options = (arr.count > 1 ? arr[1] as? [String: Any] : nil) ?? [:]
		let sortOrder = CNContactSortOrder(rawValue: (options["sortOrder"] as? Int ?? CNContactSortOrder.none.rawValue)) ?? .none
		let unifyResults = options["unifyResults"] as? Bool ?? false

		Self.cm.contactsFromGroup(groupId,
			sortOrder: sortOrder,
			unifyResults: unifyResults,
			keysToFetch: ["id"],
			keysToExclude: nil
		) { contacts, error in
			if let error {
				self.sendError(callbackId, error.localizedDescription)
				return
			}

			let ids = (contacts ?? []).compactMap { $0.identifier }
			self.bridge.sendEvent(callbackId ?? "", data: ["result": ids])
		}
	}

	@objc func discoverLinkedContacts(args: Any?, callbackId: String?) {
		Self.cm.discoverLinkedContacts { success in
			self.bridge.sendEvent(callbackId ?? "", data: ["result": success])
		}
	}

	@objc func contactsFromAnyContactId(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let contactId = (arr.count > 0 ? arr[0] as? String : nil)
		let options = (arr.count > 1 ? arr[1] as? [String: Any] : nil) ?? [:]
		let keysToFetch = options["keysToFetch"] as? [String]
		let keysToExclude = options["keysToExclude"] as? [String]

		let contacts = Self.cm.contactsFromAnyContactId(contactId ?? "",
			keysToFetch: keysToFetch,
			keysToExclude: keysToExclude
		)

		let message = contacts.map {
			QUsers.serializeContact($0, keysToFetch: keysToFetch, keysToExclude: keysToExclude)
		}
		bridge.sendEvent(callbackId ?? "", data: ["result": message])
	}

	@objc func addContact(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let contactInfo = arr.first as? [String: Any] else {
			sendError(callbackId, "Missing contact info")
			return
		}

		let options = (arr.count > 1 ? arr[1] as? [String: Any] : nil) ?? [:]
		let containerId = options["containerId"] as? String

		let contact = CNMutableContact()
		guard QUsers.unserializeContact(contact, from: contactInfo) else {
			sendError(callbackId, "Invalid contact data")
			return
		}

		Self.cm.addContact(contact, toContainerId: containerId) { success, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": contact.identifier])
			}
		}
	}

	@objc func updateContact(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let contactInfo = arr.first as? [String: Any] else {
			sendError(callbackId, "Missing contactInfo")
			return
		}
		let options = (arr.count > 1 ? arr[1] as? [String: Any] : nil) ?? [:]
		let country = options["country"] as? String

		guard let contactId = contactInfo["id"] as? String, !contactId.isEmpty else {
			sendError(callbackId, "Missing or invalid contactId")
			return
		}

		let contacts = Self.cm.contactsFromAnyContactId(contactId, keysToFetch: nil, keysToExclude: nil)
		guard !contacts.isEmpty else {
			self.bridge.sendEvent(callbackId ?? "", data: ["result": []])
			return
		}

		var updatedContacts = [CNMutableContact]()
		for contact in contacts {
			let mutable = contact.mutableCopy() as! CNMutableContact
			if QUsers.unserializeContact(mutable, from: contactInfo) {
				updatedContacts.append(mutable)
			}
		}

		guard !updatedContacts.isEmpty else {
			self.bridge.sendEvent(callbackId ?? "", data: ["result": []])
			return
		}

		Self.cm.updateContacts(updatedContacts) { contactIds, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": contactIds])
			}
		}
	}

	@objc func deleteContact(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let contactId = arr.first as? String else {
			sendError(callbackId, "Missing contactId")
			return
		}

		let contacts = Self.cm.contactsFromAnyContactId(contactId, keysToFetch: nil, keysToExclude: nil)
		guard !contacts.isEmpty else {
			self.bridge.sendEvent(callbackId ?? "", data: ["result": []])
			return
		}

		Self.cm.deleteContacts(contacts) { deletedIds, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": deletedIds])
			}
		}
	}

	@objc func addGroup(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let groupInfo = arr.first as? [String: Any] else {
			sendError(callbackId, "Missing group info")
			return
		}
		let containerId = (arr.count > 1 ? arr[1] as? String : nil)
		let group = CNMutableGroup()

		guard QUsers.unserializeGroup(group, from: groupInfo) else {
			sendError(callbackId, "Invalid group info")
			return
		}

		Self.cm.addGroup(group, toContainerId: containerId) { success, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": group.identifier])
			}
		}
	}
	
	@objc func updateGroup(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let groupInfo = arr.first as? [String: Any],
			  let groupId = groupInfo["id"] as? String else {
			sendError(callbackId, "Missing group id")
			return
		}

		guard let existingGroup = Self.cm.groupById(groupId)?.mutableCopy() as? CNMutableGroup else {
			sendError(callbackId, "Group not found")
			return
		}

		guard let name = groupInfo["name"] as? String, !name.isEmpty else {
			self.bridge.sendEvent(callbackId ?? "", data: ["result": false])
			return
		}

		existingGroup.name = name
		Self.cm.updateGroup(existingGroup) { success, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": success])
			}
		}
	}

	@objc func deleteGroup(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		let groupId = arr.first as? String

		guard let groupId,
			  let group = Self.cm.groupById(groupId)?.mutableCopy() as? CNGroup else {
			sendError(callbackId, "Missing or invalid group id")
			return
		}

		Self.cm.deleteGroup(group) { success, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": success])
			}
		}
	}

	@objc func addContactToGroup(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard arr.count >= 2,
			  let contactId = arr[0] as? String,
			  let groupId = arr[1] as? String else {
			sendError(callbackId, "Missing arguments")
			return
		}
		let containerId = arr.count > 2 ? (arr[2] as? String) : nil

		guard let contact = Self.cm.contactById(contactId, unifyResults: false,
												keysToFetch: ["id"], keysToExclude: nil),
			  let group = Self.cm.groupById(groupId) else {
			sendError(callbackId, "Invalid contact or group id")
			return
		}

		Self.cm.addContactToGroup(
			contact: contact,
			group: group,
			inContainerId: containerId
		) { success, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": success])
			}
		}

	}

	@objc func addUnifiedContactsToGroups(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard arr.count > 1,
			  let contactIds = arr[0] as? [String],
			  let groupIds = arr[1] as? [String] else {
			sendError(callbackId, "addUnifiedContactsToGroups: Missing arguments")
			return
		}
		let containerId = arr.count > 2 ? (arr[2] as? String) : nil
		let groups = Self.cm.groupsByIds(groupIds)

		Self.cm.addUnifiedContactsToGroups(
			contactIds: contactIds,
			groups: groups,
			inContainerId: containerId
		) { success, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": success])
			}
		}
	}

	@objc func removeContactFromGroup(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard arr.count >= 2,
			  let contactId = arr[0] as? String,
			  let groupId = arr[1] as? String else {
			sendError(callbackId, "Missing arguments")
			return
		}

		guard let contact = Self.cm.contactById(contactId, unifyResults: false,
												keysToFetch: ["id"], keysToExclude: nil),
			  let group = Self.cm.groupById(groupId) else {
			sendError(callbackId, "Invalid contact or group id")
			return
		}

		Self.cm.removeContactFromGroup(
			contact: contact,
			group: group
		) { success, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": success])
			}
		}

	}

	@objc func removeUnifiedContactsFromGroups(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard arr.count > 1,
			  let contactIds = arr[0] as? [String],
			  let groupIds = arr[1] as? [String] else {
			sendError(callbackId, "Missing arguments")
			return
		}


		let groups = Self.cm.groupsByIds(groupIds)
		Self.cm.removeUnifiedContactsFromGroups(
			contactIds: contactIds,
			groups: groups
		) { success, error in
			if let error {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": error.localizedDescription])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["result": success])
			}
		}

	}

	@objc func UICreate(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let contactInfo = arr.first as? [String: Any] else {
			sendError(callbackId, "Missing contact info")
			return
		}
		let contact = CNMutableContact()
		_ = QUsers.unserializeContact(contact, from: contactInfo)
		Self.cu.create(
			contact: contact,
			parentContainer: nil
		) { newContact in
			if let newContact {
				let message = QUsers.serializeContact(newContact)
				self.bridge.sendEvent(callbackId ?? "", data: ["result": message])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": "Failed to create contact"])
			}
		}

	}

	@objc func UIEdit(args: Any?, callbackId: String?) {
		let arr = args as? [Any] ?? []
		guard let contactId = arr.first as? String else {
			sendError(callbackId, "Missing contact id")
			return
		}
		Self.cu.edit(
			contactId: contactId,
			parentContainer: nil
		) { editedContact in
			if let editedContact {
				let message = QUsers.serializeContact(editedContact)
				self.bridge.sendEvent(callbackId ?? "", data: ["result": message])
			} else {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": "Edit canceled or failed"])
			}
		}

	}

	@objc func UIPick(args _: Any?, callbackId: String?) {
		Self.cu.pick { contacts in
			if contacts.isEmpty {
				self.bridge.sendEvent(callbackId ?? "", data: ["error": "Picker canceled"])
			} else {
				let message = contacts.map { QUsers.serializeContact($0) }
				self.bridge.sendEvent(callbackId ?? "", data: ["result": message])
			}
		}
	}

	@objc func UIPickAccess(args _: Any?, callbackId: String?) {
		if #available(iOS 18.0, *) {
			QContactsUI().pickAccess { contacts, error in
				if let contacts, !contacts.isEmpty {
					let result = contacts.map { QUsers.serializeContact($0) }
					self.bridge.sendEvent(callbackId ?? "", data: ["result": result])
				} else {
					let code = error?.localizedDescription ?? "Unknown error"
					self.bridge.sendEvent(callbackId ?? "", data: ["error": code])
				}
			}
		} else {
			sendError(callbackId, "Requires iOS 18 or later")
		}
	}
}
