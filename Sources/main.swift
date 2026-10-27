import AppKit
import Foundation
import Security
import LocalAuthentication

typealias Object = [String: Any]
let home = FileManager.default.homeDirectoryForCurrentUser

struct UsageWindow {
    let name: String
    let used: Double
    let reset: Date?
    var remaining: Double { max(0, 100 - used) }
}

struct Provider {
    let name: String
    var windows: [UsageWindow] = []
    var details: [String] = []
    var error: String?
    var updated: Date?
    var primary: UsageWindow? { windows.first }
}

struct ReadError: Error { let message: String }
func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
func date(_ value: Any?) -> Date? {
    if let n = number(value) { return Date(timeIntervalSince1970: n) }
    guard let s = value as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}
func windowName(_ mins: Double?) -> String {
    guard let mins else { return "Current limit" }
    if mins == 10080 { return "Weekly" }
    if mins == 300 { return "Session · 5 hours" }
    if mins >= 1440 { return "\(Int(mins / 1440))-day limit" }
    if mins >= 60 { return "\(Int(mins / 60))-hour limit" }
    return "\(Int(mins))-minute limit"
}
func codexSnapshot(_ result: Object) -> Provider {
    var out = Provider(name: "Codex")
    let fallback = result["rateLimits"] as? Object
    let buckets = result["rateLimitsByLimitId"] as? [String: Object]
        ?? fallback.map { ["codex": $0] } ?? [:]
    for key in buckets.keys.sorted(by: { a, b in a == "codex" ? b != "codex" : b == "codex" ? false : a < b }) {
        guard let bucket = buckets[key] else { continue }
        let prefix = key == "codex" ? "" : "\(bucket["limitName"] as? String ?? key) · "
        for field in ["primary", "secondary", "individualLimit"] {
            guard let w = bucket[field] as? Object, let used = number(w["usedPercent"]) else { continue }
            out.windows.append(UsageWindow(name: prefix + windowName(number(w["windowDurationMins"])), used: used, reset: date(w["resetsAt"])))
        }
        if let plan = bucket["planType"] as? String, key == "codex" { out.details.append("Plan: \(plan.capitalized)") }
        if let credits = bucket["credits"] as? Object {
            if credits["unlimited"] as? Bool == true { out.details.append("\(key.capitalized) credits: unlimited") }
            else if let balance = credits["balance"] as? String { out.details.append("\(key.capitalized) credit balance: \(balance)") }
        }
    }
    if let reset = result["rateLimitResetCredits"] as? Object, let count = reset["availableCount"] as? Int {
        out.details.append("Available full resets: \(count)")
    }
    if out.windows.isEmpty { out.error = "No quota windows returned by Codex." }
    else { out.updated = Date() }
    return out
}

// A dedicated read-only RPC process; never starts a thread or sends a model prompt.
func readCodex() -> Provider {
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = home.appendingPathComponent(".local/bin/codex")
    process.arguments = ["app-server"]
    process.standardInput = input; process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let condition = NSCondition()
    var buffer = Data(), responses: [Int: Object] = [:]
    output.fileHandleForReading.readabilityHandler = { handle in
        let bytes = handle.availableData
        condition.lock(); defer { condition.unlock() }
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? Object,
               let id = object["id"] as? Int { responses[id] = object }
        }
        condition.broadcast()
    }
    defer {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    func send(_ request: Object) throws {
        var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func response(_ id: Int) throws -> Object {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(25)
        while responses[id] == nil {
            if !condition.wait(until: deadline) { throw ReadError(message: "Codex connection timed out. Try Refresh.") }
        }
        let reply = responses.removeValue(forKey: id)!
        if reply["error"] != nil { throw ReadError(message: "Codex could not read subscription limits. Run codex login in Terminal.") }
        return reply["result"] as? Object ?? [:]
    }
    do {
        try process.run()
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "usage_rings", "title": "Usage Rings", "version": "1.0.1"]]])
        _ = try response(1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        return codexSnapshot(try response(2))
    } catch {
        return Provider(name: "Codex", error: (error as? ReadError)?.message ?? "Cannot launch Codex at ~/.local/bin/codex.")
    }
}

