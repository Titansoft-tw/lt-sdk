import CryptoKit
import Foundation

// Remote rules (lt-error-guard-spec README "Remote rules"): a signed envelope { rulesVersion, rules } at `url` and its
// ECDSA P-256 / SHA-256 signature (base64 DER) at `signatureURL`. Only a correctly signed, valid and newer file replaces
// the guard's rules; anything else keeps the current ones. Android: lt-error-guard-android/GuardRulesLoader.kt.

/// What one `GuardRulesLoader.refresh()` did.
public enum RulesUpdate: Equatable, Sendable {
    /// The guard now uses rules `version`.
    case applied(version: Int)
    /// The file is not newer than the rules in use.
    case unchanged(version: Int)
    /// Downloaded but refused; the reason starts with `signature`, `envelope` or `rules`.
    case rejected(reason: String)
    /// Not downloaded (network, HTTP status, size).
    case failed(reason: String)
}

/// ```swift
/// let loader = try GuardRulesLoader(guard: guardian, url: URL(string: "https://cdn.example.com/guard/ios.json")!,
///                                   publicKey: guardRulesPublicKeyPEM, cacheFile: cachesDir.appendingPathComponent("guard-rules.json"),
///                                   onApplied: { v in SentrySDK.configureScope { $0.setTag(value: "\(v)", key: "guard_rules_version") } })
/// loader.applyCached()                 // at start, before Sentry sends anything
/// let periodic = loader.startPeriodic() // refresh now and every 6 h; cancel the task to stop
/// ```
public final class GuardRulesLoader: @unchecked Sendable {
    /// Largest rules file the default fetch accepts.
    public static let maxBytes = 256 * 1024

    private let guardian: ErrorGuard
    private let url: URL
    private let signatureURL: URL
    private let key: P256.Signing.PublicKey
    private let cacheFile: URL?
    private let fetch: @Sendable (URL) async throws -> Data
    private let onApplied: @Sendable (Int) -> Void
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var current = 0

    /// - Parameters:
    ///   - publicKey: PEM (`-----BEGIN PUBLIC KEY-----`) or base64 of the SPKI DER; an invalid key throws.
    ///   - cacheFile: where the last applied file and its signature (`<name>.sig`) are kept; nil = no cache.
    ///   - fetch: GET returning the body; throws on failure. The default needs https and caps the body at `maxBytes`.
    ///   - onApplied: called with the new version after rules are applied (e.g. to tag crash reports).
    ///   - log: one line per outcome that changes something or fails; never the URL.
    public init(guard guardian: ErrorGuard, url: URL, signatureURL: URL? = nil, publicKey: String, cacheFile: URL?,
                fetch: (@Sendable (URL) async throws -> Data)? = nil, onApplied: @escaping @Sendable (Int) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.guardian = guardian
        self.url = url
        self.signatureURL = signatureURL ?? URL(string: url.absoluteString + ".sig")!
        self.key = try Self.parsePublicKey(publicKey)
        self.cacheFile = cacheFile
        self.fetch = fetch ?? Self.httpGet
        self.onApplied = onApplied
        self.log = log
    }

    /// The rules version in use: 0 = the app's own rules (nothing remote applied yet).
    public var version: Int { lock.withLock { current } }

    private var sigFile: URL? { cacheFile.map { URL(fileURLWithPath: $0.path + ".sig") } }

    /// Applies the cached file when it is still correctly signed and valid. Returns whether it did.
    @discardableResult public func applyCached() -> Bool {
        guard let cacheFile, let sigFile, let body = try? Data(contentsOf: cacheFile), let sig = try? Data(contentsOf: sigFile) else { return false }
        let outcome = apply(body, sig, cache: false)
        if case .applied = outcome { return true }
        log("guard rules: cached file ignored (\(outcome))")
        return false
    }

    /// Downloads, checks and applies the remote file.
    @discardableResult public func refresh() async -> RulesUpdate {
        let body: Data, sig: Data
        do {
            body = try await fetch(url)
            sig = try await fetch(signatureURL)
        } catch {
            let outcome = RulesUpdate.failed(reason: "\(error)")
            log("guard rules: download failed (\(error))")
            return outcome
        }
        let outcome = apply(body, sig, cache: true)
        if case .unchanged = outcome {} else { log("guard rules: \(outcome)") }
        return outcome
    }

    /// `refresh()` now and then every `interval`; cancel the task to stop.
    public func startPeriodic(every interval: Duration = .seconds(6 * 3600)) -> Task<Void, Never> {
        Task { [self] in
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func apply(_ body: Data, _ sig: Data, cache: Bool) -> RulesUpdate {
        guard Self.verify(key, body, sig) else { return .rejected(reason: "signature: does not match the public key") }
        let next: Int, rules: GuardRules
        do { (next, rules) = try Self.parseEnvelope(body) } catch { return .rejected(reason: "\(error)") }
        // The callbacks (log, onApplied) run outside the lock: they may read `version`.
        let (applied, cacheError) = lock.withLock { () -> (Bool, Error?) in
            guard next > current else { return (false, nil) }
            guardian.updateRules(rules)
            current = next
            guard cache, let cacheFile, let sigFile else { return (true, nil) }
            do { try body.write(to: cacheFile, options: .atomic); try sig.write(to: sigFile, options: .atomic); return (true, nil) }
            catch { return (true, error) }
        }
        if let cacheError { log("guard rules: cache not written (\(cacheError))") }
        guard applied else { return .unchanged(version: version) }
        onApplied(next)
        return .applied(version: next)
    }

    /// The version and rules in an envelope; throws `GuardRulesError` whose problems start with `envelope` or `rules`.
    public static func parseEnvelope(_ body: Data) throws -> (Int, GuardRules) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw GuardRulesError(problems: ["envelope: must be a JSON object"])
        }
        var problems = root.keys.sorted().filter { $0 != "rulesVersion" && $0 != "rules" }.map { "envelope: unknown key \($0)" }
        let version = Parser.integer(root["rulesVersion"]).flatMap { (1...1_000_000_000).contains($0) ? $0 : nil }
        if version == nil { problems.append("envelope: rulesVersion must be an integer from 1 to 1000000000") }
        let rules = root["rules"] as? [String: Any]
        if rules == nil { problems.append("envelope: rules must be an object") }
        guard problems.isEmpty, let version, let rules else { throw GuardRulesError(problems: problems) }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        do { return (version, try GuardRules.parse(json)) } catch let e as GuardRulesError {
            throw GuardRulesError(problems: e.problems.map { "rules.\($0)" })
        }
    }

    /// ECDSA P-256 / SHA-256 over `body`; `signature` is base64 DER (surrounding whitespace allowed).
    public static func verify(_ key: P256.Signing.PublicKey, _ body: Data, _ signature: Data) -> Bool {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let der = Data(base64Encoded: text), let sig = try? P256.Signing.ECDSASignature(derRepresentation: der) else { return false }
        return key.isValidSignature(sig, for: body)
    }

    public static func parsePublicKey(_ text: String) throws -> P256.Signing.PublicKey {
        let b64 = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined().filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: b64), let key = try? P256.Signing.PublicKey(derRepresentation: der) else {
            throw GuardRulesError(problems: ["publicKey: not an EC P-256 public key (PEM or base64 SPKI DER)"])
        }
        return key
    }

    private static func httpGet(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw GuardRulesError(problems: ["https only"]) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GuardRulesError(problems: ["HTTP \(status)"]) }
        guard data.count <= maxBytes else { throw GuardRulesError(problems: ["larger than \(maxBytes) bytes"]) }
        return data
    }
}
