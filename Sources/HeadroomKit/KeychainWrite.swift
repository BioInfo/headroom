import Foundation
#if os(macOS)
import Security
#endif

/// In-process Keychain writes — the write-side counterpart to `KeychainRead`.
///
/// ## Why not `/usr/bin/security`
/// Shelling out spawns a *different binary* for every write, and macOS scopes Keychain trust
/// to the requesting binary's identity. So `security add-generic-password -U` prompts on the
/// capture-away write, prompts again on the live-slot write, and a fallback read can prompt a
/// third time — three dialogs for one switch, none of which "Always Allow" durably silences,
/// because each `security` invocation is a fresh, unrelated process asking again.
///
/// Writing in-process asks as Headroom.app: a single "Always Allow" adds *this signed app* to
/// the item's ACL, and every later write is silent. One prompt, once, forever.
///
/// The value never touches argv (the shell-out form put the token on a command line, visible
/// to `ps` for the life of the call) and is never logged.
public enum KeychainWrite {
    public enum Outcome: Equatable, Sendable {
        case ok
        case denied          // user cancelled the auth dialog, or the ACL refused us
        case error(Int32)

        public var isOK: Bool { self == .ok }
    }

    /// Create or update a generic-password item.
    ///
    /// ## ⚠️ ONLY EVER CALL THIS ON AN ITEM WE OWN (`Headroom-*`).
    ///
    /// This doc used to claim an update "never widens access on its own — that's why the live
    /// slot keeps working for Claude Code after we write it." **That was exactly backwards,
    /// and it cost a user a password prompt every ~20 minutes for a day.** An update does not
    /// widen access; it *narrows* it onto the writer. `SecItemUpdate` leaves the trusted-app
    /// ACL alone (verified) but silently **rewrites the item's PARTITION LIST to the calling
    /// binary's identity**, evicting whoever owned it:
    ///
    /// ```
    /// partitions BEFORE:  ["apple-tool:"]
    /// SecItemUpdate -> OK
    /// partitions AFTER:   ["cdhash:<the writer>"]
    /// ```
    ///
    /// The evicted owner must then type the login-keychain password on every read, and it
    /// cannot be repaired without that password (restoring a partition list is a CHANGE-ACL
    /// operation, and CHANGE-ACL carries an empty trusted list by design — it always prompts).
    ///
    /// Writing our own `Headroom-*` stashes is safe: we are the only reader, so narrowing the
    /// partition onto ourselves costs nothing.
    public static func upsert(service: String, account: String, value: String) -> Outcome {
        #if os(macOS)
        guard let data = value.data(using: .utf8) else { return .error(errSecParam) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return .ok
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:                                  return .ok
            case errSecUserCanceled, errSecAuthFailed,
                 errSecInteractionNotAllowed:                    return .denied
            default:                                             return .error(addStatus)
            }
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied
        default:
            return .error(status)
        }
        #else
        return .error(-1)
        #endif
    }

    public static func delete(service: String, account: String) -> Outcome {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:                  return .ok   // idempotent
        case errSecUserCanceled, errSecAuthFailed:               return .denied
        default:                                                 return .error(status)
        }
        #else
        return .error(-1)
        #endif
    }
}
