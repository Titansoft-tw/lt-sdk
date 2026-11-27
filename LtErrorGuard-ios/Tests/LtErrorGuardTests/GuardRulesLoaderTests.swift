import Foundation
import Testing
@testable import LtErrorGuard

// lt-error-guard-spec/vectors/remote (signed with a fixture-only key), which lt-error-guard-android's GuardRulesLoaderTest runs too.

private let remote = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("lt-error-guard-spec/vectors/remote")
private let publicKey = try! String(contentsOf: remote.appendingPathComponent("test.pub.pem"), encoding: .utf8)
private let url = URL(string: "https://rules.example/guard.json")!
private let net = GuardEvent(exceptionTypes: ["java.net.UnknownHostException"])
private let empty = try! GuardRules.parse(#"{"version": 1, "rules": []}"#)

/// Serves `name` (and its .sig) from the fixtures; nil = the server is down.
private final class Server: @unchecked Sendable {
    var name: String?
    var calls = 0
    init(_ name: String?) { self.name = name }
    func fetch(_ u: URL) throws -> Data {
        calls += 1
        guard let name else { throw URLError(.cannotConnectToHost) }
        return try Data(contentsOf: remote.appendingPathComponent(u.absoluteString.hasSuffix(".sig") ? "\(name).sig" : name))
    }
}

private final class Applied: @unchecked Sendable { var versions: [Int] = [] }

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)").appendingPathComponent("rules.json")
}

private func loader(_ guardian: ErrorGuard, _ server: Server, cache: URL? = nil, applied: Applied = Applied()) throws -> GuardRulesLoader {
    if let cache { try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true) }
    return try GuardRulesLoader(guard: guardian, url: url, publicKey: publicKey, cacheFile: cache,
                                fetch: { try server.fetch($0) }, onApplied: { applied.versions.append($0) })
}

@Test func theSharedRemoteCases() async throws {
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: remote.appendingPathComponent("cases.json"))) as! [String: Any]
    for c in manifest["cases"] as! [[String: Any]] {
        let file = c["file"] as! String
        let result = await try loader(ErrorGuard(), Server(file)).refresh()
        if c["expect"] as! String == "applied" {
            #expect(result == .applied(version: c["version"] as! Int), "\(file)")
        } else if case .rejected(let reason) = result {
            #expect(reason.hasPrefix(c["reason"] as! String), "\(file): \(reason)")
        } else {
            Issue.record("\(file): \(result)")
        }
    }
}

@Test func appliedRulesChangeTheGuardsDecisions() async throws {
    let guardian = ErrorGuard(rules: empty)
    #expect(guardian.decide(net).keep)
    let applied = Applied()
    #expect(await try loader(guardian, Server("v2.json"), applied: applied).refresh() == .applied(version: 2))
    #expect(guardian.decide(net) == Decision(keep: false, rule: "net"))
    #expect(applied.versions == [2])
}

@Test func onlyNewerVersionsApply() async throws {
    let guardian = ErrorGuard()
    let server = Server("v3.json")
    let l = try loader(guardian, server)
    #expect(await l.refresh() == .applied(version: 3))
    server.name = "v2.json"
    #expect(await l.refresh() == .unchanged(version: 3))
    server.name = "v3.json"
    #expect(await l.refresh() == .unchanged(version: 3))
    #expect(guardian.decide(net).keep)
}

@Test func refusedOrFailedDownloadsKeepTheCurrentRules() async throws {
    let guardian = ErrorGuard()
    let server = Server("v2.json")
    let l = try loader(guardian, server)
    #expect(await l.refresh() == .applied(version: 2))
    for bad in ["tampered.json", "wrong-key.json", "invalid-rules.json"] {
        server.name = bad
        if case .rejected = await l.refresh() {} else { Issue.record("\(bad) not rejected") }
    }
    server.name = nil
    if case .failed = await l.refresh() {} else { Issue.record("offline not failed") }
    #expect(l.version == 2)
    #expect(guardian.decide(net) == Decision(keep: false, rule: "net"))
}

