import Foundation

enum QBridgeNetworkError: Error { case invalidURL, noResponse }

class QBridgeNetwork {
	static func postJSON(_ payload: [String: Any]?) throws -> [String: Any] {
		guard let urlStr = payload?["url"] as? String, let url = URL(string: urlStr) else {
			throw QBridgeNetworkError.invalidURL
		}
		let data = try JSONSerialization.data(withJSONObject: payload?["data"] ?? [:])
		var req = URLRequest(url: url)
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req.httpBody = data

		let sem = DispatchSemaphore(value: 0)
		var result: [String: Any]? = nil
		var caughtError: Error?

		URLSession.shared.dataTask(with: req) { body, _, err in
			defer { sem.signal() }
			if let err = err { caughtError = err; return }
			if let body = body {
				result = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
			}
		}.resume()

		sem.wait()
		if let e = caughtError { throw e }
		return result ?? [:]
	}
}
