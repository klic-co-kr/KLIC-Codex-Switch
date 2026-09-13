import AppKit
import CryptoKit
import Foundation
import WebKit

private let codexBundleIdentifier = "com.openai.codex"

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Data Models

struct CodexAccount {
    let key: String
    let email: String
    let plan: String
    let fiveHourUsedPercent: Int?
    let weeklyUsedPercent: Int?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let isActive: Bool
}

private struct SwitchScope {
    let applyToCLI: Bool
    let reflectCodexApp: Bool
    let launchCodexIfClosed: Bool
}

private enum SwitchScopeDefaults {
    private static let applyToCLIKey = "switchScopeApplyToCLI"
    private static let reflectCodexAppKey = "switchScopeReflectCodexApp"
    private static let launchCodexIfClosedKey = "switchScopeLaunchCodexIfClosed"
    private static let defaults: UserDefaults = {
        if let suiteName = ProcessInfo.processInfo.environment["CODEX_SWITCHER_DEFAULTS_SUITE"],
           let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }()

    static func current() -> SwitchScope {
        SwitchScope(
            applyToCLI: bool(forKey: applyToCLIKey, defaultValue: true),
            reflectCodexApp: bool(forKey: reflectCodexAppKey, defaultValue: true),
            launchCodexIfClosed: bool(forKey: launchCodexIfClosedKey, defaultValue: false)
        )
    }

    static func setApplyToCLI(_ value: Bool) {
        defaults.set(value, forKey: applyToCLIKey)
        if !value {
            defaults.set(false, forKey: reflectCodexAppKey)
        }
    }

    static func setReflectCodexApp(_ value: Bool) {
        if value {
            defaults.set(true, forKey: applyToCLIKey)
        }
        defaults.set(value, forKey: reflectCodexAppKey)
    }

    static func setLaunchCodexIfClosed(_ value: Bool) {
        defaults.set(value, forKey: launchCodexIfClosedKey)
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

struct CommandResult {
    let status: Int32
    let output: String
}

private struct AccountInfo {
    let key: String
    let email: String
    let auth: [String: Any]
    let isActive: Bool
}

private struct UsageWindow {
    let usedPercent: Int?
    let resetDate: Date?
}

private struct ParsedUsage {
    let plan: String?
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
}

private enum FetchResult {
    case success(ParsedUsage)
    case needsRefresh
    case failed
}

// MARK: - Session Continuity Models

private struct FileFingerprint: Codable, Sendable {
	let relativePath: String
	let kind: FileKind
	let size: UInt64
	let modifiedAt: Date?
	let sha256: String?

	enum FileKind: String, Codable {
		case file
		case directory
	}

	init(relativePath: String, kind: FileKind, size: UInt64, modifiedAt: Date?, sha256: String?) {
		self.relativePath = relativePath
		self.kind = kind
		self.size = size
		self.modifiedAt = modifiedAt
		self.sha256 = sha256
	}
}

private struct SessionSnapshot: Codable, Sendable {
	let codexHome: String
	let createdAt: Date
	let entries: [String: FileFingerprint]
	let activeAccountKey: String?

	init(codexHome: String, createdAt: Date = Date(), entries: [String: FileFingerprint], activeAccountKey: String? = nil) {
		self.codexHome = codexHome
		self.createdAt = createdAt
		self.entries = entries
		self.activeAccountKey = activeAccountKey
	}
}

private struct SnapshotComparison: Codable, Sendable {
	let deleted: [String]
	let modified: [String]
	let added: [String]
	let unchangedCount: Int

	var hasDestructiveChange: Bool { !deleted.isEmpty }
	var isUnchanged: Bool { deleted.isEmpty && modified.isEmpty && added.isEmpty }

	init(deleted: [String] = [], modified: [String] = [], added: [String] = [], unchangedCount: Int = 0) {
		self.deleted = deleted
		self.modified = modified
		self.added = added
		self.unchangedCount = unchangedCount
	}
}

private struct SessionProtectionPolicy: Sendable {
	let recursivelyHashedPaths: [String]
	let singleHashedPaths: [String]
	let existenceOnlyPaths: [String]

	static let `default` = SessionProtectionPolicy(
		recursivelyHashedPaths: ["sessions", "archived_sessions", "skills", "rules"],
		singleHashedPaths: [
			"history.jsonl", "session_index.jsonl", "config.toml",
			"hooks.json", ".codex-global-state.json", "state_5.sqlite",
			"thread_history_1.sqlite", "external_agent_session_imports.json"
		],
		existenceOnlyPaths: ["threads", "projects", "worktrees"]
	)
}

private enum CaptureMode: Sendable {
	case contentHashed
	case metadataOnly
}

private struct ContinuityTestRecord: Codable, Sendable {
	let marker: String
	let startedAt: Date
	let sourceAccount: String?
	let targetAccount: String?
	let sessionPath: String?
	let sessionID: String?
	let followUpSucceeded: Bool?
	let verdict: ContinuityVerdict
	let notes: String?

	init(marker: String, startedAt: Date, sourceAccount: String?, targetAccount: String? = nil, sessionPath: String? = nil, sessionID: String? = nil, followUpSucceeded: Bool? = nil, verdict: ContinuityVerdict = .pending, notes: String? = nil) {
		self.marker = marker
		self.startedAt = startedAt
		self.sourceAccount = sourceAccount
		self.targetAccount = targetAccount
		self.sessionPath = sessionPath
		self.sessionID = sessionID
		self.followUpSucceeded = followUpSucceeded
		self.verdict = verdict
		self.notes = notes
	}
}

private enum ContinuityVerdict: String, Codable {
	case pending
	case pass
	case partial
	case fail

	var displayText: String {
		switch self {
		case .pending: return NSLocalizedString("verdict_pending", comment: "")
		case .pass: return NSLocalizedString("verdict_pass", comment: "")
		case .partial: return NSLocalizedString("verdict_partial", comment: "")
		case .fail: return NSLocalizedString("verdict_fail", comment: "")
		}
	}

	// Records persisted before the raw values were stabilized stored Korean
	// display strings; keep decoding them so old records still load.
	init(from decoder: Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		switch raw {
		case "pending", "대기 중": self = .pending
		case "pass", "통과": self = .pass
		case "partial", "부분 통과": self = .partial
		case "fail", "실패": self = .fail
		default:
			throw DecodingError.dataCorrupted(.init(
				codingPath: decoder.codingPath,
				debugDescription: "Unknown verdict: \(raw)"))
		}
	}
}

private struct SessionMarkerMatch: Sendable {
	let fileURL: URL
	let sessionID: String?

	init(fileURL: URL, sessionID: String?) {
		self.fileURL = fileURL
		self.sessionID = sessionID
	}
}

// MARK: - Rotation Decision (pure, shared by GUI + CLI)

/// Suite-aware defaults so CLI subcommands can be driven against an isolated
/// store in tests via CODEX_SWITCHER_DEFAULTS_SUITE. In the GUI (no env var)
/// this resolves to `.standard`.
func switcherDefaults() -> UserDefaults {
    if let suiteName = ProcessInfo.processInfo.environment["CODEX_SWITCHER_DEFAULTS_SUITE"],
       let suite = UserDefaults(suiteName: suiteName) {
        return suite
    }
    return .standard
}

enum RotationThresholdDefaults {
    static let steps = [10, 20, 30, 40]
    static let fallback = 20
    static let key5h = "rotationThreshold5h"
    static let keyWeekly = "rotationThresholdWeekly"

    static func value(forKey key: String) -> Int {
        let v = switcherDefaults().integer(forKey: key)
        return v > 0 ? v : fallback
    }

    static func set(_ value: Int, forKey key: String) {
        switcherDefaults().set(value, forKey: key)
    }
}

enum RotationDecision: String {
    case none
    case switchTarget = "switch"
    case allExhausted = "all-exhausted"
}

/// A usage window is "over limit" when its remaining (100 - used) is at or below
/// the remaining-% threshold. Unknown (nil) usage counts as NOT over, so missing
/// data never triggers a switch or a false all-exhausted warning.
func windowOverLimit(usedPercent: Int?, remainingThreshold: Int) -> Bool {
    guard let used = usedPercent else { return false }
    let clamped = min(max(used, 0), 100)
    return (100 - clamped) <= remainingThreshold
}

func accountOverLimit(fiveHourUsed: Int?, weeklyUsed: Int?, threshold5h: Int, thresholdWeekly: Int) -> Bool {
    windowOverLimit(usedPercent: fiveHourUsed, remainingThreshold: threshold5h) ||
        windowOverLimit(usedPercent: weeklyUsed, remainingThreshold: thresholdWeekly)
}

func decideRotation(activeOverLimit: Bool, inactiveOverLimit: Bool) -> RotationDecision {
    guard activeOverLimit else { return .none }
    return inactiveOverLimit ? .allExhausted : .switchTarget
}

// MARK: - Usage Window Classification (shared GUI + CLI)

/// Windows are classified by their own duration, never by their position in the
/// response. The Codex usage API's `primary_window`/`secondary_window` slots do
/// NOT map to fixed durations: as of 2026-07 the 5-hour window was removed and
/// the weekly window (limit_window_seconds == 604800) is delivered in
/// `primary_window`, with `secondary_window` null. A window whose duration is at
/// or below one day is treated as the short ("5-hour") window; anything longer is
/// the weekly window. When 5-hour limits return, both windows classify correctly
/// regardless of which slot each arrives in.
private let fiveHourWindowMaxSeconds: Double = 86_400

private let usageISO8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func usageWindowResetDate(_ dict: [String: Any]) -> Date? {
    for key in ["reset_at", "resets_at"] {
        if let ts = dict[key] as? Double {
            return Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000.0 : ts)
        }
        if let ts = dict[key] as? Int {
            let d = Double(ts)
            return Date(timeIntervalSince1970: d > 1e12 ? d / 1000.0 : d)
        }
        if let str = dict[key] as? String {
            return usageISO8601Formatter.date(from: str)
        }
    }
    return nil
}

private func usageWindowUsedPercent(_ dict: [String: Any]) -> Int? {
    if let pct = dict["used_percent"] as? Double { return Int(pct) }
    if let pct = dict["utilization"] as? Double { return Int(pct) }
    return nil
}

private func usageWindowDurationSeconds(_ dict: [String: Any]) -> Double? {
    if let s = dict["limit_window_seconds"] as? Double { return s }
    if let s = dict["window_seconds"] as? Double { return s }
    if let m = dict["window_minutes"] as? Double { return m * 60.0 }
    return nil
}

private func classifyUsageWindows(_ rateLimit: [String: Any]?) -> (fiveHour: UsageWindow?, weekly: UsageWindow?) {
    guard let rateLimit else { return (nil, nil) }
    let slots: [([String: Any]?, Bool)] = [
        (rateLimit["primary_window"] as? [String: Any] ?? rateLimit["primary"] as? [String: Any], true),
        (rateLimit["secondary_window"] as? [String: Any] ?? rateLimit["secondary"] as? [String: Any], false)
    ]

    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var undated: [(window: UsageWindow, isPrimary: Bool)] = []

    for (dict, isPrimary) in slots {
        guard let dict else { continue }
        let window = UsageWindow(usedPercent: usageWindowUsedPercent(dict), resetDate: usageWindowResetDate(dict))
        if let duration = usageWindowDurationSeconds(dict) {
            if duration <= fiveHourWindowMaxSeconds { fiveHour = window } else { weekly = window }
        } else {
            undated.append((window, isPrimary))
        }
    }

    // Windows lacking a duration field fall back to positional assignment
    // (primary -> short, secondary -> weekly), filling only empty slots.
    for (window, isPrimary) in undated {
        if isPrimary && fiveHour == nil { fiveHour = window }
        else if !isPrimary && weekly == nil { weekly = window }
        else if weekly == nil { weekly = window }
        else if fiveHour == nil { fiveHour = window }
    }
    return (fiveHour, weekly)
}

// MARK: - Shared Helpers (used by both GUI and CLI)

private struct HTTPResult {
    let data: Data?
    let response: HTTPURLResponse?
}

private func codexHomeDirectory() -> String {
    ProcessInfo.processInfo.environment["CODEX_SWITCHER_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
}

private func encodeKey(_ key: String) -> String {
    Data(key.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
}

private func decodeBase64Key(_ key: String) -> String? {
    let padding = String(repeating: "=", count: (4 - key.count % 4) % 4)
    guard let data = Data(base64Encoded: key + padding) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func extractEmail(from auth: [String: Any]) -> String? {
    guard let tokens = auth["tokens"] as? [String: Any],
          let accessToken = tokens["access_token"] as? String else { return nil }
    let segments = accessToken.split(separator: ".")
    guard segments.count == 3 else { return nil }
    let payload = String(segments[1])
    let padding = String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload + padding),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json["email"] as? String
}

private func normalizeAuth(_ auth: [String: Any]) -> [String: Any] {
    var result = auth
    if result["OPENAI_API_KEY"] == nil {
        result["OPENAI_API_KEY"] = NSNull()
    }
    if result["auth_mode"] == nil {
        result["auth_mode"] = "chatgpt"
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    result["last_refresh"] = formatter.string(from: Date())
    return result
}

private func httpGet(url: URL, headers: [String: String]) -> HTTPResult {
    let semaphore = DispatchSemaphore(value: 0)
    var result = HTTPResult(data: nil, response: nil)
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    URLSession.shared.dataTask(with: request) { data, response, _ in
        result = HTTPResult(data: data, response: response as? HTTPURLResponse)
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 15)
    return result
}

private func httpPost(url: URL, body: String) -> HTTPResult {
    let semaphore = DispatchSemaphore(value: 0)
    var result = HTTPResult(data: nil, response: nil)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 12
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = body.data(using: .utf8)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        result = HTTPResult(data: data, response: response as? HTTPURLResponse)
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 15)
    return result
}

private func httpPostJSON(url: URL, body: String) -> HTTPResult {
    let semaphore = DispatchSemaphore(value: 0)
    var result = HTTPResult(data: nil, response: nil)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body.data(using: .utf8)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        result = HTTPResult(data: data, response: response as? HTTPURLResponse)
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 15)
    return result
}

private func cliRun(_ executable: String, _ args: [String]) -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    } catch {
        return CommandResult(status: 127, output: error.localizedDescription)
    }
}

private func cliCodexProcessTreePIDs(rootPIDs: [String]) -> Set<String> {
    guard !rootPIDs.isEmpty else { return [] }
    let result = cliRun("/bin/ps", ["-axo", "pid=,ppid="])
    guard result.status == 0 else { return Set(rootPIDs) }

    var childrenByParent: [String: [String]] = [:]
    for line in result.output.split(whereSeparator: \.isNewline) {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2,
              fields[0].allSatisfy(\.isNumber),
              fields[1].allSatisfy(\.isNumber) else { continue }
        childrenByParent[String(fields[1]), default: []].append(String(fields[0]))
    }

    var tree = Set(rootPIDs)
    var pending = rootPIDs
    while let parent = pending.popLast() {
        for child in childrenByParent[parent, default: []] where tree.insert(child).inserted {
            pending.append(child)
        }
    }
    return tree
}

