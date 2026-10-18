import Foundation
import Security

/// What the iPad knows about the Mac it is paired with: the token, and the page link it came from when there was one.
struct Pairing: Equatable, Sendable {
    let token: String
    /// The Mac's web page, only when the pasted text was the whole link. Used by the Board button.
    let page: URL?

    /// "Copy iPad link" on the Mac puts `http://<host>.local:8710/<token>/` on the clipboard. The token is the first
    /// path segment. A bare token (22+ base64url characters) is taken as is.
    static func parse(_ text: String) -> Pairing? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: t), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil {
            guard let first = url.pathComponents.first(where: { $0 != "/" }), valid(first) else { return nil }
            return Pairing(token: first, page: url)
        }
        return valid(t) ? Pairing(token: t, page: nil) : nil
    }

    private static func valid(_ s: String) -> Bool {
        s.count >= 16 && s.unicodeScalars.allSatisfy { ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
}

/// The pasted link lives in the Keychain, never in UserDefaults or a log.
enum Vault {
    private static let service = "com.dhrlabs.pencilpad.ipad"
    private static let account = "link"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> Pairing? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Pairing.parse(text)
    }

    static func save(_ text: String) {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
