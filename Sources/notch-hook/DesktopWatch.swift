import Foundation

// Claude Desktop watcher
// ----------------------
// Claude Desktop runs its local "cowork" agent sessions as Claude Code under the
// hood. Each session keeps a structured, append-only event log on the host disk:
//
//   ~/Library/Application Support/Claude/local-agent-mode-sessions/
//       <account>/<org>/local_<id>/audit.jsonl
//
// and sibling metadata at ".../<org>/local_<id>.json" (human title, the folders
// the user pointed it at, archived flag).
//
// `audit.jsonl` is the same streaming-JSON schema Claude Code emits, so it gives
// us a real working / needs-you / done lifecycle without any hooks, MCP server,
// or special permissions. This watcher tails those logs and writes the same
// per-session status files the hooks do (tool = "claude-desktop"), so the app,
// sounds, sorting and focus logic all work unchanged.

private let claudeSessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions",
                            isDirectory: true)

private let claudeAppPath = "/Applications/Claude.app"
private let claudeBundleID = "com.anthropic.claudefordesktop"

/// Tail state for one session's audit.jsonl.
private final class AuditTail {
    let url: URL                 // .../local_<id>/audit.jsonl
    let notchID: String          // cd-local_<id>
    let metaURL: URL             // .../local_<id>.json
    var offset: UInt64           // bytes consumed so far
    var partial = ""             // trailing line not yet terminated by "\n"
    var lastActivity = "Working…"
    var lastState = "working"
    var removed = false

    init(url: URL, offset: UInt64) {
        self.url = url
        self.offset = offset
        let folder = url.deletingLastPathComponent()          // .../local_<id>
        let folderName = folder.lastPathComponent             // local_<id>
        self.notchID = "cd-" + folderName
        self.metaURL = folder.deletingLastPathComponent()     // .../<org>
            .appendingPathComponent(folderName + ".json")
    }
}

/// Read-once-cached session metadata (title / project folders / archived).
private struct Meta {
    var project: String
    var cwd: String
    var archived: Bool
}

private func readMeta(_ url: URL) -> Meta? {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let folders = obj["userSelectedFolders"] as? [String] ?? []
    let cwd = folders.first ?? (obj["cwd"] as? String ?? "")

    // Prefer the human title; fall back to the project folder's name.
    var project = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? (cwd.isEmpty ? "Claude" : (cwd as NSString).lastPathComponent)
    project = truncate(project, 28)

    return Meta(project: project, cwd: cwd, archived: obj["isArchived"] as? Bool ?? false)
}

// MARK: - Event → state

/// Fold one audit event into the tail's running (state, activity). Returns false
/// for events that carry no display-worthy change.
private func apply(event o: [String: Any], to t: AuditTail) -> Bool {
    switch o["type"] as? String {
    case "system":
        switch o["subtype"] as? String {
        case "init":
            t.lastState = "working"; t.lastActivity = "Thinking…"; return true
        case "status":
            // "requesting" → the model is generating. Keep whatever activity we
            // last showed (a tool line is more useful than a generic label).
            if (o["status"] as? String) == "requesting" {
                t.lastState = "working"
                if t.lastActivity.isEmpty { t.lastActivity = "Thinking…" }
                return true
            }
            return false
        default:
            return false
        }

    case "assistant":
        guard let msg = o["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { return false }
        var changed = false
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                if name == "AskUserQuestion" {
                    t.lastState = "waiting"
                    t.lastActivity = askQuestionSummary(input)
                } else {
                    t.lastState = "working"
                    t.lastActivity = summarizeTool(name: name, input: input)
                }
                changed = true
            case "text":
                if let txt = (block["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !txt.isEmpty {
                    t.lastState = "working"
                    t.lastActivity = truncate(txt.replacingOccurrences(of: "\n", with: " "), 70)
                    changed = true
                }
            default:
                break
            }
        }
        return changed

    case "user":
        // Real prompts advance us to "working"; tool results just keep us there.
        if isToolResult(o) {
            t.lastState = "working"
            if t.lastActivity.isEmpty { t.lastActivity = "Working…" }
        } else {
            t.lastState = "working"
            t.lastActivity = promptSummary(o)
        }
        return true

    case "result":
        t.lastState = "done"; t.lastActivity = "Finished"; return true

    case "rate_limit_event":
        t.lastState = "waiting"; t.lastActivity = "Rate limited — check Claude"; return true

    default:
        return false
    }
}