private func cliProcessIdentity(pid: String) -> String? {
    let result = cliRun("/bin/ps", ["-p", pid, "-o", "user=,lstart=,command="])
    guard result.status == 0 else { return nil }
    let identity = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return identity.isEmpty ? nil : identity
}

private func cliCodexProcessIdentities(rootPIDs: [String]) -> [String: String] {
    cliCodexProcessTreePIDs(rootPIDs: rootPIDs).reduce(into: [String: String]()) { result, pid in
        if let identity = cliProcessIdentity(pid: pid) {
            result[pid] = identity
        }
    }
}

private func cliMatchingPIDs(_ identities: [String: String]) -> [String] {
    identities.compactMap { pid, expectedIdentity in
        guard let currentIdentity = cliProcessIdentity(pid: pid),
              currentIdentity == expectedIdentity else { return nil }
        return pid
    }
}

private func cliRefreshToken(refreshToken: String) -> (accessToken: String, newRefreshToken: String?, idToken: String?)? {
    guard let url = URL(string: "https://auth.openai.com/oauth/token"),
          let encoded = refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
    let scope = "openid profile email offline_access"
    let scopeEncoded = scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope
    let body = "grant_type=refresh_token&refresh_token=\(encoded)&client_id=app_EMoamEEZ73f0CkXaXp7hrann&scope=\(scopeEncoded)"
    let result = httpPost(url: url, body: body)
    guard let data = result.data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accessToken = json["access_token"] as? String else { return nil }
    return (accessToken, json["refresh_token"] as? String, json["id_token"] as? String)
}

private func cliReadAccounts() -> [(key: String, email: String, auth: [String: Any], isActive: Bool)] {
    let home = codexHomeDirectory()
    let accountsDir = "\(home)/.codex/accounts"
    let fm = FileManager.default

    var activeKey: String?
    let registryURL = URL(fileURLWithPath: "\(accountsDir)/registry.json")
    if let data = try? Data(contentsOf: registryURL),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let key = json["active_account_key"] as? String {
        activeKey = encodeKey(key)
    }

    var accounts: [(key: String, email: String, auth: [String: Any], isActive: Bool)] = []
    if let files = try? fm.contentsOfDirectory(atPath: accountsDir) {
        let authFiles = files.filter { $0.hasSuffix(".auth.json") }.sorted()
        for filename in authFiles {
            let base64Key = String(filename.dropLast(10))
            let email = decodeBase64Key(base64Key) ?? base64Key
            let filePath = "\(accountsDir)/\(filename)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                  let authDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            accounts.append((base64Key, email, authDict, base64Key == activeKey))
        }
    }

    if accounts.isEmpty {
        let singleAuthURL = URL(fileURLWithPath: "\(home)/.codex/auth.json")
        if let data = try? Data(contentsOf: singleAuthURL),
           let authDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let email = extractEmail(from: authDict) ?? "codex"
            accounts.append(("single", email, authDict, true))
        }
    }

    return accounts
}

private func cliSyncActiveSnapshot() -> String? {
    let home = codexHomeDirectory()
    let registryURL = URL(fileURLWithPath: "\(home)/.codex/accounts/registry.json")
    let activeAuthURL = URL(fileURLWithPath: "\(home)/.codex/auth.json")

    do {
        let data = try Data(contentsOf: registryURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let activeKey = json["active_account_key"] as? String else {
            return "Could not read active_account_key from registry.json"
        }
        let encoded = encodeKey(activeKey)
        let accountAuthURL = URL(fileURLWithPath: "\(home)/.codex/accounts/\(encoded).auth.json")
        guard FileManager.default.fileExists(atPath: activeAuthURL.path) else {
            return "Active auth file missing at \(activeAuthURL.path)"
        }
        if FileManager.default.fileExists(atPath: accountAuthURL.path) {
            try FileManager.default.removeItem(at: accountAuthURL)
        }
        try FileManager.default.copyItem(at: activeAuthURL, to: accountAuthURL)
        return nil
    } catch {
        return error.localizedDescription
    }
}

private func cliUpdateRegistry(_ key: String?) -> String? {
    let home = codexHomeDirectory()
    let accountsDir = "\(home)/.codex/accounts"
    let registryURL = URL(fileURLWithPath: "\(accountsDir)/registry.json")
    try? FileManager.default.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)

    var json: [String: Any]
    if let data = try? Data(contentsOf: registryURL),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        json = existing
    } else {
        json = [:]
    }
    if let key {
        json["active_account_key"] = key
    } else {
        json.removeValue(forKey: "active_account_key")
    }
    do {
        let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try newData.write(to: registryURL, options: .atomic)
        return nil
    } catch {
        return error.localizedDescription
    }
}

private func cliRestartCodex(launchIfNotRunning: Bool = true) -> CommandResult {
    let rootPIDs = cliCodexPIDs()
    let wasRunning = !rootPIDs.isEmpty
    let initialTree = cliCodexProcessTreePIDs(rootPIDs: rootPIDs)
    var processIdentities = cliCodexProcessIdentities(rootPIDs: rootPIDs)
    if wasRunning && processIdentities.count != initialTree.count {
        return CommandResult(status: 1, output: "Could not verify all Codex process identities; restart aborted.")
    }

    // Ask the app to terminate cleanly first. The app owns child app-server
    // processes; waiting for that tree prevents the next launch from reusing
    // an app-server that still has the previous account in memory.
    if wasRunning {
        NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier)
            .forEach { _ = $0.terminate() }
    }

    for attempt in 1...6 {
        let currentTree = cliCodexProcessTreePIDs(rootPIDs: rootPIDs)
        for pid in currentTree where processIdentities[pid] == nil {
            if let identity = cliProcessIdentity(pid: pid) {
                processIdentities[pid] = identity
            } else {
                return CommandResult(status: 1, output: "Could not verify a Codex child process identity; restart aborted.")
            }
        }
        let pids = cliMatchingPIDs(processIdentities)
        if pids.isEmpty { break }
        let signal = attempt == 1 ? "-TERM" : "-KILL"
        _ = cliRun("/bin/kill", [signal] + pids)
        Thread.sleep(forTimeInterval: 1)
    }
    let remaining = cliMatchingPIDs(processIdentities)
    if !remaining.isEmpty {
        return CommandResult(status: 1, output: "Codex processes survived force quit: \(remaining.joined(separator: ", "))")
    }
    if !wasRunning && !launchIfNotRunning {
        return CommandResult(status: 0, output: "Codex App was not running; launch skipped.")
    }
    let openResult = cliRun("/usr/bin/open", ["-b", codexBundleIdentifier])
    if openResult.status != 0 { return openResult }
    if !cliWaitForCodexApp() {
        return CommandResult(status: 1, output: "Codex App did not report as running after launch.")
    }

    // The documented deep link both focuses a workspace and starts a fresh
    // thread. This removes the extra manual Internet/Workspace navigation
    // after an account switch, while doing nothing when no workspace is saved.
    if let workspaceURL = cliLastWorkspaceDeepLink() {
        Thread.sleep(forTimeInterval: 0.5)
        let workspaceResult = cliRun("/usr/bin/open", [workspaceURL])
        if workspaceResult.status != 0 { return workspaceResult }
    }
    return CommandResult(status: 0, output: "ok")
}

private func cliCodexPIDs() -> [String] {
    NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier)
        .map { String($0.processIdentifier) }
}

private func cliWaitForCodexApp(timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if !cliCodexPIDs().isEmpty { return true }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return !cliCodexPIDs().isEmpty
}

private func cliLastWorkspaceDeepLink() -> String? {
    let stateURL = URL(fileURLWithPath: "\(codexHomeDirectory())/.codex/.codex-global-state.json")
    guard let data = try? Data(contentsOf: stateURL),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    let keys = ["active-workspace-roots", "electron-saved-workspace-roots"]
    let fileManager = FileManager.default
    for key in keys {
        guard let roots = state[key] as? [String] else { continue }
        guard let path = roots.first(where: {
            $0.hasPrefix("/") && fileManager.fileExists(atPath: $0)
        }) else { continue }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url?.absoluteString
    }
    return nil
}

// MARK: - Session Continuity Helpers

private class SessionSnapshotter {
    let codexHome: URL
    let policy: SessionProtectionPolicy

    init(codexHome: URL, policy: SessionProtectionPolicy = .default) {
        self.codexHome = codexHome.resolvingSymlinksInPath().standardizedFileURL
        self.policy = policy
    }

    func capture(mode: CaptureMode = .contentHashed) throws -> SessionSnapshot {
        var entries: [String: FileFingerprint] = [:]

        for path in policy.singleHashedPaths {
            let url = codexHome.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                let item = try fingerprint(url: url, hashContents: mode == .contentHashed)
                entries[item.relativePath] = item
            }
        }

        for path in policy.recursivelyHashedPaths {
            let root = codexHome.appendingPathComponent(path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            let rootItem = try fingerprint(url: root, hashContents: false)
            entries[rootItem.relativePath] = rootItem

            if isDirectory.boolValue {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let itemURL as URL in enumerator {
                    let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    guard values.isRegularFile == true else { continue }

                    if shouldExclude(itemURL) {
                        continue
                    }

                    let item = try fingerprint(url: itemURL, hashContents: mode == .contentHashed)
                    entries[item.relativePath] = item
                }
            }
        }

        for path in policy.existenceOnlyPaths {
            let url = codexHome.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                let item = try fingerprint(url: url, hashContents: false)
                entries[item.relativePath] = item
            }
        }

        let home = codexHome.path
        var activeKey: String?
        let registryURL = URL(fileURLWithPath: "\(home)/accounts/registry.json")
        if let data = try? Data(contentsOf: registryURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = json["active_account_key"] as? String {
            activeKey = key
        }

        return SessionSnapshot(codexHome: home, entries: entries, activeAccountKey: activeKey)
    }

    func compare(_ before: SessionSnapshot, _ after: SessionSnapshot) -> SnapshotComparison {
        let beforeKeys = Set(before.entries.keys)
        let afterKeys = Set(after.entries.keys)
        let deleted = beforeKeys.subtracting(afterKeys).sorted()
        let added = afterKeys.subtracting(beforeKeys).sorted()
        var modified: [String] = []
        var unchanged = 0

        for key in beforeKeys.intersection(afterKeys).sorted() {
            guard let old = before.entries[key], let new = after.entries[key] else { continue }
            let contentChanged: Bool
            if old.sha256 != nil || new.sha256 != nil {
                contentChanged = old.sha256 != new.sha256
            } else {
                contentChanged = old.modifiedAt != new.modifiedAt
            }
            if old.kind != new.kind || old.size != new.size || contentChanged {
                modified.append(key)
            } else {
                unchanged += 1
            }
        }

        return SnapshotComparison(deleted: deleted, modified: modified, added: added, unchangedCount: unchanged)
    }

    private func fingerprint(url: URL, hashContents: Bool) throws -> FileFingerprint {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let relativePath = relativePath(for: url)

        if values.isDirectory == true {
            return FileFingerprint(
                relativePath: relativePath,
                kind: .directory,
                size: UInt64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                sha256: nil
            )
        }

        return FileFingerprint(
            relativePath: relativePath,
            kind: .file,
            size: UInt64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate,
            sha256: hashContents ? try sha256(url: url) : nil
        )
    }

    private func sha256(url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw NSError(domain: "SessionSnapshotter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open file"])
        }
        stream.open()
        // An unopened stream would hash zero bytes as a bogus "empty" digest
        // and poison the baseline snapshot — fail loudly instead.
        guard (stream as Stream).streamStatus == .open, stream.streamError == nil else {
            let message = stream.streamError?.localizedDescription ?? "Cannot open file for hashing"
            throw NSError(domain: "SessionSnapshotter", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw NSError(domain: "SessionSnapshotter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Read error"])
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(for url: URL) -> String {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let root = codexHome.path.hasSuffix("/") ? codexHome.path : codexHome.path + "/"
        if url.path == codexHome.path { return "." }
        guard url.path.hasPrefix(root) else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count))
    }

    private func shouldExclude(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix(".tmp") ||
               name.hasSuffix(".lock") || name == "auth.json"
    }
}

private class SessionMarkerFinder {
    let codexHome: URL

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    func find(marker: String) throws -> SessionMarkerMatch? {
        guard marker.hasPrefix("CAS-PROBE-"), let needle = marker.data(using: .utf8) else {
            return nil
        }

        let candidates = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
            codexHome.appendingPathComponent("history.jsonl")
        ]

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                guard let enumerator = FileManager.default.enumerator(
                    at: candidate,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let file as URL in enumerator {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true, ["json", "jsonl"].contains(file.pathExtension.lowercased()) else { continue }
                    if try contains(needle: needle, in: file) {
                        return SessionMarkerMatch(fileURL: file, sessionID: inferredSessionID(from: file))
                    }
                }
            } else if try contains(needle: needle, in: candidate) {
                return SessionMarkerMatch(fileURL: candidate, sessionID: inferredSessionID(from: candidate))
            }
        }

        return nil
    }

    private func contains(needle: Data, in file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var overlap = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { return false }

            var search = overlap
            search.append(chunk)
            if search.range(of: needle) != nil { return true }
            overlap = Data(search.suffix(max(needle.count - 1, 0)))
        }
    }

    private func inferredSessionID(from url: URL) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        if let range = url.lastPathComponent.range(of: pattern, options: .regularExpression) {
            return String(url.lastPathComponent[range])
        }
        return nil
    }
}

private class ContinuityTestStore {
    let continuityRecordFile: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        // Continuity records live beside the test-isolated codex home, not the
        // real Application Support, so CLI tests can drive them end-to-end.
        let dir = URL(fileURLWithPath: codexHomeDirectory()).appendingPathComponent(".codex/continuity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.continuityRecordFile = dir.appendingPathComponent("continuity-test.json")
    }

    func begin(sourceAccount: String?) throws -> ContinuityTestRecord {
        let marker = "CAS-PROBE-\(UUID().uuidString)"
        let record = ContinuityTestRecord(marker: marker, startedAt: Date(), sourceAccount: sourceAccount)
        try save(record)
        return record
    }

    func recordMarkerMatch(_ match: SessionMarkerMatch) throws -> ContinuityTestRecord {
        guard let record = try loadRecord() else { throw missingRecordError }
        let updated = ContinuityTestRecord(
            marker: record.marker,
            startedAt: record.startedAt,
            sourceAccount: record.sourceAccount,
            targetAccount: record.targetAccount,
            sessionPath: match.fileURL.path,
            sessionID: match.sessionID,
            followUpSucceeded: record.followUpSucceeded,
            verdict: record.verdict,
            notes: record.notes
        )
        try save(updated)
        return updated
    }

    func finish(verdict: ContinuityVerdict, targetAccount: String?, followUpSucceeded: Bool?, notes: String?) throws -> ContinuityTestRecord {
        guard let record = try loadRecord() else { throw missingRecordError }
        let updated = ContinuityTestRecord(
            marker: record.marker,
            startedAt: record.startedAt,
            sourceAccount: record.sourceAccount,
            targetAccount: targetAccount ?? record.targetAccount,
            sessionPath: record.sessionPath,
            sessionID: record.sessionID,
            followUpSucceeded: followUpSucceeded,
            verdict: verdict,
            notes: notes ?? record.notes
        )
        try save(updated)
        return updated
    }