func claudeSnapshot(_ result: Object) -> Provider {
    var out = Provider(name: "Claude")
    let labels = ["five_hour": "Session · 5 hours", "seven_day": "Weekly · all models", "seven_day_sonnet": "Weekly · Sonnet", "seven_day_opus": "Weekly · Opus", "seven_day_oauth_apps": "Weekly · OAuth apps"]
    let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps"]
    let keys = order + result.keys.filter { !order.contains($0) && $0 != "extra_usage" }.sorted()
    for key in keys {
        guard let w = result[key] as? Object, let used = number(w["utilization"]) else { continue }
        out.windows.append(UsageWindow(name: labels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized, used: used, reset: date(w["resets_at"])))
    }
    if let extra = result["extra_usage"] as? Object, extra["is_enabled"] as? Bool == true {
        if let used = number(extra["utilization"]) { out.windows.append(UsageWindow(name: "Extra usage", used: used, reset: date(extra["resets_at"]))) }
        if let spent = number(extra["used_credits"]), let limit = number(extra["monthly_limit"]) {
            out.details.append(String(format: "Extra usage: %.2f / %.2f credits", spent, limit))
        }
    }
    if out.windows.isEmpty { out.error = "Claude returned no quota windows." }
    else { out.updated = Date() }
    return out
}

func usageSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    return configuration
}

func readClaude(interactive: Bool) -> Provider {
    var credentials: Data?
    let file = home.appendingPathComponent(".claude/.credentials.json")
    credentials = try? Data(contentsOf: file)
    if credentials == nil {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        let authentication = LAContext()
        authentication.interactionNotAllowed = !interactive
        query[kSecUseAuthenticationContext as String] = authentication
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess { credentials = item as? Data }
        else {
            let reason = status == errSecInteractionNotAllowed || status == errSecAuthFailed
                ? "Click Connect Claude to allow access to the existing Claude Code login."
                : "Claude login unavailable. Run claude auth login in Terminal, then Connect Claude."
            return Provider(name: "Claude", error: reason)
        }
    }
    guard let data = credentials,
          let json = try? JSONSerialization.jsonObject(with: data) as? Object,
          let oauth = json["claudeAiOauth"] as? Object,
          let token = oauth["accessToken"] as? String, !token.isEmpty else {
        return Provider(name: "Claude", error: "No Claude subscription login found. Run claude auth login in Terminal.")
    }
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let semaphore = DispatchSemaphore(value: 0)
    var payload: Data?, statusCode: Int?, failed = false
    let session = URLSession(configuration: usageSessionConfiguration())
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request) { data, response, error in
        payload = data; statusCode = (response as? HTTPURLResponse)?.statusCode
        failed = error != nil; semaphore.signal()
    }
    task.resume()
    guard semaphore.wait(timeout: .now() + 23) == .success else {
        task.cancel(); return Provider(name: "Claude", error: "Claude request timed out. Try Refresh.")
    }
    guard !failed, statusCode == 200, let payload,
          let result = try? JSONSerialization.jsonObject(with: payload) as? Object else {
        let message: String
        switch statusCode {
        case 401, 403: message = "Claude login expired or lacks usage access. Run claude auth login in Terminal."
        case 429: message = "Claude usage is rate limited. Automatic refresh will retry in five minutes."
        default: message = "Cannot reach Claude usage\(statusCode.map { " (HTTP \($0))" } ?? ""). Try Refresh."
        }
        return Provider(name: "Claude", error: message)
    }
    return claudeSnapshot(result)
}

let claudeColor = NSColor(calibratedRed: 0.80, green: 0.46, blue: 0.32, alpha: 1)
let codexColor = NSColor(calibratedRed: 0.23, green: 0.68, blue: 0.52, alpha: 1)
func usageColor(_ used: Double, _ base: NSColor) -> NSColor {
    used >= 95 ? .systemRed : used >= 80 ? .systemOrange : base
}
func drawRing(in rect: NSRect, used: Double?, color: NSColor, width: CGFloat) {
    let oval = rect.insetBy(dx: width / 2, dy: width / 2)
    NSColor.labelColor.withAlphaComponent(0.15).setStroke()
    let track = NSBezierPath(ovalIn: oval); track.lineWidth = width; track.stroke()
    guard let used else { return }
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: oval.width / 2,
                  startAngle: 90, endAngle: 90 - CGFloat(min(100, max(0, used))) * 3.6, clockwise: true)
    usageColor(used, color).setStroke(); arc.lineWidth = width; arc.lineCapStyle = .round
    if used > 0 { arc.stroke() }
}

