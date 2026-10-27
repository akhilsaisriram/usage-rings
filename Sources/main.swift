import AppKit
import Foundation

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
    var isStale: Bool {
        guard let updated else { return false }
        return Date().timeIntervalSince(updated) > 600 || windows.contains { $0.reset.map { $0 <= Date() } ?? false }
    }
    var session: UsageWindow? { windows.first { $0.name == "Session · 5 hours" } }
    var weekly: UsageWindow? { windows.first { $0.name == "Weekly" || $0.name == "Weekly · all models" } }
    var menuText: String {
        let shortName = name == "Claude" ? "Cl" : "Cx"
        let limits = [session.map { percent($0.used) }, weekly.map { percent($0.used) }].compactMap { $0 }
        return shortName + " " + (limits.isEmpty ? "—" : limits.joined(separator: " / ")) + (isStale && !limits.isEmpty ? " ~" : "")
    }
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

func menuBarImage(_ providers: [Provider]) -> NSImage {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.labelColor
    ]
    let widths = providers.map { ceil($0.menuText.size(withAttributes: attributes).width) + 27 }
    let spacing: CGFloat = 12
    let width = widths.reduce(0, +) + spacing * CGFloat(max(0, providers.count - 1))
    return NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
        var x: CGFloat = 0
        for (index, provider) in providers.enumerated() {
            let color = provider.name == "Claude" ? claudeColor : codexColor
            if let session = provider.session {
                drawRing(in: NSRect(x: x, y: 1, width: 20, height: 20), used: session.used, color: color, width: 2)
            }
            if let weekly = provider.weekly {
                drawRing(in: NSRect(x: x + 4.5, y: 5.5, width: 11, height: 11), used: weekly.used, color: color, width: 2)
            }
            provider.menuText.draw(at: NSPoint(x: x + 26, y: 4), withAttributes: attributes)
            x += widths[index] + spacing
        }
        return true
    }
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
    let codex = CodexConnection()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: 154)
        status.button?.target = self; status.button?.action = #selector(toggle)
        status.button?.setAccessibilityLabel("Claude and Codex subscription usage")
        content = NSViewController(); popover.contentViewController = content
        popover.behavior = .transient; popover.animates = true
        codex.onUpdate = { [weak self] provider in
            DispatchQueue.main.async { self?.providers[1] = provider; self?.render() }
        }
        render(); refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.providers[0] = readClaudeFeed(); self.render()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggle() }
        return false
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); codex.stop() }
    @objc func woke() { refresh() }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            render(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc func refreshAction() { refresh() }
    @objc func connectClaude() {
        do { try setupClaudeFeed(); providers[0] = readClaudeFeed() }
        catch { providers[0] = Provider(name: "Claude", error: (error as? ReadError)?.message ?? "Could not set up the Claude feed.") }
        render()
    }
    func refresh() {
        providers[0] = readClaudeFeed()
        guard !loading else { render(); return }
        loading = true; render()
        DispatchQueue.global(qos: .utility).async {
            let result = self.codex.read()
            DispatchQueue.main.async {
                self.providers[1] = result; self.loading = false; self.render()
            }
        }
    }
    @objc func claudeWeb() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc func codexWeb() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    func render() {
        let image = menuBarImage(providers)
        status.length = image.size.width + 4
        status.button?.image = image
        status.button?.toolTip = providers.map { p in
            let session = p.session.map { "\(percent($0.used)) used" } ?? "unavailable"
            let weekly = p.weekly.map { "\(percent($0.used)) used" } ?? "unavailable"
            return "\(p.name): outer ring = session \(session); inner ring = weekly \(weekly)\(p.isStale ? "; last-known reading, refresh source" : "")"
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
                rows.append(label("\(p.isStale ? "Last known" : "Received") \(f.string(from: updated))\(p.isStale ? " · stale" : "")", size: 10, secondary: true))
            }
            if index == 0 && p.error != nil { rows.append(button("Set up Claude feed…", #selector(connectClaude))) }
            let section = stack(rows, spacing: 9)
            section.widthAnchor.constraint(equalToConstant: 360).isActive = true
            sections.append(NSBox.separator())
            sections.append(section)
        }
        sections.append(NSBox.separator())
        let refreshButton = button(loading ? "Refreshing…" : "Refresh", #selector(refreshAction))
        refreshButton.isEnabled = !loading
        sections.append(stack([refreshButton, button("Claude ↗", #selector(claudeWeb)), button("Codex ↗", #selector(codexWeb)), button("Quit", #selector(quit))], vertical: false, spacing: 6))
        sections.append(label("Local Claude feed + Codex events · ~ means stale", size: 10, secondary: true))
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
    let codex = codexSnapshot(["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 10080, "resetsAt": 1793602977], "secondary": NSNull()]])
    precondition(codex.windows.count == 1 && codex.primary?.name == "Weekly" && codex.primary?.remaining == 75)
    precondition(codex.session == nil && codex.weekly?.used == 25 && codex.menuText == "Cx 25%")
    let multi = codexSnapshot(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 10, "windowDurationMins": 300], "secondary": ["usedPercent": 40, "windowDurationMins": 10080]], "other": ["primary": ["usedPercent": 60, "windowDurationMins": 60]]]])
    precondition(multi.windows.count == 3 && multi.primary?.name == "Session · 5 hours")
    let claude = claudeSnapshot(["five_hour": ["utilization": 23.5, "resets_at": "2026-10-27T19:00:00Z"], "seven_day": ["utilization": 41.2], "seven_day_opus": ["utilization": 0], "seven_day_sonnet": NSNull()])
    precondition(claude.windows.count == 3 && claude.primary?.reset != nil && claude.windows.last?.used == 0)
    precondition(claude.session?.used == 23.5 && claude.weekly?.used == 41.2 && claude.menuText == "Cl 24% / 41%")
    precondition(Provider(name: "Claude").menuText == "Cl —")
    precondition(claudeSnapshot([:]).error != nil && codexSnapshot([:]).error != nil)
    precondition(UsageWindow(name: "test", used: 105, reset: nil).remaining == 0)
    print("Passed: passive usage sources, weekly-only Codex, multi-bucket limits, Claude models, null/missing data, reset dates, remaining usage.")
} else if CommandLine.arguments.contains("--collect-claude") {
    do { try collectClaudeFeed() } catch { exit(1) }
} else if CommandLine.arguments.contains("--setup-claude-feed") {
    do { try setupClaudeFeed(); print("Claude local feed configured. Use Claude Code to supply usage.") }
    catch { print((error as? ReadError)?.message ?? "Claude feed setup failed."); exit(1) }
} else if CommandLine.arguments.contains("--diagnose") {
    let connection = CodexConnection()
    let results = [diagnose(readClaudeFeed()), diagnose(connection.read())]
    connection.stop()
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), let s = String(data: data, encoding: .utf8) { print(s) }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