    func loadRecord() throws -> ContinuityTestRecord? {
        guard FileManager.default.fileExists(atPath: continuityRecordFile.path) else { return nil }
        let data = try Data(contentsOf: continuityRecordFile)
        return try decoder.decode(ContinuityTestRecord.self, from: data)
    }

    private var missingRecordError: NSError {
        NSError(domain: "ContinuityTestStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "No continuity test in progress"])
    }

    private func save(_ record: ContinuityTestRecord) throws {
        let data = try encoder.encode(record)
        try data.write(to: continuityRecordFile, options: .atomic)
    }
}

private func makeSessionSnapshotter() -> SessionSnapshotter {
    SessionSnapshotter(codexHome: URL(fileURLWithPath: codexHomeDirectory()).appendingPathComponent(".codex", isDirectory: true))
}

private func makeSessionMarkerFinder() -> SessionMarkerFinder {
    SessionMarkerFinder(codexHome: URL(fileURLWithPath: codexHomeDirectory()).appendingPathComponent(".codex", isDirectory: true))
}

/// Restores ~/.codex/auth.json from the previous account's snapshot file.
/// The source is read fully before anything is written and the final write is
/// atomic, so a failure can never leave auth.json absent. Returns nil on
/// success or an error message; the caller decides how to fix the registry.
func restorePreviousAuth(previousEmail: String?) -> String? {
    guard let previousEmail, previousEmail != "codex" else {
        return "previous account unknown"
    }
    let home = codexHomeDirectory()
    let encoded = encodeKey(previousEmail)
    let previousAuthURL = URL(fileURLWithPath: "\(home)/.codex/accounts/\(encoded).auth.json")
    let mainAuthURL = URL(fileURLWithPath: "\(home)/.codex/auth.json")
    guard FileManager.default.fileExists(atPath: previousAuthURL.path) else {
        return "account file missing for \(previousEmail)"
    }
    do {
        let data = try Data(contentsOf: previousAuthURL)
        try data.write(to: mainAuthURL, options: .atomic)
        return nil
    } catch {
        return error.localizedDescription
    }
}

// MARK: - Session Protection Defaults

enum SessionProtectionDefaults {
    private static let enabledKey = "sessionProtectionEnabled"

    static var enabled: Bool {
        get {
            let defaults = switcherDefaults()
            guard defaults.object(forKey: enabledKey) != nil else { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set { switcherDefaults().set(newValue, forKey: enabledKey) }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let refreshInterval: TimeInterval = 5
    private let usageCacheInterval: TimeInterval = 60
    private let labelsDefaultsKey = "accountDisplayLabels"
    private let statusItemLength: CGFloat = 18
    private let statusItemAutosaveName = "local.codex-account-switcher.menu-bar.status-item"
    private let statusItemPreferredPosition = 247
    private let menuSummaryWidth: CGFloat = 300
    private let menuSideInset: CGFloat = 14
    private var refreshTimer: Timer?
    private var accounts: [CodexAccount] = []
    private var lastError: String?
    private var isSwitching = false
    private var isRefreshing = false
    private var labelEditField: NSTextField?
    private var switchAnimationTimer: Timer?
    private var switchAnimationFrame = 0
    private var switchingTitle = NSLocalizedString("switching", comment: "")
    private let switchAnimationFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var cachedUsageByAccount: [String: ParsedUsage] = [:]
    private var lastUsageFetch: Date?
    private var allLimitsReached = false
    private var continuityTestRecord: ContinuityTestRecord?
    private var isLocatingMarker = false
    private var lastSnapshotComparison: SnapshotComparison?
    private var sessionProtectionEnabled: Bool {
        get { SessionProtectionDefaults.enabled }
        set { SessionProtectionDefaults.enabled = newValue }
    }
    private var rotationEnabled: Bool {
        get { switcherDefaults().bool(forKey: "rotationEnabled") }
        set { switcherDefaults().set(newValue, forKey: "rotationEnabled") }
    }
    private var rotationThreshold5h: Int {
        get { RotationThresholdDefaults.value(forKey: RotationThresholdDefaults.key5h) }
        set { RotationThresholdDefaults.set(newValue, forKey: RotationThresholdDefaults.key5h) }
    }
    private var rotationThresholdWeekly: Int {
        get { RotationThresholdDefaults.value(forKey: RotationThresholdDefaults.keyWeekly) }
        set { RotationThresholdDefaults.set(newValue, forKey: RotationThresholdDefaults.keyWeekly) }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        prepareStatusItemPlacementDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemLength)
        statusItem.autosaveName = statusItemAutosaveName
        statusItem.isVisible = true
        configureStatusButton()
        refreshAccounts()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAccounts()
        }
        RunLoop.current.add(timer, forMode: .common)
        refreshTimer = timer
        continuityTestRecord = try? ContinuityTestStore().loadRecord()
        showFirstLaunchHintIfNeeded()
    }

    private func prepareStatusItemPlacementDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(statusItemPreferredPosition, forKey: "NSStatusItem Preferred Position \(statusItemAutosaveName)")
        defaults.set(true, forKey: "NSStatusItem Visible \(statusItemAutosaveName)")
        defaults.synchronize()
    }

    private func showFirstLaunchHintIfNeeded() {
        let key = "didShowMenuBarHint"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("hint_title", comment: "")
        alert.informativeText = NSLocalizedString("hint_body", comment: "")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("ok", comment: ""))
        alert.runModal()
    }

