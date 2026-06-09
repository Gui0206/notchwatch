import Foundation
import Darwin

/// The GUI app that owns a Claude Code session (the terminal/editor it runs in).
struct OwnerInfo {
    let bundleID: String
    let appPath: String
    let name: String
    let kind: String
}

/// Walks up the process tree from this hook and identifies the hosting app.
func detectOwner() -> OwnerInfo? {
    var appPath: String?
    var pid = getppid()
    var hops = 0
    while pid > 1 && hops < 40 {
        if let p = execPath(of: pid), let app = outermostApp(in: p) {
            appPath = app          // first GUI app we hit = the hosting terminal/editor
            break
        }
        guard let pp = parentPID(of: pid), pp != pid, pp > 1 else { break }
        pid = pp
        hops += 1
    }
    guard let path = appPath else { return nil }
    let bundle = Bundle(path: path)
    let id = bundle?.bundleIdentifier ?? ""
    let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    return OwnerInfo(bundleID: id, appPath: path, name: name, kind: classify(bundleID: id, name: name))
}

// MARK: - Process tree helpers

private func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let r = sysctl(&mib, 4, &info, &size, nil, 0)
    if r != 0 || size == 0 { return nil }
    return info.kp_eproc.e_ppid
}

private func execPath(of pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let len = proc_pidpath(pid, &buf, UInt32(buf.count))
    if len <= 0 { return nil }
    return String(cString: buf)
}

/// "/Applications/Visual Studio Code.app/Contents/.../Code Helper" -> the outermost ".app".
private func outermostApp(in path: String) -> String? {
    guard let r = path.range(of: ".app") else { return nil }
    return String(path[..<r.upperBound])
}

private func classify(bundleID: String, name: String) -> String {
    let id = bundleID.lowercased(), n = name.lowercased()
    if id.contains("vscodium") || n.contains("vscodium") { return "vscodium" }
    if id == "com.microsoft.vscodeinsiders" { return "vscode-insiders" }
    if id == "com.microsoft.vscode" || n == "visual studio code" || n == "code" { return "vscode" }
    if id.contains("cursor") || n == "cursor" { return "cursor" }
    if id == "com.googlecode.iterm2" || n.contains("iterm") { return "iterm" }
    if id == "com.apple.terminal" || n == "terminal" { return "apple_terminal" }
    if id.contains("wezterm") || n.contains("wezterm") { return "wezterm" }
    if id.contains("ghostty") || n.contains("ghostty") { return "ghostty" }
    if id.contains("kitty") || n.contains("kitty") { return "kitty" }
    if id.contains("alacritty") || n.contains("alacritty") { return "alacritty" }
    if id.contains("warp") || n.contains("warp") { return "warp" }
    if id.contains("hyper") || n.contains("hyper") { return "hyper" }
    return "generic"
}
