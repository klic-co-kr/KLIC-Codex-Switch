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

enum UsageDisplayMode: String {
    case fiveHour
    case weekly
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

// MARK: - Shared Helpers (used by both GUI and CLI)

private struct HTTPResult {
    let data: Data?
    let response: HTTPURLResponse?
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
    let home = NSHomeDirectory()
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
    let home = NSHomeDirectory()
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
    let home = NSHomeDirectory()
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

private func cliRestartCodex() -> CommandResult {
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
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let refreshInterval: TimeInterval = 5
    private let usageCacheInterval: TimeInterval = 60
    private let labelsDefaultsKey = "accountDisplayLabels"
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
    private var cachedUsage: ParsedUsage?
    private var lastUsageFetch: Date?
    private var rotationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "rotationEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "rotationEnabled") }
    }
    private var rotationThreshold: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "rotationThreshold")
            return val > 0 ? val : 80
        }
        set { UserDefaults.standard.set(newValue, forKey: "rotationThreshold") }
    }

    private var usageMode: UsageDisplayMode {
        get {
            UsageDisplayMode(rawValue: UserDefaults.standard.string(forKey: "usageDisplayMode") ?? "") ?? .weekly
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "usageDisplayMode")
        }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusButton()
        refreshAccounts()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAccounts()
        }
        RunLoop.current.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: UI Configuration

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.toolTip = NSLocalizedString("app_name", comment: "")
        button.image = loadCodexIcon()
        button.imagePosition = .imageLeft
    }

    private func loadCodexIcon() -> NSImage? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/icon.icns",
            "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
            "/Applications/Codex.app/Contents/Resources/codexTemplate.png"
        ]

        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let image = NSImage(contentsOfFile: path) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    // MARK: Data Refresh

    private func refreshAccounts() {
        guard !isSwitching, !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let (accountInfos, _) = self.readAccountFiles()

            var activeAccountKey: String?
            var allUsage: [String: ParsedUsage] = [:]

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
                    if let activeKey = accountInfos.first(where: { $0.isActive })?.key,
                       let activeUsage = allUsage[activeKey] {
                        self.cachedUsage = activeUsage
                    }
                }
            } else {
                let staleCache: ParsedUsage? = DispatchQueue.main.sync { self.cachedUsage }
                if let activeInfo = accountInfos.first(where: { $0.isActive }) {
                    activeAccountKey = activeInfo.key
                    if let stale = staleCache {
                        allUsage[activeInfo.key] = stale
                    }
                }
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
        guard rotationEnabled,
              accounts.count == 2,
              !isSwitching,
              let active = accounts.first(where: { $0.isActive }),
              let inactive = accounts.first(where: { !$0.isActive }),
              let activePct = active.fiveHourUsedPercent,
              let inactivePct = inactive.fiveHourUsedPercent,
              activePct >= rotationThreshold,
              inactivePct < rotationThreshold else { return }
        switchTo(key: inactive.key)
    }

    // MARK: Menu Building

    private func rebuildMenu() {
        let menu = NSMenu()

        if let active = accounts.first(where: { $0.isActive }) {
            if !isSwitching {
                statusItem.button?.title = statusTitle(for: active)
            }
            menu.addItem(headerItem(String(format: NSLocalizedString("active_account", comment: ""), active.email, displayPlan(active.plan))))
        } else {
            if !isSwitching {
                statusItem.button?.title = ""
            }
            menu.addItem(headerItem(lastError ?? NSLocalizedString("no_active_account", comment: "")))
        }

        menu.addItem(.separator())

        if let active = accounts.first(where: { $0.isActive }) {
            let usageHeader = headerItem(NSLocalizedString("usage_remaining", comment: ""))
            usageHeader.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: NSLocalizedString("usage_remaining", comment: ""))
            menu.addItem(usageHeader)
            menu.addItem(usageModeItem(
                title: NSLocalizedString("5hr", comment: ""),
                percent: remainingPercentText(fromUsed: active.fiveHourUsedPercent),
                reset: resetTimeText(from: active.fiveHourResetAt),
                mode: .fiveHour
            ))
            menu.addItem(usageModeItem(
                title: NSLocalizedString("weekly", comment: ""),
                percent: remainingPercentText(fromUsed: active.weeklyUsedPercent),
                reset: resetDateText(from: active.weeklyResetAt),
                mode: .weekly
            ))
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
            if rotationEnabled {
                rotItem.image = NSImage(systemSymbolName: "arrow.2.circlepath", accessibilityDescription: nil)
            }
            menu.addItem(rotItem)

            let threshStr = String(format: NSLocalizedString("threshold", comment: ""), "\(rotationThreshold)")
            let threshItem = NSMenuItem(title: threshStr, action: #selector(cycleThreshold), keyEquivalent: "")
            threshItem.target = self
            threshItem.isEnabled = rotationEnabled && !isSwitching
            menu.addItem(threshItem)

            menu.addItem(.separator())
        }

        if accounts.isEmpty {
            let item = NSMenuItem(title: lastError ?? NSLocalizedString("no_accounts", comment: ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            menu.addItem(headerItem(NSLocalizedString("accounts", comment: "")))
            for account in accounts {
                let item = NSMenuItem(title: "", action: #selector(switchAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.key
                item.attributedTitle = accountAttributedTitle(label: displayLabel(for: account), email: account.email)
                item.state = account.isActive ? .on : .off
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
        menu.addItem(toggle)

        menu.addItem(.separator())

        let addAccount = NSMenuItem(title: NSLocalizedString("add_account", comment: ""), action: #selector(addAccountBrowser), keyEquivalent: "")
        addAccount.target = self
        addAccount.isEnabled = !isSwitching
        menu.addItem(addAccount)

        let addDevice = NSMenuItem(title: NSLocalizedString("add_device_code", comment: ""), action: #selector(addAccountDeviceCode), keyEquivalent: "")
        addDevice.target = self
        addDevice.isEnabled = !isSwitching
        addDevice.toolTip = NSLocalizedString("device_code_tooltip", comment: "")
        menu.addItem(addDevice)

        if !accounts.isEmpty {
            let labelsItem = NSMenuItem(title: NSLocalizedString("display_labels", comment: ""), action: nil, keyEquivalent: "")
            let labelsMenu = NSMenu()
            for account in accounts {
                let item = NSMenuItem(title: String(format: NSLocalizedString("set_label", comment: ""), displayLabel(for: account), account.email), action: #selector(setAccountLabel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.email
                labelsMenu.addItem(item)
            }
            labelsItem.submenu = labelsMenu
            menu.addItem(labelsItem)

            let removeItem = NSMenuItem(title: NSLocalizedString("remove_account", comment: ""), action: nil, keyEquivalent: "")
            let removeMenu = NSMenu()
            for account in accounts {
                let item = NSMenuItem(title: "\(displayLabel(for: account))  \(account.email)", action: #selector(removeAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.key
                item.isEnabled = !isSwitching && account.key != "single"
                removeMenu.addItem(item)
            }
            removeItem.submenu = removeMenu
            menu.addItem(removeItem)
        }

        let refresh = NSMenuItem(title: NSLocalizedString("refresh", comment: ""), action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !isSwitching
        menu.addItem(refresh)

        let quit = NSMenuItem(title: NSLocalizedString("quit", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: Display Helpers

    private func statusTitle(for account: CodexAccount) -> String {
        let base: String
        switch usageMode {
        case .fiveHour:
            base = String(format: NSLocalizedString("status_5hr", comment: ""), displayLabel(for: account), remainingPercentText(fromUsed: account.fiveHourUsedPercent))
        case .weekly:
            base = String(format: NSLocalizedString("status_weekly", comment: ""), displayLabel(for: account), remainingPercentText(fromUsed: account.weeklyUsedPercent))
        }
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

    private func usageModeItem(title: String, percent: String, reset: String, mode: UsageDisplayMode) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(setUsageMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode.rawValue
        item.state = usageMode == mode ? .on : .off
        item.attributedTitle = usageAttributedTitle(title: title, percent: percent, reset: reset)
        return item
    }

    private func usageAttributedTitle(title: String, percent: String, reset: String) -> NSAttributedString {
        attributedColumns(
            "\(title)\t\(percent)\t\(reset)",
            tabs: [112, 162],
            font: NSFont.menuFont(ofSize: 0),
            color: .labelColor
        )
    }

    private func accountAttributedTitle(label: String, email: String) -> NSAttributedString {
        attributedColumns(
            "\(limitedLabel(label))\t\(email)",
            tabs: [86],
            font: NSFont.menuFont(ofSize: 0),
            color: .labelColor
        )
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

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Action Handlers

    @objc private func refreshNow() {
        lastUsageFetch = nil
        refreshAccounts()
    }

    @objc private func setUsageMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = UsageDisplayMode(rawValue: rawValue) else { return }
        usageMode = mode
        rebuildMenu()
    }

    @objc private func toggleRotation() {
        rotationEnabled = !rotationEnabled
        rebuildMenu()
    }

    @objc private func cycleThreshold() {
        let steps = [60, 70, 80, 90]
        let current = rotationThreshold
        guard let idx = steps.firstIndex(of: current) else { return }
        rotationThreshold = steps[(idx + 1) % steps.count]
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
        statusItem.button?.title = NSLocalizedString("removing_account", comment: "")
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            let home = NSHomeDirectory()
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

            let home = NSHomeDirectory()
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

            let restartResult = self.restartCodexApp()
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
        statusItem.button?.title = "\(switchingTitle) \(frame)"
    }

    private func endSwitchAnimation() {
        switchAnimationTimer?.invalidate()
        switchAnimationTimer = nil
    }

    // MARK: Account File Operations

    private func syncActiveAuthSnapshot() -> String? {
        let home = NSHomeDirectory()
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
        let home = NSHomeDirectory()
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
        let home = NSHomeDirectory()
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

        let home = NSHomeDirectory()
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
        statusItem.button?.title = NSLocalizedString("adding_account", comment: "")
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
            let _ = self.restartCodexApp()

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
        statusItem.button?.title = NSLocalizedString("adding_account", comment: "")
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
                self.statusItem.button?.title = "\(userCode)"
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
            let _ = self.restartCodexApp()

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

        let home = NSHomeDirectory()
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

    private func restartCodexApp() -> CommandResult { cliRestartCodex() }

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
          "  rotation status               Show rotation state\n" +
          "  rotation on|off               Toggle rotation\n" +
          "  rotation threshold <60|70|80|90>  Set threshold\n", stderr)
    exit(1)
}

private func handleRotation(_ args: ArraySlice<String>) -> Never {
    let defaults = UserDefaults.standard
    let subcommand = args.first

    switch subcommand {
    case "status":
        let enabled = defaults.bool(forKey: "rotationEnabled")
        let threshold = defaults.integer(forKey: "rotationThreshold")
        let thresh = threshold > 0 ? threshold : 80
        print("rotation:\(enabled ? "on" : "off") threshold:\(thresh)")
        exit(0)

    case "on":
        defaults.set(true, forKey: "rotationEnabled")
        print("rotation:on")
        exit(0)

    case "off":
        defaults.set(false, forKey: "rotationEnabled")
        print("rotation:off")
        exit(0)

    case "threshold":
        guard let valueStr = args.dropFirst().first,
              let value = Int(valueStr),
              [60, 70, 80, 90].contains(value) else {
            fputs("Error: threshold must be one of: 60, 70, 80, 90\n", stderr)
            exit(1)
        }
        defaults.set(value, forKey: "rotationThreshold")
        print("threshold:\(value)")
        exit(0)

    default:
        fputs("Usage: CodexAccountSwitcher rotation <status|on|off|threshold [60|70|80|90]>\n", stderr)
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

    let home = NSHomeDirectory()
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

    // 5. Restart Codex
    let result = cliRestartCodex()
    if result.status != 0 {
        fputs("Warning: Codex restart issue — \(result.output)\n", stderr)
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