    // MARK: UI Configuration

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.toolTip = statusIdleTitle()
        button.image = loadStatusBarIcon()
        button.imagePosition = .imageOnly
    }

    private func loadStatusBarIcon() -> NSImage? {
        makeKlicSwitcherStatusIcon()
    }

    private func makeKlicSwitcherStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let mark = NSBezierPath()
        mark.lineWidth = 2.25
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: 4.5, y: 3.5))
        mark.line(to: NSPoint(x: 4.5, y: 14.5))
        mark.move(to: NSPoint(x: 5.3, y: 9.0))
        mark.line(to: NSPoint(x: 12.6, y: 4.2))
        mark.move(to: NSPoint(x: 5.3, y: 9.0))
        mark.line(to: NSPoint(x: 12.6, y: 13.8))
        mark.stroke()

        NSBezierPath(ovalIn: NSRect(x: 11.9, y: 2.9, width: 3.1, height: 3.1)).fill()
        NSBezierPath(ovalIn: NSRect(x: 11.9, y: 12.0, width: 3.1, height: 3.1)).fill()

        image.unlockFocus()
        image.size = size
        image.isTemplate = true
        image.accessibilityDescription = NSLocalizedString("app_name", comment: "")
        return image
    }

    // MARK: Data Refresh

    private func refreshAccounts() {
        guard !isSwitching, !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let (accountInfos, _) = self.readAccountFiles()

            var activeAccountKey = accountInfos.first(where: { $0.isActive })?.key
            var allUsage: [String: ParsedUsage] = DispatchQueue.main.sync {
                self.cachedUsageByAccount
            }

            let shouldFetch: Bool = DispatchQueue.main.sync {
                self.lastUsageFetch == nil ||
                    Date().timeIntervalSince(self.lastUsageFetch!) > self.usageCacheInterval
            }

            if shouldFetch {
                for info in accountInfos {
                    if let tokens = self.getTokens(from: info.auth) {
                        if let usage = self.fetchUsageWithRefresh(
                            accessToken: tokens.accessToken,
                            accountId: tokens.accountId,
                            refreshToken: tokens.refreshToken,
                            accountInfo: info
                        ) {
                            allUsage[info.key] = usage
                            if info.isActive {
                                activeAccountKey = info.key
                            }
                        }
                    }
                }
                DispatchQueue.main.sync {
                    self.lastUsageFetch = Date()
                    self.cachedUsageByAccount = allUsage
                }
            } else {
                let staleCache: [String: ParsedUsage] = DispatchQueue.main.sync {
                    self.cachedUsageByAccount
                }
                allUsage = staleCache
            }

            var accounts: [CodexAccount] = []
            for info in accountInfos {
                let isActive = info.key == activeAccountKey ?? accountInfos.first(where: { $0.isActive })?.key
                let usage = allUsage[info.key]
                accounts.append(CodexAccount(
                    key: info.key,
                    email: info.email,
                    plan: usage?.plan.flatMap { $0.isEmpty ? nil : $0 } ?? (isActive ? "Free" : "—"),
                    fiveHourUsedPercent: usage?.fiveHour?.usedPercent,
                    weeklyUsedPercent: usage?.weekly?.usedPercent,
                    fiveHourResetAt: usage?.fiveHour?.resetDate,
                    weeklyResetAt: usage?.weekly?.resetDate,
                    isActive: isActive
                ))
            }

            DispatchQueue.main.async {
                self.isRefreshing = false
                if accountInfos.isEmpty {
                    self.accounts = []
                    self.lastError = NSLocalizedString("err_no_accounts", comment: "")
                } else {
                    self.accounts = accounts
                    self.lastError = nil
                }
                self.rebuildMenu()
                self.checkAutoRotation()
            }
        }
    }

    private func checkAutoRotation() {
        let wasReached = allLimitsReached
        guard rotationEnabled,
              accounts.count == 2,
              !isSwitching,
              let active = accounts.first(where: { $0.isActive }),
              let inactive = accounts.first(where: { !$0.isActive }) else {
            allLimitsReached = false
            if wasReached { rebuildMenu() }
            return
        }

        let activeOver = accountOverLimit(
            fiveHourUsed: active.fiveHourUsedPercent,
            weeklyUsed: active.weeklyUsedPercent,
            threshold5h: rotationThreshold5h,
            thresholdWeekly: rotationThresholdWeekly)
        let inactiveOver = accountOverLimit(
            fiveHourUsed: inactive.fiveHourUsedPercent,
            weeklyUsed: inactive.weeklyUsedPercent,
            threshold5h: rotationThreshold5h,
            thresholdWeekly: rotationThresholdWeekly)

        switch decideRotation(activeOverLimit: activeOver, inactiveOverLimit: inactiveOver) {
        case .switchTarget:
            allLimitsReached = false
            switchTo(key: inactive.key)
        case .allExhausted:
            allLimitsReached = true
            if !wasReached { rebuildMenu() }
        case .none:
            allLimitsReached = false
            if wasReached { rebuildMenu() }
        }
    }

    // MARK: Menu Building

    private func rebuildMenu() {
        let menu = NSMenu()

        if let active = accounts.first(where: { $0.isActive }) {
            if !isSwitching {
                statusItem.button?.toolTip = statusTitle(for: active)
            }
            menu.addItem(activeSummaryItem(for: active))
        } else {
            if !isSwitching {
                statusItem.button?.toolTip = statusIdleTitle()
            }
            menu.addItem(headerItem(lastError ?? NSLocalizedString("no_active_account", comment: ""), symbol: "exclamationmark.circle"))
        }

        menu.addItem(.separator())

        if let active = accounts.first(where: { $0.isActive }) {
            menu.addItem(headerItem(NSLocalizedString("usage_remaining", comment: ""), symbol: "gauge.medium"))
            menu.addItem(usageCombinedItem(for: active))
            if allLimitsReached {
                menu.addItem(headerItem(NSLocalizedString("all_limits_reached", comment: ""), symbol: "exclamationmark.triangle.fill"))
            }
            menu.addItem(.separator())
        }

        // Rotation
        if accounts.count == 2 {
            let rotTitle = rotationEnabled
                ? NSLocalizedString("rotation_on", comment: "")
                : NSLocalizedString("rotation_off", comment: "")
            let rotItem = NSMenuItem(title: rotTitle, action: #selector(toggleRotation), keyEquivalent: "")
            rotItem.target = self
            rotItem.isEnabled = !isSwitching
            rotItem.state = rotationEnabled ? .on : .off
            rotItem.image = styledMenuIcon(rotationEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath", description: rotTitle)
            menu.addItem(rotItem)

            let thresh5hStr = String(format: NSLocalizedString("threshold_5h", comment: ""), "\(rotationThreshold5h)")
            let thresh5hItem = NSMenuItem(title: thresh5hStr, action: #selector(cycleThreshold5h), keyEquivalent: "")
            thresh5hItem.target = self
            thresh5hItem.isEnabled = rotationEnabled && !isSwitching
            thresh5hItem.image = styledMenuIcon("slider.horizontal.3", description: thresh5hStr)
            menu.addItem(thresh5hItem)

            let threshWeeklyStr = String(format: NSLocalizedString("threshold_weekly", comment: ""), "\(rotationThresholdWeekly)")
            let threshWeeklyItem = NSMenuItem(title: threshWeeklyStr, action: #selector(cycleThresholdWeekly), keyEquivalent: "")
            threshWeeklyItem.target = self
            threshWeeklyItem.isEnabled = rotationEnabled && !isSwitching
            threshWeeklyItem.image = styledMenuIcon("slider.horizontal.3", description: threshWeeklyStr)
            menu.addItem(threshWeeklyItem)

            menu.addItem(.separator())
        }

        let scope = SwitchScopeDefaults.current()
        menu.addItem(headerItem(NSLocalizedString("switch_scope", comment: ""), symbol: "slider.horizontal.2.square"))
        menu.addItem(scopeToggleItem(
            title: String(format: NSLocalizedString(scope.applyToCLI ? "scope_cli_on" : "scope_cli_off", comment: "")),
            action: #selector(toggleScopeCLI),
            state: scope.applyToCLI,
            enabled: !isSwitching,
            symbol: "terminal"
        ))
        menu.addItem(scopeToggleItem(
            title: String(format: NSLocalizedString(scope.reflectCodexApp ? "scope_app_on" : "scope_app_off", comment: "")),
            action: #selector(toggleScopeApp),
            state: scope.reflectCodexApp,
            enabled: !isSwitching && scope.applyToCLI,
            symbol: "macwindow"
        ))
        menu.addItem(scopeToggleItem(
            title: String(format: NSLocalizedString(scope.launchCodexIfClosed ? "scope_launch_on" : "scope_launch_off", comment: "")),
            action: #selector(toggleScopeLaunch),
            state: scope.launchCodexIfClosed,
            enabled: !isSwitching && scope.reflectCodexApp,
            symbol: "play.circle"
        ))
        menu.addItem(.separator())

        // Session protection & continuity
        menu.addItem(headerItem(NSLocalizedString("session_protection", comment: ""), symbol: "shield"))
        menu.addItem(scopeToggleItem(
            title: String(format: NSLocalizedString(sessionProtectionEnabled ? "session_protection_on" : "session_protection_off", comment: "")),
            action: #selector(toggleSessionProtection),
            state: sessionProtectionEnabled,
            enabled: !isSwitching,
            symbol: "shield.fill"
        ))
        if let comparison = lastSnapshotComparison {
            let summary = String(
                format: NSLocalizedString("snapshot_summary", comment: ""),
                comparison.deleted.count, comparison.modified.count, comparison.unchangedCount)
            let item = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = styledMenuIcon("doc.on.doc", description: summary)
            menu.addItem(item)
        }
        menu.addItem(continuityTestMenuItem())
        menu.addItem(.separator())

        if accounts.isEmpty {
            let item = NSMenuItem(title: lastError ?? NSLocalizedString("no_accounts", comment: ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = styledMenuIcon("exclamationmark.circle", description: item.title)
            menu.addItem(item)
        } else {
            menu.addItem(headerItem(NSLocalizedString("accounts", comment: ""), symbol: "person.2"))
            for account in accounts {
                let item = NSMenuItem(title: "", action: #selector(switchAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.key
                item.attributedTitle = accountAttributedTitle(for: account)
                item.state = account.isActive ? .on : .off
                item.image = styledMenuIcon(account.isActive ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle", description: displayLabel(for: account))
                item.toolTip = String(format: NSLocalizedString("account_tooltip", comment: ""),
                    account.plan,
                    usageDisplayString(percent: account.fiveHourUsedPercent, resetAt: account.fiveHourResetAt),
                    usageDisplayString(percent: account.weeklyUsedPercent, resetAt: account.weeklyResetAt))
                item.isEnabled = !isSwitching
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: NSLocalizedString("toggle_account", comment: ""), action: #selector(toggleAccount), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = accounts.count == 2 && !isSwitching
        toggle.image = styledMenuIcon("arrow.left.arrow.right.circle", description: toggle.title)
        menu.addItem(toggle)

        menu.addItem(.separator())

        let addAccount = NSMenuItem(title: NSLocalizedString("add_account", comment: ""), action: #selector(addAccountBrowser), keyEquivalent: "")
        addAccount.target = self
        addAccount.isEnabled = !isSwitching
        addAccount.image = styledMenuIcon("plus.circle", description: addAccount.title)
        menu.addItem(addAccount)

        let addDevice = NSMenuItem(title: NSLocalizedString("add_device_code", comment: ""), action: #selector(addAccountDeviceCode), keyEquivalent: "")
        addDevice.target = self
        addDevice.isEnabled = !isSwitching
        addDevice.image = styledMenuIcon("key", description: addDevice.title)
        addDevice.toolTip = NSLocalizedString("device_code_tooltip", comment: "")
        menu.addItem(addDevice)

        if !accounts.isEmpty {
            let labelsItem = NSMenuItem(title: NSLocalizedString("display_labels", comment: ""), action: nil, keyEquivalent: "")
            labelsItem.image = styledMenuIcon("tag", description: labelsItem.title)
            let labelsMenu = NSMenu()
            for account in accounts {
                let item = NSMenuItem(title: String(format: NSLocalizedString("set_label", comment: ""), displayLabel(for: account), account.email), action: #selector(setAccountLabel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.email
                item.image = styledMenuIcon("pencil", description: item.title)
                labelsMenu.addItem(item)
            }
            labelsItem.submenu = labelsMenu
            menu.addItem(labelsItem)

            let removeItem = NSMenuItem(title: NSLocalizedString("remove_account", comment: ""), action: nil, keyEquivalent: "")
            removeItem.image = styledMenuIcon("trash", description: removeItem.title)
            let removeMenu = NSMenu()
            for account in accounts {
                let item = NSMenuItem(title: "\(displayLabel(for: account))  \(account.email)", action: #selector(removeAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.key
                item.isEnabled = !isSwitching && account.key != "single"
                item.image = styledMenuIcon("minus.circle", description: item.title)
                removeMenu.addItem(item)
            }
            removeItem.submenu = removeMenu
            menu.addItem(removeItem)
        }

        let refresh = NSMenuItem(title: NSLocalizedString("refresh", comment: ""), action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !isSwitching
        refresh.image = styledMenuIcon("arrow.clockwise", description: refresh.title)
        menu.addItem(refresh)

        let quit = NSMenuItem(title: NSLocalizedString("quit", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = styledMenuIcon("power", description: quit.title)
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: Display Helpers

    private func statusIdleTitle() -> String {
        "Codex"
    }

    private func statusTitle(for account: CodexAccount) -> String {
        let base = String(
            format: NSLocalizedString("status_5hr", comment: ""),
            displayLabel(for: account),
            remainingPercentText(fromUsed: account.fiveHourUsedPercent)
        )
        if rotationEnabled, accounts.count == 2 {
            return String(format: NSLocalizedString("status_rotation", comment: ""), base)
        }
        return base
    }

    private func remainingPercentText(fromUsed usedPercent: Int?) -> String {
        guard let usedPercent else { return "--%" }
        let remaining = max(0, 100 - usedPercent)
        return "\(remaining)%"
    }

    private func resetTimeText(from date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let suffix = hour >= 12 ? NSLocalizedString("pm", comment: "") : NSLocalizedString("am", comment: "")
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: NSLocalizedString("time_format", comment: ""), "\(hour12)", String(format: "%02d", minute), suffix)
    }

    private func resetDateText(from date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        let monthIndex = cal.component(.month, from: date) - 1
        let day = cal.component(.day, from: date)
        let engMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let localizedMonth = NSLocalizedString(engMonths[monthIndex], comment: "")
        return String(format: NSLocalizedString("date_format", comment: ""), localizedMonth, "\(day)")
    }

    private func usageDisplayString(percent: Int?, resetAt: Date?) -> String {
        let pctStr = remainingPercentText(fromUsed: percent)
        guard let resetAt else { return pctStr }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: resetAt)
        let minute = cal.component(.minute, from: resetAt)
        let suffix = hour >= 12 ? NSLocalizedString("pm", comment: "") : NSLocalizedString("am", comment: "")
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(pctStr) (\(hour12):\(String(format: "%02d", minute)) \(suffix))"
    }

    private func usageCombinedItem(for account: CodexAccount) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let tooltip = usageDetailTooltip(
            fiveHourPercent: remainingPercentText(fromUsed: account.fiveHourUsedPercent),
            fiveHourReset: resetTimeText(from: account.fiveHourResetAt),
            weeklyPercent: remainingPercentText(fromUsed: account.weeklyUsedPercent),
            weeklyReset: resetTimeText(from: account.weeklyResetAt)
        )
        item.view = usageSummaryView(
            fiveHourPercent: remainingPercentText(fromUsed: account.fiveHourUsedPercent),
            fiveHourReset: resetTimeText(from: account.fiveHourResetAt),
            weeklyPercent: remainingPercentText(fromUsed: account.weeklyUsedPercent),
            weeklyReset: resetTimeText(from: account.weeklyResetAt)
        )
        item.toolTip = tooltip
        item.isEnabled = false
        return item
    }

    private func activeSummaryItem(for account: CodexAccount) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let tooltip = accountDetailTooltip(for: account)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuSummaryWidth, height: 52))

        let icon = NSImageView(frame: NSRect(x: menuSideInset + 2, y: 16, width: 22, height: 22))
        icon.image = styledMenuIcon("person.crop.circle.fill.badge.checkmark", description: displayLabel(for: account))
        icon.contentTintColor = .controlAccentColor
        view.addSubview(icon)

        let planWidth: CGFloat = 58
        let textX = menuSideInset + 34
        let titleWidth = menuSummaryWidth - textX - planWidth - menuSideInset - 8
        let title = menuLabel(
            displayLabel(for: account),
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor,
            frame: NSRect(x: textX, y: 28, width: titleWidth, height: 17)
        )
        view.addSubview(title)

        let subtitle = menuLabel(
            accountUsageSummaryText(for: account),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .secondaryLabelColor,
            frame: NSRect(x: textX, y: 11, width: menuSummaryWidth - textX - menuSideInset, height: 15)
        )
        view.addSubview(subtitle)

        let planLabel = menuLabel(
            displayPlan(account.plan),
            font: .systemFont(ofSize: 10, weight: .medium),
            color: .controlAccentColor,
            frame: NSRect(x: menuSummaryWidth - menuSideInset - planWidth, y: 29, width: planWidth, height: 13),
            alignment: .right
        )
        view.addSubview(planLabel)

        applyTooltip(tooltip, to: view)

        item.view = view
        item.toolTip = tooltip
        item.isEnabled = false
        return item
    }

    private func usageSummaryView(fiveHourPercent: String, fiveHourReset: String, weeklyPercent: String, weeklyReset: String) -> NSView {
        let tooltip = usageDetailTooltip(
            fiveHourPercent: fiveHourPercent,
            fiveHourReset: fiveHourReset,
            weeklyPercent: weeklyPercent,
            weeklyReset: weeklyReset
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuSummaryWidth, height: 30))
        let gap: CGFloat = 8
        let columnWidth = (menuSummaryWidth - (menuSideInset * 2) - gap) / 2

        let fiveHour = usageValueColumn(
            title: NSLocalizedString("5hr", comment: ""),
            value: fiveHourPercent,
            accent: .systemTeal
        )
        fiveHour.frame.origin = NSPoint(x: menuSideInset, y: 5)
        fiveHour.frame.size.width = columnWidth
        view.addSubview(fiveHour)

        let weekly = usageValueColumn(
            title: NSLocalizedString("weekly", comment: ""),
            value: weeklyPercent,
            accent: .systemIndigo
        )
        weekly.frame.origin = NSPoint(x: menuSideInset + columnWidth + gap, y: 5)
        weekly.frame.size.width = columnWidth
        view.addSubview(weekly)

        applyTooltip(tooltip, to: view)
        return view
    }

    private func usageValueColumn(title: String, value: String, accent: NSColor) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 136, height: 20))
        let titleLabel = menuLabel(
            title,
            font: .systemFont(ofSize: 10, weight: .medium),
            color: .secondaryLabelColor,
            frame: NSRect(x: 0, y: 9, width: 48, height: 12)
        )
        view.addSubview(titleLabel)

        let valueLabel = menuLabel(
            value,
            font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            color: accent,
            frame: NSRect(x: 54, y: 2, width: 74, height: 16),
            alignment: .right
        )
        view.addSubview(valueLabel)

        return view
    }

    private func usageDetailTooltip(fiveHourPercent: String, fiveHourReset: String, weeklyPercent: String, weeklyReset: String) -> String {
        [
            usageTooltipLine(title: NSLocalizedString("5hr", comment: ""), percent: fiveHourPercent, reset: fiveHourReset),
            usageTooltipLine(title: NSLocalizedString("weekly", comment: ""), percent: weeklyPercent, reset: weeklyReset)
        ].joined(separator: "\n")
    }

    private func usageTooltipLine(title: String, percent: String, reset: String) -> String {
        guard !reset.isEmpty else {
            return "\(title) \(percent)"
        }
        return "\(title) \(percent) · \(String(format: NSLocalizedString("reset_at", comment: ""), reset))"
    }

    private func accountDetailTooltip(for account: CodexAccount) -> String {
        let detail = usageDetailTooltip(
            fiveHourPercent: remainingPercentText(fromUsed: account.fiveHourUsedPercent),
            fiveHourReset: resetTimeText(from: account.fiveHourResetAt),
            weeklyPercent: remainingPercentText(fromUsed: account.weeklyUsedPercent),
            weeklyReset: resetTimeText(from: account.weeklyResetAt)
        )
        return "\(displayLabel(for: account)) · \(displayPlan(account.plan))\n\(detail)"
    }

    private func applyTooltip(_ tooltip: String, to view: NSView) {
        view.toolTip = tooltip
        for subview in view.subviews {
            applyTooltip(tooltip, to: subview)
        }
    }

    private func menuLabel(_ text: String, font: NSFont, color: NSColor, frame: NSRect, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    private func usageAttributedTitle(fiveHourPercent: String, fiveHourReset: String, weeklyPercent: String, weeklyReset: String) -> NSAttributedString {
        let fiveHour = "\(NSLocalizedString("5hr", comment: "")) \(fiveHourPercent) \(fiveHourReset)"
        let weekly = "\(NSLocalizedString("weekly", comment: "")) \(weeklyPercent) \(weeklyReset)"
        return attributedColumns(
            "\(fiveHour)\t\(weekly)",
            tabs: [168],
            font: NSFont.menuFont(ofSize: 0),
            color: .labelColor
        )
    }

    private func accountAttributedTitle(for account: CodexAccount) -> NSAttributedString {
        let fiveHour = "\(NSLocalizedString("5hr", comment: "")) \(remainingPercentText(fromUsed: account.fiveHourUsedPercent))"
        let weekly = "\(NSLocalizedString("weekly", comment: "")) \(remainingPercentText(fromUsed: account.weeklyUsedPercent))"
        return attributedColumns(
            "\(limitedLabel(displayLabel(for: account)))\t\(fiveHour)\t\(weekly)",
            tabs: [92, 184],
            font: NSFont.menuFont(ofSize: 0),
            color: .labelColor
        )
    }

    private func accountUsageSummaryText(for account: CodexAccount) -> String {
        "\(NSLocalizedString("5hr", comment: "")) \(remainingPercentText(fromUsed: account.fiveHourUsedPercent)) · \(NSLocalizedString("weekly", comment: "")) \(remainingPercentText(fromUsed: account.weeklyUsedPercent))"
    }

    private func attributedColumns(_ text: String, tabs: [CGFloat], font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
        paragraph.defaultTabInterval = 48
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func headerItem(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let symbol {
            item.image = styledMenuIcon(symbol, description: title)
        }
        return item
    }

    private func continuityTestMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString("continuity_test", comment: ""), action: nil, keyEquivalent: "")
        item.image = styledMenuIcon("testtube.2", description: item.title)
        let submenu = NSMenu()

        if let record = continuityTestRecord {
            let markerItem = NSMenuItem(title: record.marker, action: #selector(copyContinuityMarker), keyEquivalent: "")
            markerItem.target = self
            markerItem.image = styledMenuIcon("doc.on.doc", description: record.marker)
            markerItem.toolTip = NSLocalizedString("marker_tooltip", comment: "")
            submenu.addItem(markerItem)

            let statusItem = NSMenuItem(
                title: String(format: NSLocalizedString("continuity_status", comment: ""), record.verdict.displayText),
                action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            statusItem.image = styledMenuIcon(verdictSymbol(record.verdict), description: statusItem.title)
            submenu.addItem(statusItem)

            submenu.addItem(.separator())
            submenu.addItem(continuityActionItem("locate_marker", #selector(locateContinuityMarker), enabled: !isSwitching && !isLocatingMarker))
            submenu.addItem(.separator())
            submenu.addItem(continuityVerdictItem("mark_pass", .pass))
            submenu.addItem(continuityVerdictItem("mark_partial", .partial))
            submenu.addItem(continuityVerdictItem("mark_fail", .fail))
            submenu.addItem(.separator())
        }

        // Always reachable so a finished test can be replaced with a new one.
        let beginTitle = continuityTestRecord == nil
            ? NSLocalizedString("begin_continuity_test", comment: "")
            : NSLocalizedString("begin_continuity_test_new", comment: "")
        let beginItem = NSMenuItem(title: beginTitle, action: #selector(beginContinuityTest), keyEquivalent: "")
        beginItem.target = self
        beginItem.isEnabled = !isSwitching
        beginItem.image = styledMenuIcon("play.circle", description: beginItem.title)
        submenu.addItem(beginItem)

        item.submenu = submenu
        return item
    }

    private func continuityActionItem(_ titleKey: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString(titleKey, comment: ""), action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.image = styledMenuIcon("magnifyingglass", description: item.title)
        return item
    }

    private func continuityVerdictItem(_ titleKey: String, _ verdict: ContinuityVerdict) -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString(titleKey, comment: ""), action: #selector(markContinuityVerdict(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = !isSwitching
        item.representedObject = verdict.rawValue
        item.image = styledMenuIcon(verdictSymbol(verdict), description: item.title)
        return item
    }

    private func verdictSymbol(_ verdict: ContinuityVerdict) -> String {
        switch verdict {
        case .pending: return "clock"
        case .pass: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle"
        case .fail: return "xmark.circle"
        }
    }

    private func scopeToggleItem(title: String, action: Selector, state: Bool, enabled: Bool, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state ? .on : .off
        item.isEnabled = enabled
        item.image = styledMenuIcon(symbol, description: title)
        return item
    }

    private func styledMenuIcon(_ systemName: String, description: String?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: description) else {
            return nil
        }
        let configured = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) ?? base
        configured.isTemplate = true
        return configured
    }

    // MARK: Action Handlers

    @objc private func refreshNow() {
        lastUsageFetch = nil
        refreshAccounts()
    }

    @objc private func toggleRotation() {
        rotationEnabled = !rotationEnabled
        checkAutoRotation()
        rebuildMenu()
    }

    @objc private func cycleThreshold5h() {
        rotationThreshold5h = nextThresholdStep(after: rotationThreshold5h)
        checkAutoRotation()
        rebuildMenu()
    }

    @objc private func cycleThresholdWeekly() {
        rotationThresholdWeekly = nextThresholdStep(after: rotationThresholdWeekly)
        checkAutoRotation()
        rebuildMenu()
    }

    private func nextThresholdStep(after current: Int) -> Int {
        let steps = RotationThresholdDefaults.steps
        guard let idx = steps.firstIndex(of: current) else { return RotationThresholdDefaults.fallback }
        return steps[(idx + 1) % steps.count]
    }

    @objc private func toggleScopeCLI() {
        SwitchScopeDefaults.setApplyToCLI(!SwitchScopeDefaults.current().applyToCLI)
        rebuildMenu()
    }

    @objc private func toggleScopeApp() {
        SwitchScopeDefaults.setReflectCodexApp(!SwitchScopeDefaults.current().reflectCodexApp)
        rebuildMenu()
    }

    @objc private func toggleScopeLaunch() {
        SwitchScopeDefaults.setLaunchCodexIfClosed(!SwitchScopeDefaults.current().launchCodexIfClosed)
        rebuildMenu()
    }

    // MARK: Session Protection Actions

    @objc private func toggleSessionProtection() {
        sessionProtectionEnabled.toggle()
        rebuildMenu()
    }

    @objc private func beginContinuityTest() {
        guard !isSwitching else { return }
        let store = ContinuityTestStore()
        do {
            let activeEmail = accounts.first(where: { $0.isActive })?.email
            let record = try store.begin(sourceAccount: activeEmail)
            continuityTestRecord = record
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.marker, forType: .string)
            showAlert(
                title: NSLocalizedString("continuity_started", comment: ""),
                message: String(format: NSLocalizedString("continuity_started_msg", comment: ""), record.marker))
        } catch {
            showAlert(title: NSLocalizedString("alert_continuity_failed", comment: ""), message: error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func copyContinuityMarker() {
        guard let record = continuityTestRecord else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.marker, forType: .string)
    }

    @objc private func locateContinuityMarker() {
        guard !isSwitching, !isLocatingMarker, let record = continuityTestRecord else { return }
        // Scanning every session file can take seconds — keep it off the main
        // thread so the menu bar never freezes while searching.
        isLocatingMarker = true
        rebuildMenu()
        let marker = record.marker
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try makeSessionMarkerFinder().find(marker: marker) }
            DispatchQueue.main.async {
                self.isLocatingMarker = false
                switch outcome {
                case .success(.some(let match)):
                    do {
                        self.continuityTestRecord = try ContinuityTestStore().recordMarkerMatch(match)
                        self.showAlert(
                            title: NSLocalizedString("marker_found", comment: ""),
                            message: String(format: NSLocalizedString("marker_found_msg", comment: ""), match.fileURL.lastPathComponent))
                    } catch {
                        self.showAlert(title: NSLocalizedString("alert_continuity_failed", comment: ""), message: error.localizedDescription)
                    }
                case .success(.none):
                    self.showAlert(title: NSLocalizedString("marker_not_found", comment: ""), message: NSLocalizedString("marker_not_found_msg", comment: ""))
                case .failure(let error):
                    self.showAlert(title: NSLocalizedString("alert_continuity_failed", comment: ""), message: error.localizedDescription)
                }
                self.rebuildMenu()
            }
        }
    }

    @objc private func markContinuityVerdict(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let verdict = ContinuityVerdict(rawValue: raw) else { return }
        let store = ContinuityTestStore()
        do {
            let activeEmail = accounts.first(where: { $0.isActive })?.email
            continuityTestRecord = try store.finish(
                verdict: verdict,
                targetAccount: activeEmail,
                followUpSucceeded: nil,
                notes: nil)
        } catch {
            showAlert(title: NSLocalizedString("alert_continuity_failed", comment: ""), message: error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func addAccountBrowser() {
        performBrowserLogin()
    }

    @objc private func addAccountDeviceCode() {
        performDeviceCodeLogin()
    }

    private static let emojiGrid: [[String]] = [
        ["🔴","🟢","🔵","🟡","🟠","🟣","⚫","⚪","🟤"],
        ["⭐","💎","🔑","🎯","🔥","💡","✅","❌","⭐️"],
        ["😀","😎","🤖","🥷","🦊","🐱","🐶","🐼","🦁"],
        ["🏠","💼","🎮","🎵","🚀","⚡","🌊","🍀","🔔"],
    ]

    @objc private func setAccountLabel(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String,
              let account = accounts.first(where: { $0.email == email }) else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert_set_label", comment: "")
        alert.informativeText = String(format: NSLocalizedString("alert_set_label_msg", comment: ""), account.email)
        alert.addButton(withTitle: NSLocalizedString("save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("cancel", comment: ""))

        let containerWidth: CGFloat = 324
        let cellSize: CGFloat = 32
        let cellPad: CGFloat = 4
        let rows = Self.emojiGrid.count
        let gridHeight = CGFloat(rows) * (cellSize + cellPad) - cellPad
        let fieldHeight: CGFloat = 24
        let separatorHeight: CGFloat = 12
        let totalHeight = fieldHeight + separatorHeight + gridHeight + 4

        let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: totalHeight))

        let field = NSTextField(frame: NSRect(x: 0, y: totalHeight - fieldHeight, width: containerWidth, height: fieldHeight))
        field.stringValue = displayLabel(for: account)
        field.placeholderString = "emoji or text"
        container.addSubview(field)
        labelEditField = field

        let separator = NSView(frame: NSRect(x: 0, y: totalHeight - fieldHeight - separatorHeight, width: containerWidth, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        container.addSubview(separator)

        let emojiTop = totalHeight - fieldHeight - separatorHeight - gridHeight
        for (rowIndex, row) in Self.emojiGrid.enumerated() {
            for (colIndex, emoji) in row.enumerated() {
                let x = CGFloat(colIndex) * (cellSize + cellPad)
                let y = emojiTop + CGFloat(rows - 1 - rowIndex) * (cellSize + cellPad)
                let btn = NSButton(frame: NSRect(x: x, y: y, width: cellSize, height: cellSize))
                btn.title = emoji
                btn.isBordered = false
                btn.wantsLayer = true
                btn.layer?.cornerRadius = 6
                btn.font = NSFont.systemFont(ofSize: 18)
                btn.alignment = .center
                btn.target = self
                btn.action = #selector(emojiPicked(_:))
                container.addSubview(btn)
            }
        }

        alert.accessoryView = container

        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                clearCustomLabel(forEmail: email)
            } else {
                setCustomLabel(limitedLabel(value), forEmail: email)
            }
            rebuildMenu()
        }
        labelEditField = nil
    }

    @objc private func emojiPicked(_ sender: NSButton) {
        labelEditField?.stringValue = sender.title
    }

    @objc private func clearAccountLabel(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String else { return }
        clearCustomLabel(forEmail: email)
        rebuildMenu()
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let account = accounts.first(where: { $0.key == key }) else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert_remove_title", comment: "")
        alert.informativeText = String(format: NSLocalizedString("alert_remove_msg", comment: ""), account.email)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("remove", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("cancel", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            removeAccountDirect(key)
        }
    }

    private func removeAccountDirect(_ key: String) {
        guard !isSwitching else { return }
        isSwitching = true
        statusItem.button?.toolTip = NSLocalizedString("removing_account", comment: "")
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            let home = codexHomeDirectory()
            let mainAuthPath = "\(home)/.codex/auth.json"
            var errorMsg: String?

            if key == "single" {
                // Remove single (fallback) account: just clear auth.json
                try? FileManager.default.removeItem(atPath: mainAuthPath)
            } else {
                let filePath = "\(home)/.codex/accounts/\(key).auth.json"
                do {
                    try FileManager.default.removeItem(atPath: filePath)
                    _ = self.updateRegistryActiveKey(nil)
                    let (remaining, _) = self.readAccountFiles()
                    if let newActive = remaining.first(where: { $0.key != key }) {
                        let newKey = newActive.key == "single" ? nil : decodeBase64Key(newActive.key)
                        errorMsg = self.updateRegistryActiveKey(newKey)
                        // Copy new active account to auth.json
                        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.codex/accounts/\(newActive.key).auth.json")) {
                            try? data.write(to: URL(fileURLWithPath: mainAuthPath), options: .atomic)
                        }
                    } else {
                        // Last account removed — clear auth.json too
                        try? FileManager.default.removeItem(atPath: mainAuthPath)
                    }
                } catch {
                    errorMsg = error.localizedDescription
                }
            }

            DispatchQueue.main.async {
                self.isSwitching = false
                if let errorMsg {
                    self.showAlert(title: String(format: NSLocalizedString("alert_maintenance_failed", comment: ""), NSLocalizedString("removing_account", comment: "")), message: errorMsg)
                }
                self.lastUsageFetch = nil
                self.refreshAccounts()
            }
        }
    }

    @objc private func toggleAccount() {
        guard accounts.count == 2, let inactive = accounts.first(where: { !$0.isActive }) else {
            showAlert(title: NSLocalizedString("alert_cannot_toggle", comment: ""), message: NSLocalizedString("alert_cannot_toggle_msg", comment: ""))
            return
        }
        switchTo(key: inactive.key)
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        switchTo(key: key)
    }

    private func switchTo(key: String) {
        guard !isSwitching else { return }
        guard let target = accounts.first(where: { $0.key == key }), !target.isActive else { return }
        let scope = SwitchScopeDefaults.current()
        guard scope.applyToCLI else {
            showAlert(title: NSLocalizedString("alert_switch_scope_disabled", comment: ""), message: NSLocalizedString("alert_switch_scope_disabled_msg", comment: ""))
            return
        }
        isSwitching = true
        let previousActiveEmail = accounts.first(where: { $0.isActive })?.email
        beginSwitchAnimation(label: displayLabel(for: target))
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            if let syncError = self.syncActiveAuthSnapshot() {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: NSLocalizedString("alert_token_save_failed", comment: ""), message: syncError)
                    self.refreshAccounts()
                }
                return
            }

            let home = codexHomeDirectory()
            let targetAuthPath = "\(home)/.codex/accounts/\(key).auth.json"
            let mainAuthPath = "\(home)/.codex/auth.json"

            // Session protection state. Snapshot failures are fail-closed: the
            // switch aborts rather than silently proceeding unprotected.
            let protection = self.sessionProtectionEnabled
            let snapshotter = makeSessionSnapshotter()

            func abortSwitch(_ titleKey: String, _ message: String) {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: NSLocalizedString(titleKey, comment: ""), message: message)
                    self.refreshAccounts()
                }
            }

            // Post-swap abort: auth.json already holds the target's tokens, so
            // first restore it from the previous account file (synced by
            // syncActiveAuthSnapshot above). If that restore fails, point the
            // registry at the target instead — auth.json and registry stay
            // consistent either way, and neither account's stored tokens are
            // touched, so a retry can never overwrite them.
            func abortPostSwap(_ titleKey: String, _ message: String, registryUpdated: Bool) {
                if let restoreError = restorePreviousAuth(previousEmail: previousActiveEmail) {
                    if !registryUpdated { _ = self.updateRegistryActiveKey(decodeBase64Key(key)) }
                    abortSwitch(titleKey, String(format: NSLocalizedString("alert_restore_failed_msg", comment: ""), restoreError))
                } else {
                    if registryUpdated { _ = self.updateRegistryActiveKey(previousActiveEmail) }
                    abortSwitch(titleKey, message)
                }
            }

            // Session protection: baseline snapshot of protected files.
            var beforeSnapshot: SessionSnapshot?
            if protection {
                do { beforeSnapshot = try snapshotter.capture(mode: .contentHashed) }
                catch {
                    abortSwitch("alert_snapshot_failed", NSLocalizedString("alert_snapshot_failed_msg", comment: ""))
                    return
                }
            }

            // Refresh target account's token before switching
            if let targetData = try? Data(contentsOf: URL(fileURLWithPath: targetAuthPath)),
               let targetAuth = try? JSONSerialization.jsonObject(with: targetData) as? [String: Any] {
                var updatedAuth = normalizeAuth(targetAuth)
                if let tokens = updatedAuth["tokens"] as? [String: Any],
                   let refreshToken = tokens["refresh_token"] as? String,
                   let refreshed = self.refreshAccessToken(refreshToken: refreshToken) {
                    var updatedTokens = tokens
                    updatedTokens["access_token"] = refreshed.accessToken
                    if let newRefresh = refreshed.newRefreshToken {
                        updatedTokens["refresh_token"] = newRefresh
                    }
                    if let idToken = refreshed.idToken {
                        updatedTokens["id_token"] = idToken
                    }
                    updatedAuth["tokens"] = updatedTokens
                }
                if let newData = try? JSONSerialization.data(withJSONObject: updatedAuth, options: .prettyPrinted) {
                    try? newData.write(to: URL(fileURLWithPath: targetAuthPath), options: .atomic)
                }
            }

            // Quiescent baseline is captured immediately before the swap so the
            // isolation window covers the swap alone — not the multi-second
            // token refresh, during which the running Codex app legitimately
            // appends to session files.
            var quiescentBefore: SessionSnapshot?
            if protection {
                do { quiescentBefore = try snapshotter.capture(mode: .metadataOnly) }
                catch {
                    abortSwitch("alert_snapshot_failed", NSLocalizedString("alert_snapshot_failed_msg", comment: ""))
                    return
                }
            }

            do {
                let targetURL = URL(fileURLWithPath: targetAuthPath)
                let mainURL = URL(fileURLWithPath: mainAuthPath)
                if FileManager.default.fileExists(atPath: mainAuthPath) {
                    try FileManager.default.removeItem(at: mainURL)
                }
                try FileManager.default.copyItem(at: targetURL, to: mainURL)
            } catch {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: NSLocalizedString("alert_switch_failed", comment: ""), message: error.localizedDescription)
                    self.refreshAccounts()
                }
                return
            }

            // Authentication-isolation check over the swap window only. The
            // switcher writes nothing but auth.json (excluded from
            // fingerprints), so any diff here is external interference.
            if protection, let before = quiescentBefore {
                let after: SessionSnapshot
                do { after = try snapshotter.capture(mode: .metadataOnly) }
                catch {
                    abortPostSwap("alert_snapshot_failed", NSLocalizedString("alert_snapshot_failed_msg", comment: ""), registryUpdated: false)
                    return
                }
                if !snapshotter.compare(before, after).isUnchanged {
                    abortPostSwap(
                        "alert_protected_files_changed",
                        NSLocalizedString("alert_protected_files_changed_msg", comment: ""),
                        registryUpdated: false)
                    return
                }
            }

            let registryError = self.updateRegistryActiveKey(decodeBase64Key(key))

            // Destructive-change check runs BEFORE the app restart. If it
            // fires, auth.json is restored while the still-running app holds
            // the previous account's credentials in memory — no second restart
            // is needed and nothing is left inconsistent.
            if protection, let before = beforeSnapshot {
                let after: SessionSnapshot
                do { after = try snapshotter.capture(mode: .contentHashed) }
                catch {
                    abortPostSwap("alert_snapshot_failed", NSLocalizedString("alert_snapshot_failed_msg", comment: ""), registryUpdated: true)
                    return
                }
                let diff = snapshotter.compare(before, after)
                if diff.hasDestructiveChange {
                    abortPostSwap(
                        "alert_session_files_missing",
                        String(format: NSLocalizedString("alert_session_files_missing_msg", comment: ""), diff.deleted.joined(separator: "\n")),
                        registryUpdated: true)
                    return
                }
                DispatchQueue.main.async {
                    self.lastSnapshotComparison = diff
                }
            }

            let restartResult = scope.reflectCodexApp
                ? self.restartCodexApp(launchIfNotRunning: scope.launchCodexIfClosed)
                : CommandResult(status: 0, output: "Codex App reflection skipped.")

            DispatchQueue.main.async {
                self.isSwitching = false
                self.endSwitchAnimation()
                self.lastUsageFetch = nil
                if let registryError {
                    self.showAlert(title: NSLocalizedString("alert_switch_failed", comment: ""), message: registryError)
                } else if restartResult.status != 0 {
                    self.showAlert(title: NSLocalizedString("alert_relaunch_failed", comment: ""), message: restartResult.output)
                }
                self.refreshAccounts()
            }
        }
    }

    // MARK: Switch Animation

    private func beginSwitchAnimation(label: String) {
        switchAnimationTimer?.invalidate()
        switchAnimationFrame = 0
        switchingTitle = String(format: NSLocalizedString("switching_label", comment: ""), limitedLabel(label))
        updateSwitchAnimationTitle()
        switchAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.switchAnimationFrame += 1
            self.updateSwitchAnimationTitle()
        }
    }

    private func updateSwitchAnimationTitle() {
        let frame = switchAnimationFrames[switchAnimationFrame % switchAnimationFrames.count]
        statusItem.button?.toolTip = "\(switchingTitle) \(frame)"
    }

    private func endSwitchAnimation() {
        switchAnimationTimer?.invalidate()
        switchAnimationTimer = nil
    }

    // MARK: Account File Operations

    private func syncActiveAuthSnapshot() -> String? {
        let home = codexHomeDirectory()
        let registryURL = URL(fileURLWithPath: "\(home)/.codex/accounts/registry.json")
        let activeAuthURL = URL(fileURLWithPath: "\(home)/.codex/auth.json")

        do {
            let data = try Data(contentsOf: registryURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let activeKey = json["active_account_key"] as? String else {
                return NSLocalizedString("err_active_key", comment: "")
            }

            let encoded = encodeKey(activeKey)
            let accountAuthURL = URL(fileURLWithPath: "\(home)/.codex/accounts/\(encoded).auth.json")
            guard FileManager.default.fileExists(atPath: activeAuthURL.path) else {
                return String(format: NSLocalizedString("err_auth_missing", comment: ""), activeAuthURL.path)
            }

            // Clean up old backups before creating new one
            if let files = try? FileManager.default.contentsOfDirectory(atPath: accountAuthURL.deletingLastPathComponent().path) {
                let stem = accountAuthURL.deletingPathExtension().lastPathComponent
                for file in files where file.hasPrefix(stem + ".bak.") {
                    try? FileManager.default.removeItem(atPath: accountAuthURL.deletingLastPathComponent().appendingPathComponent(file).path)
                }
            }
            if FileManager.default.fileExists(atPath: accountAuthURL.path) {
                try FileManager.default.removeItem(at: accountAuthURL)
            }
            try FileManager.default.copyItem(at: activeAuthURL, to: accountAuthURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    private func updateRegistryActiveKey(_ key: String?) -> String? {
        let home = codexHomeDirectory()
        let accountsDir = "\(home)/.codex/accounts"
        let registryURL = URL(fileURLWithPath: "\(accountsDir)/registry.json")
        try? FileManager.default.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)

        var json: [String: Any]
        if let data = try? Data(contentsOf: registryURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        } else {
            json = [:]
        }
        if let key {
            json["active_account_key"] = key
        } else {
            json.removeValue(forKey: "active_account_key")
        }
        do {
            let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try newData.write(to: registryURL, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: API - Read Account Files

    private func readAccountFiles() -> (accounts: [AccountInfo], activeKey: String?) {
        let home = codexHomeDirectory()
        let accountsDir = "\(home)/.codex/accounts"
        let fm = FileManager.default

        var activeKey: String?
        let registryURL = URL(fileURLWithPath: "\(accountsDir)/registry.json")
        if let data = try? Data(contentsOf: registryURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = json["active_account_key"] as? String {
            activeKey = encodeKey(key)
        }

        var accounts: [AccountInfo] = []
        if let files = try? fm.contentsOfDirectory(atPath: accountsDir) {
            let authFiles = files.filter { $0.hasSuffix(".auth.json") }.sorted()
            for filename in authFiles {
                let base64Key = String(filename.dropLast(10))
                let email = decodeBase64Key(base64Key) ?? base64Key
                let filePath = "\(accountsDir)/\(filename)"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                      let authDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                accounts.append(AccountInfo(
                    key: base64Key,
                    email: email,
                    auth: authDict,
                    isActive: base64Key == activeKey
                ))
            }
        }

        if accounts.isEmpty {
            let singleAuthURL = URL(fileURLWithPath: "\(home)/.codex/auth.json")
            if let data = try? Data(contentsOf: singleAuthURL),
               let authDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let email = extractEmail(from: authDict) ?? "codex"
                accounts.append(AccountInfo(key: "single", email: email, auth: authDict, isActive: true))
            }
        }

        return (accounts, activeKey)
    }


    private func getTokens(from auth: [String: Any]) -> (accessToken: String, refreshToken: String, accountId: String?)? {
        guard let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String else { return nil }
        let accountId = tokens["account_id"] as? String ?? auth["account_id"] as? String
        return (accessToken, refreshToken, accountId)
    }

    // MARK: API - Fetch Usage

    private let usageAPIURLs = [
        "https://chatgpt.com/backend-api/codex/usage",
        "https://chatgpt.com/backend-api/wham/usage",
        "https://chatgpt.com/api/codex/usage"
    ]

    private func fetchUsage(accessToken: String, accountId: String?) -> FetchResult {
        var gotAuthError = false
        for urlString in usageAPIURLs {
            guard let url = URL(string: urlString) else { continue }
            var headers = [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json"
            ]
            if let accountId {
                headers["chatgpt-account-id"] = accountId
            }
            let result = httpGet(url: url, headers: headers)
            guard let response = result.response else { continue }
            if response.statusCode == 401 || response.statusCode == 403 {
                gotAuthError = true
                continue
            }
            if response.statusCode == 200, let data = result.data, let parsed = parseUsageResponse(data) {
                return .success(parsed)
            }
        }
        return gotAuthError ? .needsRefresh : .failed
    }

    private func fetchUsageWithRefresh(accessToken: String, accountId: String?, refreshToken: String, accountInfo: AccountInfo) -> ParsedUsage? {
        let result = fetchUsage(accessToken: accessToken, accountId: accountId)
        switch result {
        case .success(let usage):
            return usage
        case .needsRefresh:
            guard let refresh = refreshAccessToken(refreshToken: refreshToken) else {
                return fetchUsageViaWebView(accessToken: accessToken, accountId: accountId)
            }
            saveUpdatedTokens(for: accountInfo, newAccessToken: refresh.accessToken, newRefreshToken: refresh.newRefreshToken, idToken: refresh.idToken)
            let retry = fetchUsage(accessToken: refresh.accessToken, accountId: accountId)
            if case .success(let usage) = retry { return usage }
            return fetchUsageViaWebView(accessToken: refresh.accessToken, accountId: accountId)
        case .failed:
            return fetchUsageViaWebView(accessToken: accessToken, accountId: accountId)
        }
    }

    private func fetchUsageViaWebView(accessToken: String, accountId: String?) -> ParsedUsage? {
        let urlString = usageAPIURLs[0]
        guard let url = URL(string: urlString) else { return nil }
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json"
        ]
        if let accountId {
            headers["chatgpt-account-id"] = accountId
        }
        let fetcher = WebViewFetcher()
        guard let data = fetcher.fetch(url: url, headers: headers) else { return nil }
        return parseUsageResponse(data)
    }

    private func refreshAccessToken(refreshToken: String) -> (accessToken: String, newRefreshToken: String?, idToken: String?)? {
        guard let url = URL(string: "https://auth.openai.com/oauth/token"),
              let encoded = refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let scope = "openid profile email offline_access"
        let scopeEncoded = scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope
        let body = "grant_type=refresh_token&refresh_token=\(encoded)&client_id=app_EMoamEEZ73f0CkXaXp7hrann&scope=\(scopeEncoded)"
        let result = httpPost(url: url, body: body)
        guard let data = result.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else { return nil }
        return (accessToken, json["refresh_token"] as? String, json["id_token"] as? String)
    }

    private func saveUpdatedTokens(for info: AccountInfo, newAccessToken: String, newRefreshToken: String? = nil, idToken: String? = nil) {
        var auth = normalizeAuth(info.auth)
        if var tokens = auth["tokens"] as? [String: Any] {
            tokens["access_token"] = newAccessToken
            if let newRefreshToken {
                tokens["refresh_token"] = newRefreshToken
            }
            if let idToken {
                tokens["id_token"] = idToken
            }
            auth["tokens"] = tokens
        }

        let home = codexHomeDirectory()
        guard let data = try? JSONSerialization.data(withJSONObject: auth, options: .prettyPrinted) else { return }
        let filePath = info.key == "single"
            ? "\(home)/.codex/auth.json"
            : "\(home)/.codex/accounts/\(info.key).auth.json"
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        if info.isActive {
            try? data.write(to: URL(fileURLWithPath: "\(home)/.codex/auth.json"), options: .atomic)
        }
    }

    // MARK: API - Parse Response

    private func parseUsageResponse(_ data: Data) -> ParsedUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let plan = json["plan_type"] as? String ?? json["plan"] as? String
        let rateLimit = json["rate_limit"] as? [String: Any] ?? json["rate_limits"] as? [String: Any]
        let windows = classifyUsageWindows(rateLimit)
        return ParsedUsage(
            plan: plan,
            fiveHour: windows.fiveHour,
            weekly: windows.weekly
        )
    }

    // MARK: HTTP

    // MARK: WKWebView-based fetch (bypasses Cloudflare)

    private class WebViewFetcher: NSObject, WKNavigationDelegate {
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Data?
        private var webView: WKWebView!
        private var finished = false

        func fetch(url: URL, headers: [String: String]) -> Data? {
            DispatchQueue.main.sync { [self] in
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                let wv = WKWebView(frame: .zero, configuration: config)
                wv.navigationDelegate = self
                webView = wv

                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                wv.load(request)
            }
            _ = semaphore.wait(timeout: .now() + 25)
            DispatchQueue.main.async { [self] in webView = nil }
            return result
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Small delay for Cloudflare challenge completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                guard !finished else { return }
                webView.evaluateJavaScript("document.body.innerText") { [self] body, _ in
                    guard !finished else { return }
                    finished = true
                    if let text = body as? String {
                        result = text.data(using: .utf8)
                    }
                    semaphore.signal()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !finished else { return }
            finished = true
            semaphore.signal()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !finished else { return }
            finished = true
            semaphore.signal()
        }
    }

    // MARK: OAuth

    // Public OAuth client ID from the official Codex CLI — this is a public value, not a secret.
    private let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let oauthIssuer = "https://auth.openai.com"

    private func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, count)
        return bytes
    }

    private func generateCodeVerifier() -> String {
        Data(randomBytes(32)).base64URLEncoded
    }

    private func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: verifier.data(using: .ascii)!)
        return Data(hash).base64URLEncoded
    }

    private func randomState() -> String {
        Data(randomBytes(16)).base64URLEncoded
    }

    // MARK: Browser Login

    private func performBrowserLogin() {
        guard !isSwitching else { return }
        isSwitching = true
        statusItem.button?.toolTip = NSLocalizedString("adding_account", comment: "")
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            let verifier = self.generateCodeVerifier()
            let state = self.randomState()

            var port: UInt16 = 1455
            var code: String?
            for p in [1455, 1457] {
                port = UInt16(p)
                code = self.waitForOAuthCallback(port: port, expectedState: state, codeVerifier: verifier)
                if code != nil { break }
            }

            guard let code else {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.showAlert(title: NSLocalizedString("alert_device_login_failed", comment: ""), message: "No callback received.")
                    self.refreshAccounts()
                }
                return
            }

            let redirectURI = "http://localhost:\(port)/auth/callback"
            guard let tokens = self.exchangeCodeForTokens(code: code, redirectURI: redirectURI, codeVerifier: verifier) else {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.showAlert(title: NSLocalizedString("alert_device_login_failed", comment: ""), message: "Token exchange failed.")
                    self.refreshAccounts()
                }
                return
            }

            let saved = self.saveNewAccount(tokens: tokens)
            let _ = self.restartCodexApp(launchIfNotRunning: true)

            DispatchQueue.main.async {
                self.isSwitching = false
                if !saved {
                    self.showAlert(title: NSLocalizedString("alert_device_login_failed", comment: ""), message: "Could not save account.")
                }
                self.lastUsageFetch = nil
                self.refreshAccounts()
            }
        }
    }

    private func waitForOAuthCallback(port: UInt16, expectedState: String, codeVerifier: String, timeout: TimeInterval = 300) -> String? {
        // Start server first, then open browser
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))
        // accept() on a Darwin listening socket ignores SO_RCVTIMEO, so a
        // blocking accept would park this thread forever when no callback
        // ever arrives — leaving isSwitching stuck and every account switch
        // silently dead. Poll a non-blocking listener against a deadline.
        let currentFlags = fcntl(sock, F_GETFL)
        guard currentFlags >= 0, fcntl(sock, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 1) == 0 else { return nil }

        // Open browser after server is listening
        let scope = "openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke"
        let challengeStr = codeChallenge(for: codeVerifier)
        let authURL = "\(oauthIssuer)/oauth/authorize?response_type=code&client_id=\(oauthClientID)&redirect_uri=http%3A%2F%2Flocalhost%3A\(port)%2Fauth%2Fcallback&scope=\(scope)&code_challenge=\(challengeStr)&code_challenge_method=S256&state=\(expectedState)"
        _ = cliRun("/usr/bin/open", [authURL])

        let deadline = Date().addingTimeInterval(timeout)
        var client: Int32 = -1
        while Date() < deadline {
            client = accept(sock, nil, nil)
            if client >= 0 { break }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard client >= 0 else { return nil }
        // Accepted sockets do not inherit O_NONBLOCK; give the request read
        // its own deadline so a silent connection cannot stall login either.
        var recvTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout.size(ofValue: recvTimeout)))
        defer { close(client) }

        var buf = [UInt8](repeating: 0, count: 8192)
        let n = recv(client, &buf, buf.count, 0)
        guard n > 0 else { return nil }

        let request = String(bytes: buf.prefix(n), encoding: .ascii) ?? ""
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body><h1>OK</h1><script>window.close()</script></body></html>"
        _ = response.withCString { send(client, $0, response.utf8.count, 0) }

        guard let pathStart = request.range(of: "GET "),
              let pathEnd = request.range(of: " HTTP", range: pathStart.upperBound..<request.endIndex) else { return nil }
        let path = String(request[pathStart.upperBound..<pathEnd.lowerBound])

        guard let qMark = path.range(of: "?") else { return nil }
        var params: [String: String] = [:]
        for pair in path[qMark.upperBound...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let val = String(kv[1]).removingPercentEncoding {
                params[String(kv[0])] = val
            }
        }
        if params["error"] != nil { return nil }
        guard params["state"] == expectedState else { return nil }
        return params["code"]
    }

    // MARK: Device Code Login

    private func performDeviceCodeLogin() {
        guard !isSwitching else { return }
        isSwitching = true
        statusItem.button?.toolTip = NSLocalizedString("adding_account", comment: "")
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = URL(string: "\(self.oauthIssuer)/api/accounts/deviceauth/usercode") else { return }
            let scope = "openid profile email offline_access"
            let body = "{\"client_id\":\"\(self.oauthClientID)\",\"scope\":\"\(scope)\"}"
            let result = httpPostJSON(url: url, body: body)
            guard let data = result.data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let deviceAuthId = json["device_auth_id"] as? String,
                  let userCode = json["user_code"] as? String else {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.showAlert(title: NSLocalizedString("alert_device_login_failed", comment: ""), message: "Failed to get device code.")
                    self.refreshAccounts()
                }
                return
            }

            let interval = Int(json["interval"] as? String ?? "5") ?? 5
            let verifyURL = "https://auth.openai.com/codex/device"

            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(userCode, forType: .string)
                self.statusItem.button?.toolTip = userCode
                _ = cliRun("/usr/bin/open", [verifyURL])
            }

            // Poll for completion
            var authResult: [String: Any]?
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: TimeInterval(interval))
                guard let pollURL = URL(string: "\(self.oauthIssuer)/api/accounts/deviceauth/token") else { break }
                let pollBody = "{\"device_auth_id\":\"\(deviceAuthId)\",\"user_code\":\"\(userCode)\"}"
                let pollResult = httpPostJSON(url: pollURL, body: pollBody)
                if let pollData = pollResult.data,
                   let pollJson = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any],
                   let authCode = pollJson["authorization_code"] as? String {
                    authResult = ["authorization_code": authCode, "code_verifier": pollJson["code_verifier"] as? String ?? ""]
                    break
                }
                if let resp = pollResult.response, resp.statusCode == 200 {
                    continue
                }
            }

            guard let authResult else {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.showAlert(title: NSLocalizedString("alert_device_login_failed", comment: ""), message: "Timed out.")
                    self.refreshAccounts()
                }
                return
            }

            guard let authCode = authResult["authorization_code"] as? String,
                  let codeVerifier = authResult["code_verifier"] as? String else {
                DispatchQueue.main.async { self.isSwitching = false; self.refreshAccounts() }
                return
            }

            let redirectURI = "\(self.oauthIssuer)/deviceauth/callback"
            guard let tokens = self.exchangeCodeForTokens(code: authCode, redirectURI: redirectURI, codeVerifier: codeVerifier) else {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.showAlert(title: NSLocalizedString("alert_device_login_failed", comment: ""), message: "Token exchange failed.")
                    self.refreshAccounts()
                }
                return
            }

            let saved = self.saveNewAccount(tokens: tokens)
            let _ = self.restartCodexApp(launchIfNotRunning: true)

            DispatchQueue.main.async {
                self.isSwitching = false
                if !saved {
                    self.showAlert(title: NSLocalizedString("alert_device_login_failed", comment: ""), message: "Could not save account.")
                }
                self.lastUsageFetch = nil
                self.refreshAccounts()
            }
        }
    }

    // MARK: Token Exchange

    private func exchangeCodeForTokens(code: String, redirectURI: String, codeVerifier: String) -> [String: Any]? {
        guard let url = URL(string: "\(oauthIssuer)/oauth/token") else { return nil }
        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)&client_id=\(oauthClientID)&code_verifier=\(codeVerifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? codeVerifier)"
        let result = httpPost(url: url, body: body)
        guard let data = result.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private func saveNewAccount(tokens: [String: Any]) -> Bool {
        guard let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String else { return false }

        let accountId = tokens["account_id"] as? String ?? extractAccountIdFromToken(accessToken)
        var idToken = tokens["id_token"] as? String
        let email = Self.extractEmailFromToken(accessToken) ?? "account_\(Int(Date().timeIntervalSince1970))"

        // If id_token is missing, immediately refresh to obtain it
        var finalAccessToken = accessToken
        var finalRefreshToken = refreshToken
        if idToken == nil {
            if let refreshed = refreshAccessToken(refreshToken: refreshToken) {
                finalAccessToken = refreshed.accessToken
                if let newRefresh = refreshed.newRefreshToken { finalRefreshToken = newRefresh }
                idToken = refreshed.idToken
            }
        }

        var tokenDict: [String: Any] = [
            "access_token": finalAccessToken,
            "refresh_token": finalRefreshToken,
        ]
        if let accountId { tokenDict["account_id"] = accountId }
        if let idToken { tokenDict["id_token"] = idToken }

        let rawAuth: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": tokenDict
        ]
        let auth = normalizeAuth(rawAuth)

        let home = codexHomeDirectory()
        let accountsDir = "\(home)/.codex/accounts"
        let mainAuthPath = "\(home)/.codex/auth.json"
        let registryPath = "\(accountsDir)/registry.json"

        try? FileManager.default.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)

        // If no registry exists, migrate existing single auth.json as first account
        if !FileManager.default.fileExists(atPath: registryPath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: mainAuthPath)),
               let authDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let existingEmail = extractEmail(from: authDict), existingEmail != email {
                let existingKey = encodeKey(existingEmail)
                let existingPath = "\(accountsDir)/\(existingKey).auth.json"
                try? data.write(to: URL(fileURLWithPath: existingPath), options: .atomic)
                updateRegistryActiveKey(existingEmail)
            }
        } else {
            // Existing multi-account: sync current active account before overwrite
            _ = syncActiveAuthSnapshot()
        }

        let key = encodeKey(email)
        let accountPath = "\(accountsDir)/\(key).auth.json"

        guard let data = try? JSONSerialization.data(withJSONObject: auth, options: .prettyPrinted) else { return false }
        do {
            if FileManager.default.fileExists(atPath: accountPath) {
                try? FileManager.default.removeItem(atPath: accountPath)
            }
            try data.write(to: URL(fileURLWithPath: accountPath), options: .atomic)
            try data.write(to: URL(fileURLWithPath: mainAuthPath), options: .atomic)
        } catch {
            return false
        }

        updateRegistryActiveKey(email)
        return true
    }

    private static func extractEmailFromToken(_ token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        let payload = String(segments[1])
        let padding = String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload + padding),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    private func extractAccountIdFromToken(_ token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        let payload = String(segments[1])
        let padding = String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload + padding),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    // MARK: Process Management

    private func restartCodexApp(launchIfNotRunning: Bool) -> CommandResult {
        cliRestartCodex(launchIfNotRunning: launchIfNotRunning)
    }

    // MARK: Utility

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func displayLabel(for account: CodexAccount) -> String {
        if let custom = customLabel(forEmail: account.email) {
            return limitedLabel(custom)
        }
        let prefix = account.email.split(separator: "@").first.map(String.init) ?? account.key
        return limitedLabel(prefix)
    }

    private func limitedLabel(_ label: String) -> String {
        String(label.prefix(5))
    }

    private func displayPlan(_ plan: String) -> String {
        guard let first = plan.first else { return plan }
        return first.uppercased() + plan.dropFirst().lowercased()
    }

    private func customLabel(forEmail email: String) -> String? {
        accountLabels()[email]
    }

    private func setCustomLabel(_ label: String, forEmail email: String) {
        var labels = accountLabels()
        labels[email] = label
        UserDefaults.standard.set(labels, forKey: labelsDefaultsKey)
    }

    private func clearCustomLabel(forEmail email: String) {
        var labels = accountLabels()
        labels.removeValue(forKey: email)
        UserDefaults.standard.set(labels, forKey: labelsDefaultsKey)
    }

    private func accountLabels() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: labelsDefaultsKey) as? [String: String] ?? [:]
    }

}

