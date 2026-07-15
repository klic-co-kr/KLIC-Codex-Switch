import AppKit
import CryptoKit
import Foundation
import WebKit

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
    return (100 - used) <= remainingThreshold
}

func accountOverLimit(fiveHourUsed: Int?, weeklyUsed: Int?, threshold5h: Int, thresholdWeekly: Int) -> Bool {
    windowOverLimit(usedPercent: fiveHourUsed, remainingThreshold: threshold5h) ||
        windowOverLimit(usedPercent: weeklyUsed, remainingThreshold: thresholdWeekly)
}

func decideRotation(activeOverLimit: Bool, inactiveOverLimit: Bool) -> RotationDecision {
    guard activeOverLimit else { return .none }
    return inactiveOverLimit ? .allExhausted : .switchTarget
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
    let wasRunning = !cliCodexPIDs().isEmpty
    for attempt in 1...6 {
        let pids = cliCodexPIDs()
        if pids.isEmpty { break }
        let signal = attempt == 1 ? "-TERM" : "-KILL"
        _ = cliRun("/bin/kill", [signal] + pids)
        Thread.sleep(forTimeInterval: 1)
    }
    let remaining = cliCodexPIDs()
    if !remaining.isEmpty {
        return CommandResult(status: 1, output: "Codex processes survived force quit: \(remaining.joined(separator: ", "))")
    }
    if !wasRunning && !launchIfNotRunning {
        return CommandResult(status: 0, output: "Codex App was not running; launch skipped.")
    }
    let openResult = cliRun("/usr/bin/open", ["-a", "Codex"])
    if openResult.status != 0 { return openResult }
    Thread.sleep(forTimeInterval: 4)
    let runningResult = cliRun("/usr/bin/osascript", ["-e", "application \"Codex\" is running"])
    if runningResult.output.trimmingCharacters(in: .whitespacesAndNewlines) != "true" {
        return CommandResult(status: 1, output: "Codex App did not report as running after launch.")
    }
    return CommandResult(status: 0, output: "ok")
}

private func cliCodexPIDs() -> [String] {
    let result = cliRun("/usr/bin/pgrep", ["-f", "/Applications/Codex\\.app/Contents/"])
    guard result.status == 0 else { return [] }
    return result.output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
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

            let registryError = self.updateRegistryActiveKey(decodeBase64Key(key))

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
        let primary = rateLimit?["primary_window"] as? [String: Any] ?? rateLimit?["primary"] as? [String: Any]
        let secondary = rateLimit?["secondary_window"] as? [String: Any] ?? rateLimit?["secondary"] as? [String: Any]
        return ParsedUsage(
            plan: plan,
            fiveHour: primary.map { parseWindow($0) },
            weekly: secondary.map { parseWindow($0) }
        )
    }

    private func parseWindow(_ dict: [String: Any]) -> UsageWindow {
        let usedPercent: Int?
        if let pct = dict["used_percent"] as? Double {
            usedPercent = Int(pct)
        } else if let pct = dict["utilization"] as? Double {
            usedPercent = Int(pct)
        } else {
            usedPercent = nil
        }
        let resetDate = parseResetDate(from: dict, keys: ["reset_at", "resets_at"])
        return UsageWindow(usedPercent: usedPercent, resetDate: resetDate)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseResetDate(from dict: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let ts = dict[key] as? Double {
                let seconds = ts > 1e12 ? ts / 1000.0 : ts
                return Date(timeIntervalSince1970: seconds)
            }
            if let ts = dict[key] as? Int {
                let seconds = Double(ts) > 1e12 ? Double(ts) / 1000.0 : Double(ts)
                return Date(timeIntervalSince1970: seconds)
            }
            if let str = dict[key] as? String {
                return Self.iso8601Formatter.date(from: str)
            }
        }
        return nil
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

    private func waitForOAuthCallback(port: UInt16, expectedState: String, codeVerifier: String) -> String? {
        // Start server first, then open browser
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))
        var tv = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

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

        let client = accept(sock, nil, nil)
        guard client >= 0 else { return nil }
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
        handleUsage()
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
          "  scope status                  Show switch scope\n" +
          "  scope cli on|off              Apply switch to CLI next run\n" +
          "  scope app on|off              Reflect switch in Codex App immediately\n" +
          "  scope launch on|off           Launch Codex App if closed during reflection\n" +
          "  rotation status               Show rotation state\n" +
          "  rotation on|off               Toggle rotation\n" +
          "  rotation threshold5h <10|20|30|40>      Set 5-hour switch threshold (remaining %)\n" +
          "  rotation thresholdWeekly <10|20|30|40>  Set weekly switch threshold (remaining %)\n" +
          "  rotation decide <a5> <aWk> <i5> <iWk>   Evaluate fallback (used %, '-' unknown)\n", stderr)
    exit(1)
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
            if s == "-" { return .some(nil) }          // known-unknown
            guard let v = Int(s), (0...100).contains(v) else { return nil }  // invalid
            return .some(v)
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
                let primary = rateLimit?["primary_window"] as? [String: Any] ?? rateLimit?["primary"] as? [String: Any]
                let secondary = rateLimit?["secondary_window"] as? [String: Any] ?? rateLimit?["secondary"] as? [String: Any]

                if !plan.isEmpty { parts.append("plan:\(plan)") }
                if let p = primary {
                    let pct = p["used_percent"] as? Double ?? p["utilization"] as? Double
                    if let pct { parts.append("5h:\(Int(pct))%") }
                }
                if let s = secondary {
                    let pct = s["used_percent"] as? Double ?? s["utilization"] as? Double
                    if let pct { parts.append("weekly:\(Int(pct))%") }
                }
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

    // 4. Update registry
    let email = decodeBase64Key(match.key) ?? match.key
    if let regError = cliUpdateRegistry(email) {
        fputs("Warning: registry update failed — \(regError)\n", stderr)
    }

    // 5. Reflect in Codex App if enabled
    if scope.reflectCodexApp {
        let result = cliRestartCodex(launchIfNotRunning: scope.launchCodexIfClosed)
        if result.status != 0 {
            fputs("Warning: Codex restart issue — \(result.output)\n", stderr)
        }
    }

    print("switched:\(match.email)")
    exit(0)
}

private func handleUsage() -> Never {
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
            let primary = rateLimit?["primary_window"] as? [String: Any] ?? rateLimit?["primary"] as? [String: Any]
            let secondary = rateLimit?["secondary_window"] as? [String: Any] ?? rateLimit?["secondary"] as? [String: Any]

            var parts = ["plan:\(plan)"]
            if let p = primary {
                let pct = p["used_percent"] as? Double ?? p["utilization"] as? Double
                if let pct { parts.append("5h:\(Int(pct))%") }
            }
            if let s = secondary {
                let pct = s["used_percent"] as? Double ?? s["utilization"] as? Double
                if let pct { parts.append("weekly:\(Int(pct))%") }
            }
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
