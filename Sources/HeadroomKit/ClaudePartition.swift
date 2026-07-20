import Foundation
#if os(macOS)
import Security
#endif

/// Predicts, WITHOUT prompting, whether this process can read a Keychain item's secret.
///
/// ## Why this exists (1.6.5)
/// `Claude Code-credentials` is Claude Code's own item, and macOS re-scopes its
/// **partition list** (`ACLAuthorizationPartitionID`) onto whichever app last wrote it —
/// Claude Code does this on every token refresh, evicting Headroom's team. Reading the
/// SECRET of an item whose partition list doesn't include our team triggers the XARA
/// (Cross-Application Resource Access) password prompt, and that prompt CANNOT be
/// suppressed by any flag (`kSecUseAuthenticationUIFail`, `LAContext.interactionNotAllowed`
/// both fail against it — verified: Apple DTS forum thread 98182, steipete/CodexBar#458).
///
/// So the only way to never prompt is to never ATTEMPT the secret read when we'd be denied.
/// Reading the item's ACL *metadata* (this file) does NOT touch the secret, so it never
/// prompts and never mutates the partition list. We read the partition list, check whether
/// our own signing identity is in it, and only then let the collector read the token.
public enum ClaudePartition {

    /// The partition list of `service`, or nil if it can't be determined (item missing, off
    /// macOS, or an API error). Metadata-only: never prompts, never churns the list.
    public static func partitions(service: String) -> [String]? {
        #if os(macOS)
        // kSecReturnRef (not kSecReturnData) -> a reference to the item, no secret accessed.
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let anyItem = ref else { return nil }
        let item = anyItem as! SecKeychainItem

        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess,
              let access else { return nil }
        var aclArray: CFArray?
        guard SecAccessCopyACLList(access, &aclArray) == errSecSuccess,
              let acls = aclArray as? [SecACL] else { return nil }

        for acl in acls {
            let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard auths.contains("ACLAuthorizationPartitionID") else { continue }
            var appList: CFArray?
            var desc: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &appList, &desc, &prompt) == errSecSuccess,
                  let hex = desc as String? else { return nil }
            return parsePartitions(hexDescription: hex)
        }
        return []   // item exists but has no partition ACL -> unrestricted
        #else
        return nil
        #endif
    }

    /// Whether `service`'s partition list admits this process — true if our signing team (or,
    /// for an unsigned/ad-hoc build, our cdhash) is present, or the list is unrestricted /
    /// carries `apple:`. **Fails CLOSED:** if the partition list can't be read at all, return
    /// false so we do NOT attempt the secret read. The whole point of this gate is to never
    /// prompt; a stale card (last-good) is the correct trade when membership can't be confirmed.
    public static func admitsSelf(service: String) -> Bool {
        guard let parts = partitions(service: service) else { return false }   // can't confirm -> skip
        if parts.isEmpty { return true }                                       // unrestricted item
        let mine = ownIdentifiers()
        return parts.contains { $0 == "apple:" || mine.contains($0) }
    }

    /// Pure, testable: decode the hex-encoded partition-ACL description into the Partitions
    /// array. The `ACLAuthorizationPartitionID` description arrives as a hex string of an XML
    /// property list `{ Partitions: [ "apple-tool:", "teamid:XXXX", "cdhash:…" ] }`.
    public static func parsePartitions(hexDescription: String) -> [String] {
        guard let data = dataFromHex(hexDescription),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let parts = dict["Partitions"] as? [String] else { return [] }
        return parts
    }

    /// Our own partition identifiers: `teamid:<team>` for a Developer-ID/team-signed build,
    /// and `cdhash:<hex>` as a fallback for an unsigned/ad-hoc build.
    static func ownIdentifiers() -> [String] {
        #if os(macOS)
        var out: [String] = []
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code
        else { return out }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return out }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return out }
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            out.append("teamid:\(team)")
        }
        if let cd = info[kSecCodeInfoUnique as String] as? Data {
            out.append("cdhash:\(cd.map { String(format: "%02x", $0) }.joined())")
        }
        return out
        #else
        return []
        #endif
    }

    /// Decode a hex string (even length, [0-9a-fA-F]) into bytes; nil on malformed input.
    static func dataFromHex(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nib(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x61...0x66: return b - 0x61 + 10
            case 0x41...0x46: return b - 0x41 + 10
            default: return nil
            }
        }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nib(chars[i]), let lo = nib(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}