final class RingView: NSView {
    var used: Double?
    let color: NSColor
    init(used: Double?, color: NSColor) { self.used = used; self.color = color; super.init(frame: NSRect(x: 0, y: 0, width: 52, height: 52)) }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 52, height: 52) }
    override func draw(_ dirtyRect: NSRect) {
        drawRing(in: bounds.insetBy(dx: 3, dy: 3), used: used, color: color, width: 4)
        let text = used.map(percent) ?? "—"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = NSFont.systemFont(ofSize: size, weight: weight)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    return field
}
func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = vertical ? .vertical : .horizontal
    view.alignment = vertical ? .leading : .centerY
    view.spacing = spacing
    return view
}
func resetText(_ date: Date?) -> String {
    guard let date else { return "Reset time unavailable" }
    let formatter = DateFormatter(); formatter.dateFormat = "EEE d MMM, h:mm a"
    let seconds = date.timeIntervalSinceNow
    if seconds <= 0 { return "Reset due · refresh to check" }
    let hours = Int(seconds / 3600), mins = Int(seconds / 60) % 60
    let remaining = hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h \(mins)m"
    return "Resets in \(remaining) · \(formatter.string(from: date))"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    let popover = NSPopover()
    var providers = [Provider(name: "Claude"), Provider(name: "Codex")]
    var timer: Timer?
    var loading = false
    var content: NSViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: 154)
        status.button?.target = self; status.button?.action = #selector(toggle)
        status.button?.setAccessibilityLabel("Claude and Codex subscription usage")
        content = NSViewController(); popover.contentViewController = content
        popover.behavior = .transient; popover.animates = true
        render(); refresh(interactive: false)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh(interactive: false) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggle() }
        return false
    }
    @objc func woke() { refresh(interactive: false) }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            render(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc func refreshAction() { refresh(interactive: false) }
    @objc func connectClaude() { refresh(interactive: true) }
    func refresh(interactive: Bool) {
        guard !loading else { return }; loading = true; render()
        // Independent reads finish separately so a provider timeout does not hide the other.
        let group = DispatchGroup()
        for index in 0...1 {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result = index == 0 ? readClaude(interactive: interactive) : readCodex()
                DispatchQueue.main.async {
                    self.providers[index] = result; self.render(); group.leave()
                }
            }
        }
        group.notify(queue: .main) { self.loading = false; self.render() }
    }
    @objc func claudeWeb() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc func codexWeb() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    func render() {
        let image = NSImage(size: NSSize(width: 150, height: 22), flipped: false) { rect in
            for i in 0...1 {
                let p = self.providers[i], x = CGFloat(i * 77)
                let color = i == 0 ? claudeColor : codexColor
                drawRing(in: NSRect(x: x + 1, y: 3, width: 16, height: 16), used: p.primary?.used, color: color, width: 2.3)
                let text = "\(i == 0 ? "Cl" : "Cx") \(p.primary.map { percent($0.used) } ?? "—")"
                text.draw(at: NSPoint(x: x + 21, y: 4), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
            }; return true
        }
        status.button?.image = image
        status.button?.toolTip = providers.map { p in
            "\(p.name): \(p.primary.map { "\($0.name), \(percent($0.used)) used" } ?? "unavailable")"
        }.joined(separator: "\n")

        var sections: [NSView] = [label("Usage Rings", size: 20, weight: .bold), label("Subscription limits · circles show % used", secondary: true)]
        for (index, p) in providers.enumerated() {
            let color = index == 0 ? claudeColor : codexColor
            var rows: [NSView] = [label(p.name, size: 16, weight: .semibold)]
            if let error = p.error { rows.append(label(error, secondary: true)) }
            for w in p.windows {
                let text = stack([label(w.name, size: 13, weight: .medium),
                    label("\(percent(w.used)) used · \(percent(w.remaining)) remaining", size: 12),
                    label(resetText(w.reset), size: 11, secondary: true)], spacing: 3)
                rows.append(stack([RingView(used: w.used, color: color), text], vertical: false, spacing: 12))
            }
            for detail in p.details { rows.append(label(detail, size: 11, secondary: true)) }
            if let updated = p.updated {
                let f = DateFormatter(); f.timeStyle = .short
                rows.append(label("Updated \(f.string(from: updated))", size: 10, secondary: true))
            }
            if index == 0 && p.error != nil { rows.append(button("Connect Claude…", #selector(connectClaude))) }
            let section = stack(rows, spacing: 9)
            section.widthAnchor.constraint(equalToConstant: 360).isActive = true
            sections.append(NSBox.separator())
            sections.append(section)
        }
        sections.append(NSBox.separator())
        let refreshButton = button(loading ? "Refreshing…" : "Refresh", #selector(refreshAction))
        refreshButton.isEnabled = !loading
        sections.append(stack([refreshButton, button("Claude ↗", #selector(claudeWeb)), button("Codex ↗", #selector(codexWeb)), button("Quit", #selector(quit))], vertical: false, spacing: 6))
        sections.append(label("Refreshes every 5 minutes · unavailable ≠ zero", size: 10, secondary: true))
        let column = stack(sections, spacing: 12)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 540))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let document = NSView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor), column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor), column.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        content.view = scroll
        let height = min(680, max(400, column.fittingSize.height))
        popover.contentSize = NSSize(width: 400, height: height)
    }
}
extension NSBox {
    static func separator() -> NSBox { let b = NSBox(); b.boxType = .separator; b.widthAnchor.constraint(equalToConstant: 360).isActive = true; return b }
}

func diagnose(_ provider: Provider) -> Object {
    ["provider": provider.name, "error": provider.error as Any? ?? NSNull(),
     "windows": provider.windows.map { ["name": $0.name, "used": $0.used, "remaining": $0.remaining, "reset": $0.reset?.timeIntervalSince1970 as Any? ?? NSNull()] },
     "details": provider.details]
}
if CommandLine.arguments.contains("--self-test") {
    let configuration = usageSessionConfiguration()
    precondition(configuration.urlCache == nil)
    precondition(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    precondition(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
    precondition(configuration.urlCredentialStorage == nil)
    let codex = codexSnapshot(["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 10080, "resetsAt": 1793602977], "secondary": NSNull()]])
    precondition(codex.windows.count == 1 && codex.primary?.name == "Weekly" && codex.primary?.remaining == 75)
    let multi = codexSnapshot(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 10, "windowDurationMins": 300], "secondary": ["usedPercent": 40, "windowDurationMins": 10080]], "other": ["primary": ["usedPercent": 60, "windowDurationMins": 60]]]])
    precondition(multi.windows.count == 3 && multi.primary?.name == "Session · 5 hours")
    let claude = claudeSnapshot(["five_hour": ["utilization": 23.5, "resets_at": "2026-10-27T19:00:00Z"], "seven_day": ["utilization": 41.2], "seven_day_opus": ["utilization": 0], "seven_day_sonnet": NSNull()])
    precondition(claude.windows.count == 3 && claude.primary?.reset != nil && claude.windows.last?.used == 0)
    precondition(claudeSnapshot([:]).error != nil && codexSnapshot([:]).error != nil)
    precondition(UsageWindow(name: "test", used: 105, reset: nil).remaining == 0)
    print("Passed: network privacy settings, weekly-only Codex, multi-bucket limits, Claude models, null/missing data, reset dates, remaining usage.")
} else if CommandLine.arguments.contains("--diagnose") {
    let results = [diagnose(readClaude(interactive: CommandLine.arguments.contains("--connect-claude"))), diagnose(readCodex())]
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), let s = String(data: data, encoding: .utf8) { print(s) }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
