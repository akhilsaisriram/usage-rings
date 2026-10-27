"""Integration checks against a local fake CLI; no account credentials required."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Sources/main.swift").read_text().split('if CommandLine.arguments.contains("--self-test")')[0]
fixture = str(root / "Tests/codex_server.py")

checks = r'''
let payload: Object = ["accessToken": "NEVER_SAVE", "transcript_path": "/private/chat",
    "rate_limits": ["five_hour": ["used_percentage": 39, "resets_at": 1793113800, "secret": "NEVER_SAVE"],
                    "seven_day": ["used_percentage": 82], "unknown": ["used_percentage": 15]]]
let feed = sanitizedClaudeFeed(payload)!
let encoded = try JSONSerialization.data(withJSONObject: feed)
let text = String(data: encoded, encoding: .utf8)!
precondition(!text.contains("NEVER_SAVE") && !text.contains("transcript") && !text.contains("unknown"))
precondition((feed["windows"] as! Object).count == 2)
precondition(sanitizedClaudeFeed([:]) == nil)
precondition(sanitizedClaudeFeed(["rate_limits": ["five_hour": ["used_percentage": -1]]]) == nil)
precondition(sanitizedClaudeFeed(["rate_limits": ["five_hour": ["used_percentage": Double.infinity]]]) == nil)
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
let cache = directory.appendingPathComponent("feed.json")
try collectClaudeFeed(input: JSONSerialization.data(withJSONObject: payload), at: cache)
let saved = try Data(contentsOf: cache)
precondition(!String(data: saved, encoding: .utf8)!.contains("NEVER_SAVE"))
let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as! NSNumber
precondition(permissions.intValue == 0o600)
try collectClaudeFeed(input: Data("{}".utf8), at: cache)
let unchanged = try Data(contentsOf: cache)
precondition(unchanged == saved)
let stale = sanitizedClaudeFeed(payload, receivedAt: Date().addingTimeInterval(-900))!
try JSONSerialization.data(withJSONObject: stale).write(to: cache)
let lastKnown = readClaudeFeed(at: cache)
precondition(lastKnown.isStale && lastKnown.menuText.hasSuffix(" ~"))
try Data("not json".utf8).write(to: cache)
precondition(readClaudeFeed(at: cache).error != nil)
let sessionOnly = claudeSnapshot(["five_hour": ["utilization": 10]])
precondition(sessionOnly.menuText == "Cl 10%" && sessionOnly.weekly == nil)
let reset = Date().addingTimeInterval(3600).timeIntervalSince1970
func sample(_ used: Double, reset: Double) -> Object {
    return sanitizedClaudeFeed(["rate_limits": ["five_hour": ["used_percentage": used, "resets_at": reset]]])!
}
let high = sample(45, reset: reset)
let lower = sample(43, reset: reset)
let retained = preservingClaudeHighs(lower, previous: high)
precondition(((retained["windows"] as! Object)["five_hour"] as! Object)["utilization"] as? Double == 45)
let nextWindow = sample(0, reset: reset + 18000)
let afterReset = preservingClaudeHighs(nextWindow, previous: high)
precondition(((afterReset["windows"] as! Object)["five_hour"] as! Object)["utilization"] as? Double == 0)
let lateOldReading = preservingClaudeHighs(high, previous: nextWindow)
precondition(((lateOldReading["windows"] as! Object)["five_hour"] as! Object)["utilization"] as? Double == 0)
let writers = DispatchGroup()
for used in [45.0, 43.0, 48.0, 44.0, 46.0] {
    writers.enter()
    DispatchQueue.global().async {
        let payload: Object = ["rate_limits": ["five_hour": ["used_percentage": used, "resets_at": reset]]]
        try! collectClaudeFeed(input: JSONSerialization.data(withJSONObject: payload), at: cache)
        writers.leave()
    }
}
writers.wait()
precondition(readClaudeFeed(at: cache).session?.used == 48)
let settings = directory.appendingPathComponent("claude/settings.json")
let support = directory.appendingPathComponent("support")
try setupClaudeFeed(at: settings, directory: support)
var configured = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! Object
precondition((configured["statusLine"] as? Object)?["refreshInterval"] as? Int == 300)
precondition((configured["statusLine"] as? Object)?["command"] as? String == shellQuote(support.appendingPathComponent("UsageRingsFeed").path) + " --collect-claude")
configured["unrelated"] = "preserve"
var statusOptions = configured["statusLine"] as! Object
statusOptions["padding"] = 2
configured["statusLine"] = statusOptions
try JSONSerialization.data(withJSONObject: configured).write(to: settings)
try setupClaudeFeed(at: settings, directory: support)
let preserved = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! Object
precondition(preserved["unrelated"] as? String == "preserve")
precondition((preserved["statusLine"] as? Object)?["padding"] as? Int == 2)
precondition((preserved["statusLine"] as? Object)?["refreshInterval"] as? Int == 300)
precondition(FileManager.default.fileExists(atPath: support.appendingPathComponent("claude-settings-before-feed.json").path))
configured["statusLine"] = ["type": "command", "command": "existing-status-line"]
let originalSettings = try JSONSerialization.data(withJSONObject: configured)
try originalSettings.write(to: settings)
var refused = false
do { try setupClaudeFeed(at: settings, directory: support) } catch { refused = true }
let afterRefusal = try Data(contentsOf: settings)
precondition(refused && afterRefusal == originalSettings)

let fixture = CommandLine.arguments[1]
let connection = CodexConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture], timeout: 2)
let notification = DispatchSemaphore(value: 0)
connection.onUpdate = { provider in
    precondition(provider.weekly?.used == 75)
    precondition(provider.details.contains("Available full resets: 2"))
    notification.signal()
}
precondition(connection.read().weekly?.used == 25)
let pid = connection.processIdentifier
precondition(pid != nil && connection.read().weekly?.used == 30)
precondition(connection.processIdentifier == pid)
precondition(notification.wait(timeout: .now() + 3) == .success)
let start = Date()
precondition(connection.read().error != nil && Date().timeIntervalSince(start) < 1.5)
precondition(connection.read().weekly?.used == 25 && connection.processIdentifier != pid)
connection.stop()
precondition(connection.processIdentifier == nil)
let hanging = CodexConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture, "--hang"], timeout: 0.3)
precondition(hanging.read().error?.contains("timed out") == true)
hanging.stop()
print("Passed: same-window highest values, reset handling, delayed old windows, concurrent writers, quota-only whitelist, private writes, stale feeds, safe settings setup, persistent PID reuse, notifications, EOF recovery, timeout, shutdown.")
'''

with tempfile.TemporaryDirectory(prefix="usage-rings-tests-") as directory:
    directory = Path(directory)
    (directory / "main.swift").write_text(source + checks)
    binary = directory / "checks"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-O", "-framework", "AppKit",
        str(directory / "main.swift"), str(root / "Sources/UsageSources.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), fixture, str(directory)], check=True, timeout=15)
