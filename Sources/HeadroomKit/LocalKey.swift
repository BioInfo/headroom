import Foundation

/// Resolves a provider API key from local sources, for the web-key providers
/// (GLM, and later Kimi / MiniMax) whose quota endpoints accept the key as a
/// plain Bearer. Resolution order, highest priority first:
///   1. Headroom's own keychain entry (what the user pastes in Settings).
///   2. Environment variables the provider's own SDKs use.
///   3. A known dotfile path.
/// Returns nil if none is found — the collector then falls back to WKWebView login.
///
/// Headroom stores a pasted key in the macOS login Keychain under its own service
/// name (never the provider's), so it never reads or moves the user's other creds.
public enum LocalKey {
    /// First non-empty source in the chain, or nil.
    public static func resolve(storedService: String, envNames: [String],
                               filePaths: [URL]) -> String? {
        if let k = stored(service: storedService) { return k }
        if let k = fromEnv(envNames) { return k }
        if let k = fromFiles(filePaths) { return k }
        return nil
    }

    // MARK: - sources

    public static func fromEnv(_ names: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        for n in names {
            if let v = env[n]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        return nil
    }

    public static func fromFiles(_ paths: [URL]) -> String? {
        for p in paths {
            if let s = try? String(contentsOf: p, encoding: .utf8) {
                let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    // MARK: - Headroom's own keychain entry (paste-once)

    /// Read the key the user pasted into Headroom. Service is Headroom-owned
    /// (e.g. "Headroom-zai-key"), so granting access can't expose other apps' creds.
    public static func stored(service: String) -> String? {
        #if os(macOS)
        let out = security(["find-generic-password", "-s", service, "-w"])
        let v = out?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
        #else
        return nil
        #endif
    }

    /// Save (or replace) the pasted key in Headroom's keychain entry.
    @discardableResult
    public static func store(_ key: String, service: String) -> Bool {
        #if os(macOS)
        let user = NSUserName()
        // -U updates if it already exists.
        return security(["add-generic-password", "-s", service, "-a", user,
                         "-w", key, "-U"]) != nil
        #else
        return false
        #endif
    }

    /// Remove the stored key (e.g. user clears it in Settings).
    @discardableResult
    public static func clearStored(service: String) -> Bool {
        #if os(macOS)
        return security(["delete-generic-password", "-s", service]) != nil
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// Run `/usr/bin/security`; returns stdout on exit 0, nil otherwise.
    private static func security(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
    #endif
}
