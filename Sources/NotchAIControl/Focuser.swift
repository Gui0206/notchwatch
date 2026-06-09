import AppKit

/// Brings the user to where a Claude session is actually running.
///
/// For VS Code / Cursor / VSCodium we invoke their bundled CLI with the project
/// folder, which focuses the *exact window* hosting that workspace — no
/// Accessibility/Automation permission required. For everything else we bring
/// the owning app to the front.
enum Focuser {
    static func focus(_ s: Session) {
        var broughtForward = false

        // 1) Editor-specific: focus the precise window for this folder.
        if let appPath = s.ownerAppPath, !s.cwd.isEmpty,
           let cli = editorCLI(kind: s.ownerKind, appPath: appPath) {
            runDetached(cli, args: [s.cwd])
            broughtForward = true   // the CLI also raises the app
        }

        // 2) Bring the owning app to the front.
        if let id = s.ownerBundleID, !id.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate(options: [.activateAllWindows])
            broughtForward = true
        } else if let appPath = s.ownerAppPath, !broughtForward {
            NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
            broughtForward = true
        }

        // 3) Last resort: reveal the working directory in Finder.
        if !broughtForward, !s.cwd.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
        }
    }

    /// A short hint for the UI, e.g. "Open in Visual Studio Code".
    static func actionHint(_ s: Session) -> String {
        if let name = s.ownerName, !name.isEmpty { return "Open in \(name)" }
        return "Reveal in Finder"
    }

    private static func editorCLI(kind: String?, appPath: String) -> String? {
        let bin: String
        switch kind {
        case "vscode":          bin = "code"
        case "vscode-insiders": bin = "code-insiders"
        case "vscodium":        bin = "codium"
        case "cursor":          bin = "cursor"
        default: return nil
        }
        let path = appPath + "/Contents/Resources/app/bin/" + bin
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func runDetached(_ launchPath: String, args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try? p.run()
    }
}