@Test func theCacheSurvivesARestartAndBlocksRollback() async throws {
    let cache = tempFile()
    #expect(await try loader(ErrorGuard(), Server("v2.json"), cache: cache).refresh() == .applied(version: 2))
    #expect(FileManager.default.fileExists(atPath: cache.path + ".sig"))
    let guardian = ErrorGuard(rules: empty)
    let applied = Applied()
    let offline = Server(nil)
    let l = try loader(guardian, offline, cache: cache, applied: applied)
    #expect(l.applyCached())
    #expect(l.version == 2)
    #expect(guardian.decide(net) == Decision(keep: false, rule: "net"))
    #expect(applied.versions == [2])
    #expect(offline.calls == 0)
}

@Test func aTamperedCacheIsIgnored() async throws {
    let cache = tempFile()
    await try loader(ErrorGuard(), Server("v2.json"), cache: cache).refresh()
    try Data(contentsOf: remote.appendingPathComponent("tampered.json")).write(to: cache)
    let l = try loader(ErrorGuard(), Server(nil), cache: cache)
    #expect(!l.applyCached())
    #expect(l.version == 0)
    #expect(try !loader(ErrorGuard(), Server(nil), cache: tempFile()).applyCached())
}

@Test func envelopeProblems() throws {
    func reason(_ json: String) -> String {
        do { _ = try GuardRulesLoader.parseEnvelope(Data(json.utf8)); return "" } catch { return "\(error)" }
    }
    #expect(reason("[]").hasPrefix("envelope"))
    #expect(reason(#"{"rulesVersion": 0, "rules": {"version": 1, "rules": []}}"#).contains("rulesVersion"))
    #expect(reason(#"{"rulesVersion": 1.5, "rules": {"version": 1, "rules": []}}"#).contains("rulesVersion"))
    #expect(reason(#"{"rulesVersion": true, "rules": {"version": 1, "rules": []}}"#).contains("rulesVersion"))
    #expect(reason(#"{"rulesVersion": 1, "rules": {"version": 1, "rules": []}, "extra": 1}"#).contains("extra"))
    #expect(reason(#"{"rulesVersion": 1}"#).contains("rules must be an object"))
    #expect(reason(#"{"rulesVersion": 1, "rules": {"version": 2, "rules": []}}"#).hasPrefix("rules.version"))
    #expect(try GuardRulesLoader.parseEnvelope(Data(#"{"rulesVersion": 7, "rules": {"version": 1, "rules": []}}"#.utf8)).0 == 7)
}

@Test func anInvalidPublicKeyFailsAtConstruction() throws {
    #expect(throws: GuardRulesError.self) { try GuardRulesLoader(guard: ErrorGuard(), url: url, publicKey: "not a key", cacheFile: nil) }
    let b64 = publicKey.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    _ = try GuardRulesLoader(guard: ErrorGuard(), url: url, publicKey: b64, cacheFile: nil)
}

@Test func aLogCallbackMayReadTheVersion() async throws {
    final class Box: @unchecked Sendable { var loader: GuardRulesLoader?; var seen: [Int] = [] }
    let box = Box()
    let server = Server("v2.json")
    box.loader = try GuardRulesLoader(guard: ErrorGuard(), url: url, publicKey: publicKey, cacheFile: nil, fetch: { try server.fetch($0) },
                                      onApplied: { _ in box.seen.append(box.loader!.version) }, log: { _ in _ = box.loader?.version })
    #expect(await box.loader!.refresh() == .applied(version: 2))
    #expect(box.seen == [2])
}

@Test func periodicRefreshRuns() async throws {
    let l = try loader(ErrorGuard(), Server("v2.json"))
    let task = l.startPeriodic(every: .seconds(60))
    for _ in 0..<100 where l.version == 0 { try await Task.sleep(for: .milliseconds(20)) }
    task.cancel()
    #expect(l.version == 2)
}