private func isToolResult(_ o: [String: Any]) -> Bool {
    if o["tool_use_result"] != nil { return true }
    if let msg = o["message"] as? [String: Any],
       let content = msg["content"] as? [[String: Any]] {
        return content.contains { ($0["type"] as? String) == "tool_result" }
    }
    return false
}

private func promptSummary(_ o: [String: Any]) -> String {
    guard let msg = o["message"] as? [String: Any] else { return "Thinking…" }
    var text = ""
    if let s = msg["content"] as? String {
        text = s
    } else if let blocks = msg["content"] as? [[String: Any]] {
        text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
    return text.isEmpty ? "Thinking…" : "Thinking · " + truncate(text, 50)
}

private func askQuestionSummary(_ input: [String: Any]) -> String {
    if let qs = input["questions"] as? [[String: Any]],
       let first = qs.first,
       let q = first["question"] as? String, !q.isEmpty {
        return truncate(q.replacingOccurrences(of: "\n", with: " "), 60)
    }
    return "Waiting for your input"
}

// MARK: - Tailing

private func publish(_ t: AuditTail, _ meta: Meta) {
    upsert(sessionID: t.notchID, [
        "tool": "claude-desktop",
        "cwd": meta.cwd,
        "project": meta.project,
        "state": t.lastState,
        "activity": t.lastActivity,
        "owner_bundle_id": claudeBundleID,
        "owner_app_path": claudeAppPath,
        "owner_name": "Claude",
        "owner_kind": "claude_desktop",
    ])
}

/// Consume any bytes appended since we last looked; republish if state changed.
private func drain(_ t: AuditTail) {
    let fm = FileManager.default
    let size = (try? fm.attributesOfItem(atPath: t.url.path)[.size] as? Int).flatMap { $0 }
        .map { UInt64($0) } ?? 0

    // File rotated/truncated — start over.
    if size < t.offset { t.offset = 0; t.partial = "" }
    guard size > t.offset else { return }

    guard let fh = try? FileHandle(forReadingFrom: t.url) else { return }
    defer { try? fh.close() }
    try? fh.seek(toOffset: t.offset)
    let data = (try? fh.readToEnd()) ?? Data()
    t.offset += UInt64(data.count)
    guard !data.isEmpty else { return }

    var lines = (t.partial + (String(data: data, encoding: .utf8) ?? "")).components(separatedBy: "\n")
    t.partial = lines.removeLast()   // possibly-incomplete final line

    // Metadata can change between turns (title set, archived); re-read per batch.
    let meta = readMeta(t.metaURL)
    if meta?.archived == true {
        if !t.removed { removeSession(t.notchID); t.removed = true }
        return
    }
    t.removed = false

    var changed = false
    for line in lines where !line.isEmpty {
        guard let obj = (line.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        else { continue }
        if apply(event: obj, to: t) { changed = true }
    }
    if changed, let meta { publish(t, meta) }
}

/// All audit.jsonl files under <account>/<org>/local_*/.
private func discoverAuditFiles() -> [URL] {
    let fm = FileManager.default
    func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    }
    var out: [URL] = []
    for account in children(claudeSessionsDir) {
        for org in children(account) {
            for session in children(org) where session.lastPathComponent.hasPrefix("local_") {
                let audit = session.appendingPathComponent("audit.jsonl")
                if fm.fileExists(atPath: audit.path) { out.append(audit) }
            }
        }
    }
    return out
}

// MARK: - Run loop

func runDesktopWatcher() -> Never {
    var tails: [String: AuditTail] = [:]   // audit path -> tail
    var seeded = false

    while true {
        // Exit promptly if our parent (the app) went away — keeps us from
        // lingering or double-running after a relaunch.
        if getppid() <= 1 { exit(0) }

        for url in discoverAuditFiles() {
            if tails[url.path] != nil { continue }
            // First sweep: skip all existing history (start at EOF) so we only
            // surface live activity. Sessions that appear later are brand new,
            // so we read them from the start.
            let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0
            let startOffset: UInt64 = seeded ? 0 : UInt64(size)
            tails[url.path] = AuditTail(url: url, offset: startOffset)
        }
        seeded = true

        for t in tails.values { drain(t) }

        Thread.sleep(forTimeInterval: 1.0)
    }
}
