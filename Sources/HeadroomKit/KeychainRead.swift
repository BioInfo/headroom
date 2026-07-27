import Foundation
#if os(macOS)
import Security
import LocalAuthentication
#endif

/// In-process, never-prompting Keychain read. `SecItemCopyMatching` with
/// `kSecUseAuthenticationUIFail` returns `errSecInteractionNotAllowed` instead of showing
/// the macOS authorization dialog, so a background path can probe an item and degrade
/// gracefully (`.needsInteraction`) rather than pop UI at a random moment or hang a
/// headless run. Callers decide what interaction is worth: background refreshes skip,
/// user-initiated flows fall back to an interactive read. (Approach from steipete/CodexBar's
/// no-UI keychain probes; reimplemented on the plain Security API.)
public enum KeychainRead {
    public enum Outcome: Equatable, Sendable {
        case found(String)
        case notFound
        case needsInteraction   // item exists but reading it would require the auth dialog
        case error(Int32)
    }

    /// Read a generic-password item's value without ever prompting.
    ///
    /// Timing note (measured 2026-07-16): the FIRST access to each ACL'd item by a given
    /// binary identity costs ~4-8s while securityd evaluates the caller's code signature;
    /// every later access is instant (the verdict is cached per binary+item). So a freshly
    /// built/updated binary pays one slow pass, then it's free — background callers should
    /// expect that, and it is not a hang. The cost is identical for the deprecated
    /// `kSecUseAuthenticationUIFail` and this LAContext form; we use the modern one.
    public static func noUI(service: String) -> Outcome {
        #if os(macOS)
        let ctx = LAContext()
        ctx.interactionNotAllowed = true   // no-UI: errSecInteractionNotAllowed instead of a dialog
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: ctx,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let s = String(data: data, encoding: .utf8), !s.isEmpty else { return .notFound }
            return .found(s)
        case errSecItemNotFound:            return .notFound
        case errSecInteractionNotAllowed:   return .needsInteraction
        case errSecAuthFailed:              return .needsInteraction   // denied ACL reads surface here too
        default:                            return .error(status)
        }
        #else
        return .notFound
        #endif
    }

    /// Read a generic-password item by spawning **`/usr/bin/security`**, whose keychain access is
    /// covered by the `apple-tool:` partition entry.
    ///
    /// ⚠️ **Only call this once `ClaudePartition.admitsSecurityTool(service:)` is true.** That
    /// predicate is what makes this read provably promptless; this function has no way to suppress
    /// a dialog on its own (no flag can — see `ClaudePartition`). The `timeout` is a backstop, not
    /// the guarantee: if the tool ever did block on a prompt we terminate it and return nil so a
    /// background refresh degrades to last-good instead of hanging.
    ///
    /// Passing the secret back over a pipe keeps it off argv (unlike a write), and the value is
    /// never logged.
    public static func viaSecurityTool(service: String, timeout: TimeInterval = 10) -> String? {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timedOut = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timedOut)
        // Drain before waiting: a full pipe would deadlock a child that outgrew the 64KB buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timedOut.cancel()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8) else { return nil }
        // `security -w` appends a newline.
        let v = s.trimmingCharacters(in: .newlines)
        return v.isEmpty ? nil : v
        #else
        return nil
        #endif
    }
}
