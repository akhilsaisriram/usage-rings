import Foundation

let feedDirectory = home.appendingPathComponent("Library/Application Support/Usage Rings", isDirectory: true)
let claudeFeedURL = feedDirectory.appendingPathComponent("claude-usage.json")

// Deliberately whitelist quota fields. Never persist the full status-line payload.
func sanitizedClaudeFeed(_ payload: Object, receivedAt: Date = Date()) -> Object? {
    guard let limits = payload["rate_limits"] as? Object else { return nil }
    var windows: Object = [:]
    for key in ["five_hour", "seven_day", "spend_limit"] {
        guard let value = limits[key] as? Object,
              let used = number(value["used_percentage"]), used.isFinite, (0...100).contains(used) else { continue }
        var window: Object = ["utilization": used]
        if let reset = number(value["resets_at"]), reset.isFinite, reset > 0 { window["resets_at"] = reset }
        windows[key] = window
    }
    guard !windows.isEmpty else { return nil }
    return ["receivedAt": receivedAt.timeIntervalSince1970, "windows": windows]
}

func collectClaudeFeed(input: Data = FileHandle.standardInput.readDataToEndOfFile(), at url: URL = claudeFeedURL) throws {
    guard input.count <= 1_048_576,
          let payload = try JSONSerialization.jsonObject(with: input) as? Object,
          let feed = sanitizedClaudeFeed(payload) else { return }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    let data = try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys])
    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    if let windows = feed["windows"] as? Object {
        print(claudeSnapshot(windows).menuText)
    }
}

func readClaudeFeed(at url: URL = claudeFeedURL) -> Provider {
    guard let data = try? Data(contentsOf: url), data.count <= 65_536,
          let feed = try? JSONSerialization.jsonObject(with: data) as? Object,
          let received = date(feed["receivedAt"]), received <= Date().addingTimeInterval(60),
          let windows = feed["windows"] as? Object else {
        return Provider(name: "Claude", error: "Waiting for Claude Code usage. Set up the local feed, then use Claude Code.")
    }
    var provider = claudeSnapshot(windows)
    provider.updated = received
    provider.details = ["Source: local Claude Code status line", "Browser-only usage may be newer. No Claude credentials are read."]
    if provider.isStale { provider.details.append("Last-known reading · use Claude Code to update. ~ marks stale menu values.") }
    return provider
}

func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// Explicit setup only. Refuse to replace a pre-existing unrelated status line.
func setupClaudeFeed(at settingsURL: URL = home.appendingPathComponent(".claude/settings.json"), directory: URL = feedDirectory) throws {
    let existed = FileManager.default.fileExists(atPath: settingsURL.path)
    let oldData = existed ? try Data(contentsOf: settingsURL) : Data("{}".utf8)
    guard var settings = try JSONSerialization.jsonObject(with: oldData) as? Object else {
        throw ReadError(message: "Claude settings are not a JSON object.")
    }
    let helper = directory.appendingPathComponent("UsageRingsFeed")
    let command = shellQuote(helper.path) + " --collect-claude"
    if let existing = settings["statusLine"], !(existing is NSNull),
       (existing as? Object)?["command"] as? String != command {
        throw ReadError(message: "An existing Claude status line is configured. It was left unchanged; see the README to integrate the feed.")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    let backup = directory.appendingPathComponent("claude-settings-before-feed.json")
    if !FileManager.default.fileExists(atPath: backup.path) {
        try oldData.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let staged = directory.appendingPathComponent("UsageRingsFeed-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: staged) }
    try FileManager.default.copyItem(at: executable, to: staged)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
    if FileManager.default.fileExists(atPath: helper.path) {
        _ = try FileManager.default.replaceItemAt(helper, withItemAt: staged)
    } else { try FileManager.default.moveItem(at: staged, to: helper) }
    settings["statusLine"] = ["type": "command", "command": command]
    // Detect a concurrent settings edit before replacing the file.
    let unchanged = existed ? try Data(contentsOf: settingsURL) == oldData : !FileManager.default.fileExists(atPath: settingsURL.path)
    guard unchanged else {
        throw ReadError(message: "Claude settings changed during setup. Retry; settings were not overwritten.")
    }
    let permissions = existed ? try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] : 0o600
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
    if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: settingsURL.path) }
}

