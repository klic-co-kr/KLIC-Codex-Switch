import AppKit
import Foundation

private let appName = "Codex Account Switcher"
private let executableName = "CodexAccountSwitcher"
private let launchAgentLabel = "local.codex-account-switcher.menu-bar"

private struct CommandResult {
    let status: Int32
    let output: String
}

private func run(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    } catch {
        return CommandResult(status: 127, output: error.localizedDescription)
    }
}

private final class InstallerDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        promptAndInstall()
    }

    private func promptAndInstall() {
        let alert = NSAlert()
        alert.messageText = "\(appName) 설치"
        alert.informativeText = "앱을 ~/Applications에 설치하고 로그인 시 자동 실행되도록 등록합니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "설치")
        alert.addButton(withTitle: "취소")

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }

        do {
            try install()
            showResult(title: "설치 완료", message: "\(appName)이 설치되고 실행되었습니다.")
        } catch {
            showResult(title: "설치 실패", message: error.localizedDescription)
        }
        NSApp.terminate(nil)
    }

    private func install() throws {
        guard let sourceApp = Bundle.main.url(forResource: appName, withExtension: "app") else {
            throw NSError(domain: "Installer", code: 1, userInfo: [NSLocalizedDescriptionKey: "설치할 앱 번들을 찾을 수 없습니다."])
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let destinationDir = home.appendingPathComponent("Applications", isDirectory: true)
        let destinationApp = destinationDir.appendingPathComponent("\(appName).app", isDirectory: true)
        let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logsDir = home.appendingPathComponent("Library/Logs", isDirectory: true)
        let launchAgentURL = launchAgentsDir.appendingPathComponent("\(launchAgentLabel).plist")
        let executableURL = destinationApp.appendingPathComponent("Contents/MacOS/\(executableName)")
        let domain = "gui/\(getuid())"

        _ = run("/bin/launchctl", ["bootout", domain, launchAgentURL.path])
        _ = run("/usr/bin/pkill", ["-x", executableName])

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destinationApp.path) {
            try FileManager.default.removeItem(at: destinationApp)
        }
        try FileManager.default.copyItem(at: sourceApp, to: destinationApp)

        try launchAgentPlist(executableURL: executableURL, logsDir: logsDir).write(to: launchAgentURL, atomically: true, encoding: .utf8)

        let bootstrap = run("/bin/launchctl", ["bootstrap", domain, launchAgentURL.path])
        if bootstrap.status != 0 {
            throw NSError(domain: "Installer", code: 2, userInfo: [NSLocalizedDescriptionKey: bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        _ = run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(launchAgentLabel)"])
    }

    private func launchAgentPlist(executableURL: URL, logsDir: URL) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(launchAgentLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(executableURL.path)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <dict>
            <key>SuccessfulExit</key>
            <false/>
          </dict>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>StandardOutPath</key>
          <string>\(logsDir.appendingPathComponent("CodexAccountSwitcher.log").path)</string>
          <key>StandardErrorPath</key>
          <string>\(logsDir.appendingPathComponent("CodexAccountSwitcher.error.log").path)</string>
        </dict>
        </plist>
        """
    }

    private func showResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title.contains("실패") ? .warning : .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

let app = NSApplication.shared
private let delegate = InstallerDelegate()
app.delegate = delegate
app.run()
