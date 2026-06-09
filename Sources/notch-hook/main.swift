import Foundation

// notch-hook
// Updates a per-session status file that NotchAIControl.app watches.
//
// Two modes:
//   • Claude Code  — JSON hook payload on STDIN (configured in ~/.claude/settings.json).
//                    Optional argv[1] overrides the event name.
//   • OpenAI Codex — `notch-hook codex '<json>'`, where the JSON is Codex's
//                    `notify` event (configured in ~/.codex/config.toml).
//
// It never blocks the agent: any error exits 0 silently.

// MARK: - Paths

let home = FileManager.default.homeDirectoryForCurrentUser
let baseDir = home.appendingPathComponent(".notch-ai-control", isDirectory: true)
let sessionsDir = baseDir.appendingPathComponent("sessions", isDirectory: true)

func ensureDirs() {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
}

func bail() -> Never { exit(0) }

func truncate(_ s: String, _ n: Int) -> String {
    if s.count <= n { return s }
    return String(s[..<s.index(s.startIndex, offsetBy: n)]) + "…"
}

// MARK: - Shared write

/// Merge `fields` into a session file, preserving started_at and the once-detected
/// owning app. Writes atomically so the watcher never sees a partial file.
func upsert(sessionID: String, _ fields: [String: Any]) {
    ensureDirs()
    let file = sessionsDir.appendingPathComponent(sessionID + ".json")

    var record: [String: Any] = [:]
    if let existing = try? Data(contentsOf: file),
       let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
        record = obj
    }

    let now = Date().timeIntervalSince1970
    if record["started_at"] == nil { record["started_at"] = now }

    // Detect the owning app once, then remember it.
    if record["owner_bundle_id"] == nil, let owner = detectOwner() {
        record["owner_bundle_id"] = owner.bundleID
        record["owner_app_path"] = owner.appPath
        record["owner_name"] = owner.name
        record["owner_kind"] = owner.kind
    }

    for (k, v) in fields { record[k] = v }
    record["session_id"] = sessionID
    record["updated_at"] = now

    guard let out = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    else { return }
    let tmp = file.appendingPathExtension("tmp")
    try? out.write(to: tmp, options: .atomic)
    try? FileManager.default.removeItem(at: file)
    try? FileManager.default.moveItem(at: tmp, to: file)
}

func removeSession(_ sessionID: String) {
    try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent(sessionID + ".json"))
}

let cliArgs = Array(CommandLine.arguments.dropFirst())

// MARK: - Codex mode
//
// Codex calls the `notify` program with one trailing JSON argument. The main
// event is `agent-turn-complete`, which includes the assistant's last message.
// Codex provides no session id or cwd, so we derive a stable id from the parent
// (codex) pid and use the inherited working directory.

if cliArgs.first == "codex" {
    let jsonArg = cliArgs.count >= 2 ? cliArgs[1] : "{}"
    let payload = (jsonArg.data(using: .utf8)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]

    let cwd = FileManager.default.currentDirectoryPath
    let project = (cwd as NSString).lastPathComponent
    let sessionID = "codex-\(getppid())"

    var state = "working"
    var activity = "Working…"
    switch payload["type"] as? String ?? "" {
    case "agent-turn-complete":
        state = "done"
        if let msg = payload["last-assistant-message"] as? String, !msg.isEmpty {
            activity = truncate(msg.replacingOccurrences(of: "\n", with: " "), 70)
        } else {
            activity = "Finished"
        }
    case let other where !other.isEmpty:
        state = "working"
        activity = other
    default:
        break
    }

    upsert(sessionID: sessionID, [
        "tool": "codex",
        "cwd": cwd,
        "project": project,
        "state": state,
        "activity": activity,
    ])
    bail()
}

// MARK: - Claude Code mode (stdin)

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

func str(_ key: String) -> String? {
    if let s = payload[key] as? String, !s.isEmpty { return s }
    return nil
}

let event = cliArgs.first ?? str("hook_event_name") ?? "Unknown"

let cwd = str("cwd") ?? FileManager.default.currentDirectoryPath
let sessionID = str("session_id")
    ?? "local-" + cwd.data(using: .utf8)!.base64EncodedString()
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "=", with: "")
let project = (cwd as NSString).lastPathComponent

/// Turn a PreToolUse payload into a short human activity line.
func summarizeTool() -> String {
    let name = str("tool_name") ?? "tool"
    let input = payload["tool_input"] as? [String: Any] ?? [:]
    func s(_ k: String) -> String? { input[k] as? String }
    func base(_ path: String) -> String { (path as NSString).lastPathComponent }

    switch name {
    case "Bash":
        if let cmd = s("command") { return "$ " + truncate(cmd.replacingOccurrences(of: "\n", with: " "), 60) }
        return "Running command"
    case "Edit", "MultiEdit":
        if let f = s("file_path") { return "Editing \(base(f))" }
        return "Editing a file"
    case "Write":
        if let f = s("file_path") { return "Writing \(base(f))" }
        return "Writing a file"
    case "Read":
        if let f = s("file_path") { return "Reading \(base(f))" }
        return "Reading a file"
    case "Grep":
        if let p = s("pattern") { return "Searching “\(truncate(p, 40))”" }
        return "Searching"
    case "Glob":
        if let p = s("pattern") { return "Finding \(truncate(p, 40))" }
        return "Finding files"
    case "WebFetch":
        if let u = s("url") { return "Fetching \(truncate(u, 50))" }
        return "Fetching a page"
    case "WebSearch":
        if let q = s("query") { return "Searching the web: \(truncate(q, 40))" }
        return "Searching the web"
    case "Task":
        if let d = s("description") { return "Subagent: \(truncate(d, 45))" }
        return "Running a subagent"
    case "TodoWrite":
        return "Updating the plan"
    default:
        return "Using \(name)"
    }
}

var state = "working"
var activity = ""

switch event {
case "SessionStart":
    state = "idle"; activity = "Session started"
case "UserPromptSubmit":
    state = "working"
    activity = str("prompt").map { "Thinking · \(truncate($0.replacingOccurrences(of: "\n", with: " "), 50))" } ?? "Thinking…"
case "PreToolUse":
    state = "working"; activity = summarizeTool()
case "PostToolUse":
    state = "working"; activity = "Working…"
case "Notification":
    state = "waiting"; activity = str("message") ?? "Waiting for your input"
case "Stop", "SubagentStop":
    state = "done"; activity = "Finished"
case "SessionEnd":
    removeSession(sessionID); bail()
default:
    state = "working"; activity = event
}

var fields: [String: Any] = [
    "tool": "claude",
    "cwd": cwd,
    "project": project,
    "state": state,
    "activity": activity,
]
if let tp = str("transcript_path") { fields["transcript_path"] = tp }
upsert(sessionID: sessionID, fields)
bail()
