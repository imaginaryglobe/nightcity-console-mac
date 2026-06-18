import SwiftUI
import AppKit

enum Const {
    static let appVersion = "1.0.0"
    static let supportedGameVersion = "2.3.1"
    static let defaultGame = "\(NSHomeDirectory())/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
    // Files copied from the app's Resources into <game>/red4ext/ on install.
    static let payload = ["red4ext_hooks.js", "FridaGadget.config", "RED4ext.dylib",
                          "FridaGadget.dylib", "libcyberconsole_overlay.dylib"]
    static let commandsURL = "https://github.com/ysrdevs/cet-mac/blob/main/docs/COMMANDS.md"
    static let supportURL = "https://ko-fi.com/ysrdevs"
}

final class Model: ObservableObject {
    @Published var gamePath: String
    @Published var status: String = ""
    @Published var installed: Bool = false
    @Published var gameVersion: String? = nil

    private let defaults = UserDefaults.standard

    init() {
        gamePath = defaults.string(forKey: "gamePath") ?? Const.defaultGame
        refresh()
    }

    var binaryPath: String { "\(gamePath)/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" }
    var red4Dir: String { "\(gamePath)/red4ext" }
    var gameFound: Bool { FileManager.default.fileExists(atPath: binaryPath) }

    // the three dylibs DYLD_INSERT_LIBRARIES will load (must all exist before launch)
    var injectDylibs: [String] { ["RED4ext.dylib", "FridaGadget.dylib", "libcyberconsole_overlay.dylib"] }
    func fullyInstalled() -> Bool {
        let fm = FileManager.default
        return Const.payload.allSatisfy { fm.fileExists(atPath: "\(red4Dir)/\($0)") }
    }

    func setGamePath(_ p: String) {
        gamePath = p
        defaults.set(p, forKey: "gamePath")
        refresh()
    }

    func refresh() {
        gameVersion = readGameVersion()
        installed = fullyInstalled()
        if !gameFound {
            status = "Cyberpunk 2077 not found here - click Browse to locate it."
        } else {
            let v = gameVersion.map { " (v\($0))" } ?? ""
            status = "Game found\(v)" + (installed ? " · CET Mac installed" : " · not installed yet")
        }
    }

    func readGameVersion() -> String? {
        let plist = "\(gamePath)/Cyberpunk2077.app/Contents/Info.plist"
        guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }

    func install() {
        guard gameFound else { status = "Game not found."; return }
        guard let res = Bundle.main.resourceURL else { status = "Bundle resources missing."; return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: red4Dir, withIntermediateDirectories: true)
            for f in Const.payload {
                let src = res.appendingPathComponent(f)
                guard fm.fileExists(atPath: src.path) else { status = "Missing bundled file: \(f)"; return }
                let dst = URL(fileURLWithPath: "\(red4Dir)/\(f)")
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            stripQuarantine(red4Dir)   // files we just wrote -> make dyld load them
            status = "Installed ✓  - click Play."
            refresh()
        } catch {
            status = "Install failed: \(error.localizedDescription)"
        }
    }

    func uninstall() {
        let fm = FileManager.default
        for f in Const.payload {
            let p = "\(red4Dir)/\(f)"
            if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        }
        // also clear any wrapper left over from earlier builds
        let wrap = "\(red4Dir)/cyberconsole-launch.sh"
        if fm.fileExists(atPath: wrap) { try? fm.removeItem(atPath: wrap) }
        status = "Uninstalled."
        refresh()
    }

    func stripQuarantine(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", path]
        try? p.run()
        p.waitUntilExit()
    }

    func ensureSteam() {
        let ws = NSWorkspace.shared
        let running = ws.runningApplications.contains { $0.bundleIdentifier == "com.valvesoftware.steam" }
        if !running, let steam = ws.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") {
            ws.openApplication(at: steam, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    func play() {
        guard gameFound else { status = "Game not found."; return }
        if !fullyInstalled() { install() }   // self-heal stale/partial installs
        // pre-flight: every injected dylib must exist, or the game aborts on launch
        let fm = FileManager.default
        let missing = injectDylibs.filter { !fm.fileExists(atPath: "\(red4Dir)/\($0)") }
        guard missing.isEmpty else { status = "Can't launch - missing: \(missing.joined(separator: ", ")). Try Install again."; return }
        ensureSteam()
        let inject = "\(red4Dir)/RED4ext.dylib:\(red4Dir)/FridaGadget.dylib:\(red4Dir)/libcyberconsole_overlay.dylib"
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = inject
        env["DYLD_FORCE_FLAT_NAMESPACE"] = "1"
        env["SteamAppId"] = "1091500"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.currentDirectoryURL = URL(fileURLWithPath: gamePath)
        p.environment = env
        do {
            try p.run()
            status = "Launched - press  `  or  F1  in-game to open the console."
        } catch {
            status = "Launch failed: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var m = Model()

    var versionMismatch: Bool {
        guard let v = m.gameVersion else { return false }
        return m.gameFound && v != Const.supportedGameVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CET Mac").font(.largeTitle.bold())
            Text("In-game cheat console for Cyberpunk 2077 · macOS").foregroundColor(.secondary)
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("GAME FOLDER").font(.caption2).foregroundColor(.secondary)
                HStack {
                    Text(m.gamePath)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Browse…") { browse() }
                }
            }

            if versionMismatch, let v = m.gameVersion {
                Label("Detected game v\(v); CET Mac targets v\(Const.supportedGameVersion). It may not work.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.orange)
            }

            HStack(spacing: 12) {
                Button(m.installed ? "Reinstall CET Mac" : "Install") { m.install() }
                    .disabled(!m.gameFound)
                Button("Play  ▶") { m.play() }
                    .disabled(!m.installed)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Uninstall CET Mac") { m.uninstall() }
                    .disabled(!m.installed)
            }

            Spacer()
            HStack {
                Text(m.status).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Link("Commands", destination: URL(string: Const.commandsURL)!)
                Link("♥ Support", destination: URL(string: Const.supportURL)!)
            }
            Text("Single-player only · back up your saves").font(.caption2).foregroundColor(.secondary)
        }
        .padding(22)
        .frame(width: 600, height: 380)
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select your 'Cyberpunk 2077' folder"
        if panel.runModal() == .OK, let url = panel.url { m.setGamePath(url.path) }
    }
}

@main
struct CyberConsoleApp: App {
    var body: some Scene {
        WindowGroup("CET Mac") {
            ContentView()
        }
    }
}