// MARK: - CLI Mode

private func runCLI() -> Never {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        cliUsage()
    }

    switch command {
    case "rotation":
        handleRotation(args.dropFirst())
    case "scope":
        handleScope(args.dropFirst())
    case "list":
        handleList()
    case "active":
        handleActive()
    case "switch":
        handleSwitch(args.dropFirst())
    case "usage":
        handleUsage(args.dropFirst())
    case "session":
        handleSession(args.dropFirst())
    default:
        fputs("Error: unknown command '\(command)'\n\n", stderr)
        cliUsage()
    }
}

private func cliUsage() -> Never {
    fputs("Usage: CodexAccountSwitcher <command> [args]\n\n" +
          "Commands:\n" +
          "  list                          List all accounts\n" +
          "  active                        Show active account\n" +
          "  switch <key|email>            Switch to account\n" +
          "  usage                         Show usage for active account\n" +
          "  usage parse <json-file>       Classify a saved usage payload (debug)\n" +
          "  scope status                  Show switch scope\n" +
          "  scope cli on|off              Apply switch to CLI next run\n" +
          "  scope app on|off              Reflect switch in Codex App immediately\n" +
          "  scope launch on|off           Launch Codex App if closed during reflection\n" +
          "  rotation status               Show rotation state\n" +
          "  rotation on|off               Toggle rotation\n" +
          "  rotation threshold5h <10|20|30|40>      Set 5-hour switch threshold (remaining %)\n" +
          "  rotation thresholdWeekly <10|20|30|40>  Set weekly switch threshold (remaining %)\n" +
          "  rotation decide <a5> <aWk> <i5> <iWk>   Evaluate fallback (used %, '-' unknown)\n" +
          "  session protection [on|off]   Show or toggle session protection\n" +
          "  session snapshot [metadata]   Capture a protected-file snapshot (debug)\n" +
          "  session continuity begin      Start a continuity test (prints marker)\n" +
          "  session continuity locate     Locate the marker in session files\n" +
          "  session continuity finish <pass|partial|fail>  Record a verdict\n", stderr)
    exit(1)
}

