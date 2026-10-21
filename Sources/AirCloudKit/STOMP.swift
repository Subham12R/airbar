import Foundation

/// The bits of STOMP 1.2 that airCloud's notification websocket uses.
enum STOMP {
    /// CONNECT + SUBSCRIBE in one websocket message, as the official app sends them.
    static func connectAndSubscribe(token: String, familyId: String, subscriptionId: String = UUID().uuidString) -> String {
        "CONNECT\naccept-version:1.1,1.2\nheart-beat:10000,10000\nAuthorization:Bearer \(token)\n\n\0\n"
            + "SUBSCRIBE\nid:\(subscriptionId)\ndestination:/notification/\(familyId)/\(familyId)\nack:auto\n\n\0"
    }

    enum Frame: Equatable {
        /// The server accepted the connection; `authenticated` is false when the token was rejected
        /// (airCloud still answers CONNECTED, just without a `user-name` header).
        case connected(authenticated: Bool)
        case units([[String: Any]])
        case other

        static func == (a: Frame, b: Frame) -> Bool {
            switch (a, b) {
            case let (.connected(x), .connected(y)): return x == y
            case let (.units(x), .units(y)): return x.count == y.count
            case (.other, .other): return true
            default: return false
            }
        }
    }

    static func parse(_ raw: String) -> Frame {
        let text = raw.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("CONNECTED") {
            return .connected(authenticated: text.contains("user-name:"))
        }
        var body = text
        if let r = text.range(of: "MESSAGE") {
            let frame = text[r.lowerBound...]
            if let split = frame.range(of: "\n\n") {
                body = String(frame[split.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return .other }
        return .units(list)
    }
}
