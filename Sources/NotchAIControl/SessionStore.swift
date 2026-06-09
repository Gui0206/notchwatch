import SwiftUI
import Combine

enum SessionState: String, Codable {
    case idle, working, waiting, done, error, stale

    /// Priority for sorting — lower sorts first. Things that need the user come first.
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .error:   return 1
        case .working: return 2
        case .idle:    return 3
        case .done:    return 4
        case .stale:   return 5
        }
    }

    var color: Color {
        switch self {
        case .waiting: return .orange
        case .error:   return .red
        case .working: return .blue
        case .idle:    return .gray
        case .done:    return .green
        case .stale:   return Color(white: 0.45)
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "bell.badge.fill"
        case .error:   return "exclamationmark.triangle.fill"
        case .working: return "circle.dotted"
        case .idle:    return "moon.zzz.fill"
        case .done:    return "checkmark.circle.fill"
        case .stale:   return "questionmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .waiting: return "Needs you"
        case .error:   return "Error"
        case .working: return "Working"
        case .idle:    return "Idle"
        case .done:    return "Done"
        case .stale:   return "Stale"
        }
    }

    /// Should this state pulse to draw attention?
    var pulses: Bool { self == .waiting || self == .working }
}

struct Session: Identifiable, Equatable {
    let id: String          // session_id
    var tool: String
    var project: String
    var cwd: String
    var state: SessionState
    var activity: String
    var startedAt: Date
    var updatedAt: Date
    var transcriptPath: String?
    var ownerBundleID: String?
    var ownerAppPath: String?
    var ownerName: String?
    var ownerKind: String?

    static func == (l: Session, r: Session) -> Bool {
        l.id == r.id && l.state == r.state && l.activity == r.activity &&
        l.updatedAt == r.updatedAt && l.project == r.project && l.ownerName == r.ownerName
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let dir: URL
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var reloadTimer: Timer?
    private var tickTimer: Timer?

    // Tuning
    private let staleAfter: TimeInterval = 8 * 60      // working w/o updates -> stale
    private let dismissDoneAfter: TimeInterval = 15 * 60 // done -> auto-remove

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notch-ai-control/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dir = base
        load()
        startWatching()
        startTicking()
    }

    // MARK: Derived

    var sorted: [Session] {
        sessions.sorted { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            return a.updatedAt > b.updatedAt
        }
    }

    var needsAttentionCount: Int { sessions.filter { $0.state == .waiting || $0.state == .error }.count }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var doneCount: Int { sessions.filter { $0.state == .done }.count }

    /// The single most important state across all sessions, for the collapsed pill.
    var headlineState: SessionState? {
        sessions.min { $0.state.rank < $1.state.rank }?.state
    }

    // MARK: Watching

    private func startWatching() {
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }
        src.resume()
        dirSource = src
    }

    private func scheduleReload() {
        // Debounce bursts of writes.
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    private func startTicking() {
        // Re-evaluate staleness and auto-dismissal once a second; also drives
        // the live "elapsed" timers in the UI via objectWillChange.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        var changed = false
        for i in sessions.indices {
            let s = sessions[i]
            if s.state == .working, now.timeIntervalSince(s.updatedAt) > staleAfter {
                sessions[i].state = .stale
                changed = true
            }
            if s.state == .done, now.timeIntervalSince(s.updatedAt) > dismissDoneAfter {
                remove(id: s.id)
                changed = true
            }
        }
        // Always nudge so elapsed timers refresh.
        objectWillChange.send()
        _ = changed
    }

    // MARK: Loading

    func load() {
        // Remember prior states so we can detect transitions (for sounds).
        let priorStates = Dictionary(sessions.map { ($0.id, $0.state) },
                                     uniquingKeysWith: { a, _ in a })

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Session] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let id = obj["session_id"] as? String else { continue }
            let stateRaw = obj["state"] as? String ?? "working"
            let started = (obj["started_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let updated = (obj["updated_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            loaded.append(Session(
                id: id,
                tool: obj["tool"] as? String ?? "claude",
                project: obj["project"] as? String ?? "—",
                cwd: obj["cwd"] as? String ?? "",
                state: SessionState(rawValue: stateRaw) ?? .working,
                activity: obj["activity"] as? String ?? "",
                startedAt: started,
                updatedAt: updated,
                transcriptPath: obj["transcript_path"] as? String,
                ownerBundleID: obj["owner_bundle_id"] as? String,
                ownerAppPath: obj["owner_app_path"] as? String,
                ownerName: obj["owner_name"] as? String,
                ownerKind: obj["owner_kind"] as? String
            ))
        }
        // Sound on meaningful transitions. We only fire when we had a prior
        // state for that id, so loading existing sessions at launch is silent.
        for s in loaded {
            guard let prev = priorStates[s.id], prev != s.state else { continue }
            if s.state == .done {
                NotchSound.finished()
            } else if s.state == .waiting {
                NotchSound.needsYou()
            }
        }

        if loaded != sessions { sessions = loaded }
    }

    // MARK: Mutations

    func remove(id: String) {
        let file = dir.appendingPathComponent(id + ".json")
        try? FileManager.default.removeItem(at: file)
        sessions.removeAll { $0.id == id }
    }

    func clearFinished() {
        for s in sessions where s.state == .done || s.state == .stale || s.state == .error {
            remove(id: s.id)
        }
    }
}