private func handleSession(_ args: ArraySlice<String>) -> Never {
    let subcommand = args.first

    switch subcommand {
    case "protection":
        let rest = args.dropFirst()
        if let value = rest.first {
            guard ["on", "off"].contains(value) else {
                fputs("Usage: CodexAccountSwitcher session protection <on|off>\n", stderr)
                exit(1)
            }
            SessionProtectionDefaults.enabled = (value == "on")
            print("protection:\(value)")
            exit(0)
        }
        print("protection:\(SessionProtectionDefaults.enabled ? "on" : "off")")
        exit(0)

    case "snapshot":
        let mode: CaptureMode = args.dropFirst().first == "metadata" ? .metadataOnly : .contentHashed
        do {
            let snapshot = try makeSessionSnapshotter().capture(mode: mode)
            print("entries:\(snapshot.entries.count) active:\(snapshot.activeAccountKey ?? "-") createdAt:\(snapshot.createdAt)")
            exit(0)
        } catch {
            fputs("Error: snapshot failed — \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "continuity":
        handleContinuity(args.dropFirst())

    default:
        fputs("Usage: CodexAccountSwitcher session <protection|snapshot|continuity> [args]\n", stderr)
        exit(1)
    }
}

private func handleContinuity(_ args: ArraySlice<String>) -> Never {
    let store = ContinuityTestStore()

    switch args.first {
    case "begin":
        let accounts = cliReadAccounts()
        let source = accounts.first(where: { $0.isActive })?.email
        do {
            let record = try store.begin(sourceAccount: source)
            print("marker:\(record.marker)")
            exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "locate":
        do {
            guard let record = try store.loadRecord() else {
                fputs("Error: no continuity test in progress\n", stderr)
                exit(1)
            }
            guard let match = try makeSessionMarkerFinder().find(marker: record.marker) else {
                print("marker:not-found")
                exit(1)
            }
            let updated = try store.recordMarkerMatch(match)
            print("marker:found session:\(updated.sessionID ?? "-") path:\(match.fileURL.path)")
            exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "finish":
        guard let verdictRaw = args.dropFirst().first,
              let verdict = ContinuityVerdict(rawValue: verdictRaw) else {
            fputs("Usage: CodexAccountSwitcher session continuity finish <pass|partial|fail>\n", stderr)
            exit(1)
        }
        do {
            let accounts = cliReadAccounts()
            let target = accounts.first(where: { $0.isActive })?.email
            let record = try store.finish(verdict: verdict, targetAccount: target, followUpSucceeded: nil, notes: nil)
            print("verdict:\(verdictRaw) target:\(record.targetAccount ?? "-")")
            exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    default:
        fputs("Usage: CodexAccountSwitcher session continuity <begin|locate|finish>\n", stderr)
        exit(1)
    }
}

private func handleRotation(_ args: ArraySlice<String>) -> Never {
    let defaults = switcherDefaults()
    let subcommand = args.first
    let rotationUsage = "Usage: CodexAccountSwitcher rotation <status|on|off|threshold5h|thresholdWeekly|decide>\n"

    func setThreshold(key: String, label: String) -> Never {
        guard let valueStr = args.dropFirst().first,
              let value = Int(valueStr),
              RotationThresholdDefaults.steps.contains(value) else {
            fputs("Error: \(label) must be one of: 10, 20, 30, 40\n", stderr)
            exit(1)
        }
        RotationThresholdDefaults.set(value, forKey: key)
        print("\(label):\(value)")
        exit(0)
    }

    switch subcommand {
    case "status":
        let enabled = defaults.bool(forKey: "rotationEnabled")
        let thr5h = RotationThresholdDefaults.value(forKey: RotationThresholdDefaults.key5h)
        let thrWeekly = RotationThresholdDefaults.value(forKey: RotationThresholdDefaults.keyWeekly)
        print("rotation:\(enabled ? "on" : "off") thr5h:\(thr5h) thrWeekly:\(thrWeekly)")
        exit(0)

    case "on":
        defaults.set(true, forKey: "rotationEnabled")
        print("rotation:on")
        exit(0)

    case "off":
        defaults.set(false, forKey: "rotationEnabled")
        print("rotation:off")
        exit(0)

    case "threshold5h":
        setThreshold(key: RotationThresholdDefaults.key5h, label: "thr5h")

    case "thresholdWeekly":
        setThreshold(key: RotationThresholdDefaults.keyWeekly, label: "thrWeekly")

    case "decide":
        let rest = Array(args.dropFirst())
        guard rest.count == 4 else {
            fputs("Usage: CodexAccountSwitcher rotation decide <active5h> <activeWeekly> <inactive5h> <inactiveWeekly>\n", stderr)
            exit(1)
        }
        func parsePercent(_ s: String) -> Int?? {
            if s == "-" { return .some(Int?.none) }          // known-unknown
            guard let v = Int(s), (0...100).contains(v) else { return Int??.none }  // invalid
            return .some(Int?.some(v))
        }
        guard let a5 = parsePercent(rest[0]),
              let aWk = parsePercent(rest[1]),
              let i5 = parsePercent(rest[2]),
              let iWk = parsePercent(rest[3]) else {
            fputs("Error: percentages must be 0-100 or '-'\n", stderr)
            exit(1)
        }
        let thr5h = RotationThresholdDefaults.value(forKey: RotationThresholdDefaults.key5h)
        let thrWeekly = RotationThresholdDefaults.value(forKey: RotationThresholdDefaults.keyWeekly)
        let activeOver = accountOverLimit(fiveHourUsed: a5, weeklyUsed: aWk, threshold5h: thr5h, thresholdWeekly: thrWeekly)
        let inactiveOver = accountOverLimit(fiveHourUsed: i5, weeklyUsed: iWk, threshold5h: thr5h, thresholdWeekly: thrWeekly)
        print(decideRotation(activeOverLimit: activeOver, inactiveOverLimit: inactiveOver).rawValue)
        exit(0)

    default:
        fputs(rotationUsage, stderr)
        exit(1)
    }
}

private func handleScope(_ args: ArraySlice<String>) -> Never {
    let subcommand = args.first

    switch subcommand {
    case "status":
        let scope = SwitchScopeDefaults.current()
        print("cli:\(scope.applyToCLI ? "on" : "off") app:\(scope.reflectCodexApp ? "on" : "off") launch:\(scope.launchCodexIfClosed ? "on" : "off")")
        exit(0)

    case "cli":
        guard let value = args.dropFirst().first, ["on", "off"].contains(value) else {
            fputs("Usage: CodexAccountSwitcher scope cli <on|off>\n", stderr)
            exit(1)
        }
        SwitchScopeDefaults.setApplyToCLI(value == "on")
        print("cli:\(value)")
        exit(0)

    case "app":
        guard let value = args.dropFirst().first, ["on", "off"].contains(value) else {
            fputs("Usage: CodexAccountSwitcher scope app <on|off>\n", stderr)
            exit(1)
        }
        SwitchScopeDefaults.setReflectCodexApp(value == "on")
        print("app:\(value)")
        exit(0)

    case "launch":
        guard let value = args.dropFirst().first, ["on", "off"].contains(value) else {
            fputs("Usage: CodexAccountSwitcher scope launch <on|off>\n", stderr)
            exit(1)
        }
        SwitchScopeDefaults.setLaunchCodexIfClosed(value == "on")
        print("launch:\(value)")
        exit(0)

    default:
        fputs("Usage: CodexAccountSwitcher scope <status|cli|app|launch> [on|off]\n", stderr)
        exit(1)
    }
}

private func handleList() -> Never {
    let accounts = cliReadAccounts()
    if accounts.isEmpty {
        print("no accounts")
        exit(0)
    }

    let urls = [
        "https://chatgpt.com/backend-api/codex/usage",
        "https://chatgpt.com/backend-api/wham/usage",
        "https://chatgpt.com/api/codex/usage"
    ]

    for acct in accounts {
        var parts: [String] = []
        parts.append(acct.isActive ? "*" : " ")
        parts.append(acct.key)
        parts.append(acct.email)

        if let tokens = acct.auth["tokens"] as? [String: Any],
           let accessToken = tokens["access_token"] as? String {
            let accountId = tokens["account_id"] as? String ?? acct.auth["account_id"] as? String

            for urlString in urls {
                guard let url = URL(string: urlString) else { continue }
                var headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"]
                if let accountId { headers["chatgpt-account-id"] = accountId }
                let result = httpGet(url: url, headers: headers)
                guard let response = result.response, response.statusCode == 200, let data = result.data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let plan = json["plan_type"] as? String ?? json["plan"] as? String ?? ""
                let rateLimit = json["rate_limit"] as? [String: Any] ?? json["rate_limits"] as? [String: Any]
                let windows = classifyUsageWindows(rateLimit)

                if !plan.isEmpty { parts.append("plan:\(plan)") }
                if let pct = windows.fiveHour?.usedPercent { parts.append("5h:\(pct)%") }
                if let pct = windows.weekly?.usedPercent { parts.append("weekly:\(pct)%") }
                break
            }
        }

        print(parts.joined(separator: "\t"))
    }
    exit(0)
}

private func handleActive() -> Never {
    let accounts = cliReadAccounts()
    guard let active = accounts.first(where: { $0.isActive }) else {
        print("none")
        exit(1)
    }
    print(active.email)
    exit(0)
}

private func handleSwitch(_ args: ArraySlice<String>) -> Never {
    guard let target = args.first else {
        fputs("Error: switch requires an account key or email\n", stderr)
        exit(1)
    }
    let scope = SwitchScopeDefaults.current()
    guard scope.applyToCLI else {
        fputs("Error: CLI next-run apply is off; no shared auth file will be changed.\n", stderr)
        exit(1)
    }

    let accounts = cliReadAccounts()
    let match = accounts.first { $0.key == target || $0.email == target }
    guard let match else {
        fputs("Error: account '\(target)' not found\n", stderr)
        exit(1)
    }
    guard !match.isActive else {
        fputs("Error: '\(match.email)' is already active\n", stderr)
        exit(1)
    }
    guard accounts.count >= 2 else {
        fputs("Error: need at least 2 accounts to switch\n", stderr)
        exit(1)
    }

    // 1. Backup current active auth
    if let syncError = cliSyncActiveSnapshot() {
        fputs("Error: \(syncError)\n", stderr)
        exit(1)
    }

    let home = codexHomeDirectory()
    let targetAuthPath = "\(home)/.codex/accounts/\(match.key).auth.json"
    let mainAuthPath = "\(home)/.codex/auth.json"

    // Session protection: baseline capture is fail-closed — an error aborts
    // the switch instead of proceeding unprotected.
    let protection = SessionProtectionDefaults.enabled
    let snapshotter = makeSessionSnapshotter()
    let previousEmail = accounts.first(where: { $0.isActive })?.email
    let targetEmail = decodeBase64Key(match.key) ?? match.key

    var beforeSnapshot: SessionSnapshot?
    if protection {
        do { beforeSnapshot = try snapshotter.capture(mode: .contentHashed) }
        catch {
            fputs("Error: session snapshot failed — \(error.localizedDescription); switch aborted before any file was changed.\n", stderr)
            exit(1)
        }
    }

    // 2. Refresh target account's token and normalize fields
    if let targetData = try? Data(contentsOf: URL(fileURLWithPath: targetAuthPath)),
       let targetAuth = try? JSONSerialization.jsonObject(with: targetData) as? [String: Any] {
        var updatedAuth = normalizeAuth(targetAuth)
        if let tokens = updatedAuth["tokens"] as? [String: Any],
           let refreshToken = tokens["refresh_token"] as? String,
           let refreshed = cliRefreshToken(refreshToken: refreshToken) {
            var updatedTokens = tokens
            updatedTokens["access_token"] = refreshed.accessToken
            if let newRefresh = refreshed.newRefreshToken {
                updatedTokens["refresh_token"] = newRefresh
            }
            if let idToken = refreshed.idToken {
                updatedTokens["id_token"] = idToken
            }
            updatedAuth["tokens"] = updatedTokens
        }
        if let newData = try? JSONSerialization.data(withJSONObject: updatedAuth, options: .prettyPrinted) {
            try? newData.write(to: URL(fileURLWithPath: targetAuthPath), options: .atomic)
        }
    }

    // Quiescent baseline immediately before the swap so the isolation window
    // covers the swap alone, not the token refresh.
    var quiescentBefore: SessionSnapshot?
    if protection {
        do { quiescentBefore = try snapshotter.capture(mode: .metadataOnly) }
        catch {
            fputs("Error: session snapshot failed — \(error.localizedDescription); switch aborted before any file was changed.\n", stderr)
            exit(1)
        }
    }

    // 3. Copy target auth to main auth.json
    do {
        let targetURL = URL(fileURLWithPath: targetAuthPath)
        let mainURL = URL(fileURLWithPath: mainAuthPath)
        if FileManager.default.fileExists(atPath: mainAuthPath) {
            try FileManager.default.removeItem(at: mainURL)
        }
        try FileManager.default.copyItem(at: targetURL, to: mainURL)
    } catch {
        fputs("Error: switch failed — \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    // Post-swap abort: restore the previous account's auth.json first; if that
    // fails, point the registry at the target so auth.json and registry stay
    // consistent either way and neither account's stored tokens are touched.
    func abortPostSwap(registryUpdated: Bool, _ message: String) -> Never {
        if let restoreError = restorePreviousAuth(previousEmail: previousEmail) {
            if !registryUpdated { _ = cliUpdateRegistry(targetEmail) }
            fputs("Error: \(message)\nRestore of \(previousEmail ?? "previous account") failed — \(restoreError). Registry left on \(targetEmail) to stay consistent.\n", stderr)
            exit(1)
        }
        if registryUpdated { _ = cliUpdateRegistry(previousEmail) }
        fputs("Error: \(message)\nRolled back to \(previousEmail ?? "previous account").\n", stderr)
        exit(1)
    }

    // Isolation check over the swap window only.
    if protection, let before = quiescentBefore {
        let after: SessionSnapshot
        do { after = try snapshotter.capture(mode: .metadataOnly) }
        catch {
            abortPostSwap(registryUpdated: false, "session snapshot failed — \(error.localizedDescription)")
        }
        if !snapshotter.compare(before, after).isUnchanged {
            abortPostSwap(registryUpdated: false, "protected files changed during the auth swap")
        }
    }

    // 4. Update registry
    if let regError = cliUpdateRegistry(targetEmail) {
        fputs("Warning: registry update failed — \(regError)\n", stderr)
    }

    // 5. Destructive-change check BEFORE the app restart, mirroring the GUI.
    if protection, let before = beforeSnapshot {
        let after: SessionSnapshot
        do { after = try snapshotter.capture(mode: .contentHashed) }
        catch {
            abortPostSwap(registryUpdated: true, "session snapshot failed — \(error.localizedDescription)")
        }
        let diff = snapshotter.compare(before, after)
        if diff.hasDestructiveChange {
            abortPostSwap(registryUpdated: true, "session files missing after switch:\n\(diff.deleted.joined(separator: "\n"))")
        }
        if !diff.isUnchanged {
            fputs("Warning: protected files changed — deleted:\(diff.deleted.count) modified:\(diff.modified.count) added:\(diff.added.count)\n", stderr)
        }
    }

    // 6. Reflect in Codex App if enabled
    if scope.reflectCodexApp {
        let result = cliRestartCodex(launchIfNotRunning: scope.launchCodexIfClosed)
        if result.status != 0 {
            fputs("Warning: Codex restart issue — \(result.output)\n", stderr)
        }
    }

    print("switched:\(match.email)")
    exit(0)
}

private func handleUsage(_ args: ArraySlice<String>) -> Never {
    // Offline classification of a saved usage JSON payload — used by tests and
    // debugging so the duration-based window mapping can be exercised without
    // hitting the live API.
    if args.first == "parse" {
        guard let path = args.dropFirst().first,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fputs("Usage: CodexAccountSwitcher usage parse <json-file>\n", stderr)
            exit(1)
        }
        let rateLimit = json["rate_limit"] as? [String: Any] ?? json["rate_limits"] as? [String: Any]
        let windows = classifyUsageWindows(rateLimit)
        let fiveHour = windows.fiveHour?.usedPercent.map(String.init) ?? "-"
        let weekly = windows.weekly?.usedPercent.map(String.init) ?? "-"
        print("5h:\(fiveHour) weekly:\(weekly)")
        exit(0)
    }

    let accounts = cliReadAccounts()
    guard let active = accounts.first(where: { $0.isActive }) else {
        fputs("Error: no active account\n", stderr)
        exit(1)
    }

    guard let tokens = active.auth["tokens"] as? [String: Any],
          let accessToken = tokens["access_token"] as? String else {
        fputs("Error: no access token for active account\n", stderr)
        exit(1)
    }
    let accountId = tokens["account_id"] as? String ?? active.auth["account_id"] as? String

    // Try fetching usage via API
    let urls = [
        "https://chatgpt.com/backend-api/codex/usage",
        "https://chatgpt.com/backend-api/wham/usage",
        "https://chatgpt.com/api/codex/usage"
    ]

    for urlString in urls {
        guard let url = URL(string: urlString) else { continue }
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json"
        ]
        if let accountId { headers["chatgpt-account-id"] = accountId }
        let result = httpGet(url: url, headers: headers)
        guard let response = result.response else { continue }
        if response.statusCode == 200, let data = result.data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let plan = json["plan_type"] as? String ?? json["plan"] as? String ?? "unknown"
            let rateLimit = json["rate_limit"] as? [String: Any] ?? json["rate_limits"] as? [String: Any]
            let windows = classifyUsageWindows(rateLimit)

            var parts = ["plan:\(plan)"]
            if let pct = windows.fiveHour?.usedPercent { parts.append("5h:\(pct)%") }
            if let pct = windows.weekly?.usedPercent { parts.append("weekly:\(pct)%") }
            print(parts.joined(separator: " "))
            exit(0)
        }
        if response.statusCode == 401 || response.statusCode == 403 { continue }
    }

    fputs("Error: could not fetch usage\n", stderr)
    exit(1)
}

// MARK: - Entry Point

if CommandLine.arguments.count > 1 {
    runCLI()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