func mergingCodexUpdate(_ update: Object, into previous: Object) -> Object {
    var result = previous.merging(update) { _, new in new }
    if let bucket = update["rateLimits"] as? Object {
        let key = bucket["limitId"] as? String ?? "codex"
        var buckets = result["rateLimitsByLimitId"] as? [String: Object] ?? [:]
        buckets[key] = bucket
        result["rateLimitsByLimitId"] = buckets
    }
    return result
}

// One owned local RPC connection. No timer polls the remote usage endpoint.
final class CodexConnection {
    var onUpdate: ((Provider) -> Void)?
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let operation = NSLock()
    private let condition = NSCondition()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var generation = UUID()
    private var buffer = Data()
    private var responses: [Int: Object] = [:]
    private var disconnected = true
    private var nextID = 10
    private var latest: Object = [:]

    init(executable: URL = home.appendingPathComponent(".local/bin/codex"), arguments: [String] = ["app-server"], timeout: TimeInterval = 25) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
    }
    var processIdentifier: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    deinit { close() }

    private func close() {
        process?.terminationHandler = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil
        condition.lock()
        generation = UUID(); disconnected = true; buffer = Data(); responses = [:]; latest = [:]
        condition.broadcast(); condition.unlock()
    }
    func stop() {
        condition.lock(); disconnected = true; condition.broadcast(); condition.unlock()
        operation.lock(); defer { operation.unlock() }; close()
    }

    private func receive(_ data: Data, generation id: UUID) {
        var snapshot: Provider?
        condition.lock()
        guard generation == id else { condition.unlock(); return }
        if data.isEmpty { disconnected = true; condition.broadcast(); condition.unlock(); return }
        buffer.append(data)
        if buffer.count > 4_194_304 { disconnected = true; condition.broadcast(); condition.unlock(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? Object else { continue }
            if let responseID = message["id"] as? Int {
                responses[responseID] = message
                if let result = message["result"] as? Object,
                   result["rateLimits"] != nil || result["rateLimitsByLimitId"] != nil { latest = result }
            }
            else if message["method"] as? String == "account/rateLimits/updated", let params = message["params"] as? Object {
                latest = mergingCodexUpdate(params, into: latest)
                snapshot = codexSnapshot(latest)
                snapshot?.details.append("Source: persistent Codex connection · other-app changes may need Refresh")
            }
        }
        condition.broadcast(); condition.unlock()
        if let snapshot { onUpdate?(snapshot) }
    }
    private func send(_ message: Object) throws {
        guard let input else { throw ReadError(message: "Codex connection closed. Click Refresh to reconnect.") }
        var bytes = try JSONSerialization.data(withJSONObject: message); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    private func response(_ id: Int) throws -> Object {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while responses[id] == nil {
            if disconnected { throw ReadError(message: "Codex connection closed. Click Refresh to reconnect.") }
            if !condition.wait(until: deadline) { throw ReadError(message: "Codex connection timed out. Click Refresh to reconnect.") }
        }
        let message = responses.removeValue(forKey: id)!
        guard message["error"] == nil else { throw ReadError(message: "Codex could not read limits. Check codex login, then Refresh.") }
        return message["result"] as? Object ?? [:]
    }
    private func connect() throws {
        close()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        self.process = process; self.input = input; self.output = output
        condition.lock(); let id = generation; disconnected = false; condition.unlock()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.receive(data, generation: id)
        }
        process.terminationHandler = { [weak self] _ in self?.receive(Data(), generation: id) }
        try process.run()
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "usage_rings", "title": "Usage Rings", "version": "1.1.0"]]])
        _ = try response(1)
        try send(["method": "initialized"])
    }
    func read() -> Provider {
        operation.lock(); defer { operation.unlock() }
        do {
            condition.lock(); let closed = disconnected; condition.unlock()
            if process?.isRunning != true || closed { try connect() }
            nextID += 1
            try send(["id": nextID, "method": "account/rateLimits/read"])
            _ = try response(nextID)
            condition.lock(); let result = latest; condition.unlock()
            var snapshot = codexSnapshot(result)
            snapshot.details.append("Source: persistent Codex connection · other-app changes may need Refresh")
            return snapshot
        } catch {
            close()
            return Provider(name: "Codex", error: (error as? ReadError)?.message ?? "Cannot start the local Codex connection.")
        }
    }
}
