import Foundation
import UIKit
import MessageUI

@objc class QBridgePlugin: QBridgeBaseService {

    // MARK: - sign(command)
    @objc func sign(_ args: Any?, callbackId: String?) {
        guard
            let arr = args as? [Any],
            let payload = arr.first as? [String: Any]
        else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "Missing payload"])
            return
        }

        QUtils.signPayload(payload) { signData, error in
            if let error = error, !error.isEmpty {
                self.bridge.sendEvent(callbackId ?? "", data: ["error": error])
                return
            }
            if let signData = signData {
                self.bridge.sendEvent(callbackId ?? "", data: ["result": signData])
            } else {
                self.bridge.sendEvent(callbackId ?? "", data: ["error": "Unknown signing error"])
            }
        }
    }

    // MARK: - sign(payload, completion)
    @objc func sign(
        _ payload: [String: Any],
        completion: @escaping (_ signData: [String: Any]?, _ error: String?) -> Void
    ) {
        QUtils.signPayload(payload) { signData, error in
            if let dict = signData as? [String: Any] {
                completion(dict, error)
            } else if let error = error, !error.isEmpty {
                completion(nil, error)
            } else {
                completion(nil, "Invalid or empty signing data")
            }
        }
    }

    // MARK: - info(command)
    @objc func info(_ args: Any?, callbackId: String?) {
        let info = QUtils.appInfo()
        bridge.sendEvent(callbackId ?? "", data: ["result": info])
    }

    // MARK: - sendEmail(command)
    /**
     Presents MFMailComposeViewController with optional image attachment
     
     Parameters in args:
     - recipients: [String] - Array of email addresses
     - subject: String - Email subject (default: "Shared from Groups")
     - body: String - Email body (can be HTML if isHTML is true)
     - isHTML: Bool - Whether body is HTML (default: true)
     - imageBase64: String? - Optional base64-encoded image data (without data URI prefix)
     - imageFilename: String? - Optional filename for attachment (default: "image.jpg")
     
     Example from JavaScript:
     ```
     await QBridge.call("Share.sendEmail", {
         recipients: ["user@example.com"],
         subject: "Check this out",
         body: "<p>Here's the link: <a href='...'>...</a></p>",
         isHTML: true,
         imageBase64: "base64data...",  // Optional
         imageFilename: "shared.jpg"     // Optional
     });
     ```
     */
    @objc func sendEmail(args: Any?, callbackId: String?) {
        guard let arr = args as? [Any],
              let params = arr.first as? [String: Any] else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "Missing parameters"])
            return
        }
        
        guard let presentingVC = bridge.presentingController else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "No presenting controller"])
            return
        }
        
        guard MFMailComposeViewController.canSendMail() else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "Device not configured to send email"])
            return
        }
        
        let recipients = params["recipients"] as? [String] ?? []
        let subject = params["subject"] as? String ?? "Shared from Groups"
        let body = params["body"] as? String ?? ""
        let isHTML = params["isHTML"] as? Bool ?? true
        let imageBase64 = params["imageBase64"] as? String
        let imageFilename = params["imageFilename"] as? String ?? "image.jpg"
        
        DispatchQueue.main.async {
            let composer = MFMailComposeViewController()
            composer.mailComposeDelegate = presentingVC as? MFMailComposeViewControllerDelegate
            composer.setToRecipients(recipients)
            composer.setSubject(subject)
            composer.setMessageBody(body, isHTML: isHTML)
            
            // Attach image if provided
            if let base64 = imageBase64, !base64.isEmpty {
                if let imageData = Data(base64Encoded: base64) {
                    // Determine MIME type from filename extension
                    let mimeType = self.mimeTypeForFilename(imageFilename)
                    composer.addAttachmentData(imageData, mimeType: mimeType, fileName: imageFilename)
                    print("[QBridgePlugin] Email: Attached image (\(imageData.count) bytes) as \(imageFilename)")
                } else {
                    print("[QBridgePlugin] Email: Warning - Failed to decode base64 image data")
                }
            }
            
            presentingVC.present(composer, animated: true) {
                self.bridge.sendEvent(callbackId ?? "", data: ["result": "presented"])
            }
        }
    }

    // MARK: - sendSMS(command)
    /**
     Presents MFMessageComposeViewController with optional MMS image attachment
     
     Parameters in args:
     - recipients: [String] - Array of phone numbers
     - body: String - SMS/MMS message body text
     - imageBase64: String? - Optional base64-encoded image data (without data URI prefix)
     - imageFilename: String? - Optional filename hint for type detection (default: "image.jpg")
     
     Example from JavaScript:
     ```
     await QBridge.call("Share.sendSMS", {
         recipients: ["+1234567890"],
         body: "Check this out: https://...",
         imageBase64: "base64data...",  // Optional - makes it MMS
         imageFilename: "shared.jpg"     // Optional
     });
     ```
     
     Notes:
     - If imageBase64 is provided, this becomes an MMS (multimedia message)
     - The image will be attached using addAttachmentData with UTI type identifier
     - Supports common image formats: JPEG, PNG, GIF
     */
    @objc func sendSMS(args: Any?, callbackId: String?) {
        guard let arr = args as? [Any],
              let params = arr.first as? [String: Any] else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "Missing parameters"])
            return
        }
        
        guard let presentingVC = bridge.presentingController else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "No presenting controller"])
            return
        }
        
        guard MFMessageComposeViewController.canSendText() else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "Device not configured to send SMS"])
            return
        }
        
        let recipients = params["recipients"] as? [String] ?? []
        let body = params["body"] as? String ?? ""
        let imageBase64 = params["imageBase64"] as? String
        let imageFilename = params["imageFilename"] as? String ?? "image.jpg"
        
        DispatchQueue.main.async {
            let composer = MFMessageComposeViewController()
            composer.messageComposeDelegate = presentingVC as? MFMessageComposeViewControllerDelegate
            composer.recipients = recipients
            composer.body = body
            
            // Attach image for MMS if provided
            if let base64 = imageBase64, !base64.isEmpty {
                if let imageData = Data(base64Encoded: base64) {
                    // Determine UTI type identifier from filename
                    let typeIdentifier = self.utiTypeForFilename(imageFilename)
                    composer.addAttachmentData(imageData, 
                                             typeIdentifier: typeIdentifier, 
                                             filename: imageFilename)
                    print("[QBridgePlugin] SMS: Attached image (\(imageData.count) bytes) as \(imageFilename) with UTI \(typeIdentifier)")
                } else {
                    print("[QBridgePlugin] SMS: Warning - Failed to decode base64 image data")
                }
            }
            
            presentingVC.present(composer, animated: true) {
                self.bridge.sendEvent(callbackId ?? "", data: ["result": "presented"])
            }
        }
    }

    // MARK: - Helper: Determine MIME type from filename
    /**
     Returns MIME type string based on file extension
     Used for email attachments
     */
    private func mimeTypeForFilename(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        case "webp":
            return "image/webp"
        default:
            return "application/octet-stream"
        }
    }
    
    // MARK: - Helper: Determine UTI type from filename
    /**
     Returns UTI (Uniform Type Identifier) string based on file extension
     Used for MMS attachments
     
     Common UTI types:
     - public.jpeg - JPEG images
     - public.png - PNG images
     - public.gif - GIF images
     - public.heic - HEIC images
     */
    private func utiTypeForFilename(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg":
            return "public.jpeg"
        case "png":
            return "public.png"
        case "gif":
            return "public.gif"
        case "heic":
            return "public.heic"
        default:
            return "public.jpeg"  // Default to JPEG for unknown types
        }
    }

    // MARK: - openMainApp(command) - Fallback if direct presentation doesn't work
    /**
     Opens the main app with shared data
     Used as fallback if presenting composers directly from extension fails
     
     Parameters in args:
     - action: String - Action type (default: "compose")
     - contactIds: [String] - Array of contact IDs
     - sharedLink: String? - Optional shared URL
     - sharedImage: String? - Optional shared image URL or data URI
     
     Flow:
     1. Saves pending action to App Group shared container
     2. Opens main app via custom URL scheme (groups://share/...)
     3. Main app reads pending action and handles it
     */
    @objc func openMainApp(args: Any?, callbackId: String?) {
        guard let arr = args as? [Any],
              let params = arr.first as? [String: Any] else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "Missing parameters"])
            return
        }
        
        let action = params["action"] as? String ?? "compose"
        let contactIds = params["contactIds"] as? [String] ?? []
        let sharedLink = params["sharedLink"] as? String
        let sharedImage = params["sharedImage"] as? String
        
        // Save data to App Group for main app to retrieve
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.qbix.groups.common"
        ) {
            let documentsPath = containerURL.appendingPathComponent("Documents")
            let pendingPath = documentsPath.appendingPathComponent("pending_action.json")
            
            let payload: [String: Any] = [
                "action": action,
                "contactIds": contactIds,
                "sharedLink": sharedLink ?? NSNull(),
                "sharedImage": sharedImage ?? NSNull(),
                "timestamp": Date().timeIntervalSince1970
            ]
            
            do {
                try FileManager.default.createDirectory(at: documentsPath, withIntermediateDirectories: true)
                let jsonData = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
                try jsonData.write(to: pendingPath)
                print("[QBridgePlugin] Saved pending action: \(action)")
            } catch {
                print("[QBridgePlugin] Failed to save pending action: \(error)")
                bridge.sendEvent(callbackId ?? "", data: ["error": "Failed to save data: \(error.localizedDescription)"])
                return
            }
        }
        
        // Build URL
        var components = URLComponents()
        components.scheme = "groups"  // Your custom URL scheme
        components.host = "share"
        components.path = "/\(action)"
        
        var queryItems = [URLQueryItem]()
        if !contactIds.isEmpty {
            queryItems.append(URLQueryItem(name: "contacts", value: contactIds.joined(separator: ",")))
        }
        if let link = sharedLink {
            queryItems.append(URLQueryItem(name: "link", value: link))
        }
        if let image = sharedImage {
            queryItems.append(URLQueryItem(name: "image", value: image))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        
        guard let url = components.url,
              let extensionContext = bridge.extensionContext else {
            bridge.sendEvent(callbackId ?? "", data: ["error": "Failed to build URL or get extension context"])
            return
        }
        
        print("[QBridgePlugin] Attempting to open URL: \(url)")
        
        extensionContext.open(url) { success in
            print("[QBridgePlugin] Open URL result: \(success)")
            if success {
                self.bridge.sendEvent(callbackId ?? "", data: ["result": "success"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    extensionContext.completeRequest(returningItems: [])
                }
            } else {
                self.bridge.sendEvent(callbackId ?? "", data: ["error": "Failed to open main app"])
            }
        }
    }

    // MARK: - close()
    /**
     Closes the share extension UI
     Called after successful send or when user cancels
     */
    @objc func close(args: Any?, callbackId: String?) {
        DispatchQueue.main.async {
            QBridgePluginCloser.close(self.bridge.presentingController)
        }
    }
}
