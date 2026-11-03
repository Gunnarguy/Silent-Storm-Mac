import AppKit
import Foundation

/// The native game. It is embedded in the hub at Contents/Games and keeps its own settings and saves.
public enum SilentStormEdition: String, CaseIterable, Identifiable, Sendable {
    case silentStorm = "Silent Storm"

    public var id: String { rawValue }
    public var shortTitle: String { "Silent Storm" }
    public var appName: String { "Silent Storm.app" }
    public var subdirectoryName: String { "Silent Storm" }
    public var databaseFileName: String { "game.db" }

    public var bundleIdentifier: String {
        if let test = ProcessInfo.processInfo.environment["OPENSTORM_GAME_BUNDLE_ID"] { return test }
        return "org.silentstorm.mac"
    }

    /// The game inside the hub, or a copy in /Applications if the hub is run on its own.
    public var appURL: URL {
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Games/\(appName)")
        if FileManager.default.fileExists(atPath: embedded.path) { return embedded }
        return URL(fileURLWithPath: "/Applications/\(appName)")
    }

    public static var dataRoot: URL {
        if let test = ProcessInfo.processInfo.environment["OPENSTORM_DATA_ROOT"] { return URL(fileURLWithPath: test) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Silent Storm")
    }

    public var dataDirectory: URL { Self.dataRoot.appendingPathComponent(subdirectoryName) }

    public var location: GameDataLocation {
        GameDataLocation(dataDirectory: dataDirectory, databaseFileName: databaseFileName)
    }
}

public struct SilentStormSaveInfo: Sendable, Identifiable, Hashable {
    public var id: String { folderURL.path }
    public let slotName: String
    public let folderURL: URL
    public let fileSize: Int64
    public let modifiedDate: Date
}

public struct SilentStormModInfo: Sendable, Identifiable, Hashable {
    public var id: String { path.path }
    public let folderName: String
    public let displayName: String
    public let summaryText: String
    public let path: URL
    public let hasDatabase: Bool
}

/// One soldier as the running game reports it (`squad_dump`, Main/iMission.cpp).
public struct LiveUnit: Sendable, Codable, Identifiable, Hashable {
    public var id: String { "\(pers)-\(name)-\(maxHP)" }
    public let pers: Int32
    public let name: String
    public let hp: Int
    public let healed: Int
    public let maxHP: Int
    public let ap: Int
    public let maxAP: Int
    public let down: Bool
    public let item: Int32?
    public let sight: Int?
    public let interrupt: Int?
    public let ic: Int?
    public let criticals: Int?
    public let hero: Bool?
    public let hidden: Bool?
    public let skills: [String: Int]?
}

public struct LiveSquad: Sendable, Codable, Hashable {
    public let realTime: Bool
    public let playerTurn: Bool
    public let squad: [LiveUnit]
    public let enemies: [LiveUnit]
}

public struct LiveCheat: Sendable, Codable, Identifiable, Hashable {
    public var id: String { `var` }
    public let `var`: String
    public let title: String
    public let detail: String
    public let mission: Bool
    public let on: Bool
}

public struct LiveHubState: Sendable, Codable, Hashable {
    public let graphics: String
    /// Enemy and ally turn speed, 1 to 4. Absent from a game built before it existed.
    public let turnSpeed: Int?
    public let cheats: [LiveCheat]
}

/// Starts the native games and talks to the running one through `_s2cmd.txt` in its data folder.
/// It never writes a game's settings or saves; the only files it writes in there are that command file and, when asked, a copy of a mod.
@MainActor
public final class EngineController: ObservableObject {
    @Published public var selectedEdition: SilentStormEdition = .silentStorm { didSet { if oldValue != selectedEdition { refreshEnvironment() } } }
    @Published public private(set) var runningEdition: SilentStormEdition?
    @Published public var statusMessage: String = "Ready"
    @Published public var consoleLogText: String = ""
    @Published public private(set) var saves: [SilentStormSaveInfo] = []
    @Published public private(set) var mods: [SilentStormModInfo] = []
    @Published public private(set) var liveSquad: LiveSquad?
    @Published public private(set) var liveHubState: LiveHubState?

    private var outbox: [String] = []
    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    public var isGameRunning: Bool { runningEdition != nil }
    public var dataDirectory: URL { selectedEdition.dataDirectory }
    /// The folder live commands and live state go through: the game that is actually running.
    private var liveDirectory: URL { (runningEdition ?? selectedEdition).dataDirectory }

    public init() {
        refreshEnvironment()
        refreshRunningGame()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningGame() }
            })
        }
    }

    public func refreshEnvironment() {
        loadSaves()
        loadMods()
        refreshLogs()
    }

    /// Asks macOS which game is open, so a game started outside the hub, or one that quit or crashed, is seen the same way.
    public func refreshRunningGame() {
        let running = SilentStormEdition.allCases.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty }
        guard running != runningEdition else { return }
        let previous = runningEdition
        runningEdition = running
        if let running {
            statusMessage = "\(running.shortTitle) is running"
            startPolling()
        } else {
            statusMessage = previous.map { "\($0.shortTitle) quit" } ?? "Ready"
            stopPolling()
            liveSquad = nil
            liveHubState = nil
            loadSaves()
        }
    }

    // MARK: Starting and stopping

    public func launchGame(loadingSlot slot: String? = nil) {
        let url = selectedEdition.appURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Game not found: \(url.path)"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let slot {
            // The engine's own start-up load: it reads the slot name from this file, then opens the save instead of the menu.
            do {
                try Data(slot.utf8).write(to: dataDirectory.appendingPathComponent("_loadslot.txt"), options: .atomic)
                configuration.arguments = ["-loadslot"]
            } catch {
                statusMessage = "Could not prepare the load: \(error.localizedDescription)"
                return
            }
        }
        statusMessage = "Opening \(selectedEdition.shortTitle)"
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let message { self.statusMessage = "Launch failed: \(message)" }
                self.refreshRunningGame()
            }
        }
    }

    /// Asks the game to quit like Cmd-Q, so it saves its own settings on the way out.
    public func terminateGame() {
        guard let edition = runningEdition else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: edition.bundleIdentifier).first?.terminate()
        statusMessage = "Asked \(edition.shortTitle) to quit"
    }

    // MARK: Live commands

    /// A line the native engine's `_s2cmd.txt` hook accepts, from what someone typed.
    public nonisolated static func nativeCommandLine(_ rawCommand: String) -> String? {
        let c = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty || c.contains("\n") { return nil }
        return "cmd \(c)"
    }

    public func sendConsoleCommand(_ command: String) {
        guard let line = Self.nativeCommandLine(command) else { return }
        send(line)
    }

    public func setGraphics(original: Bool) { send(original ? "graphics original" : "graphics enhanced") }
    public func setTurnSpeed(_ speed: Int) { send("turnspeed \(max(1, min(4, speed)))") }
    public func setCheat(_ cheat: LiveCheat, on: Bool) { send("cheat \(cheat.var) \(on ? 1 : 0)") }
    public func saveGame(named slot: String) { send("cmd save \(slot)") }
    public func loadGame(named slot: String) { send("cmd load \(slot)") }

    public func send(_ line: String) {
        guard isGameRunning else {
            statusMessage = "Start the game first: commands only reach a running game"
            return
        }
        outbox.append(line)
        statusMessage = "Sent: \(line)"
        flushOutbox()
    }

    /// The game deletes the command file after reading it, so lines wait in the outbox while one is still there.
    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        let url = liveDirectory.appendingPathComponent("_s2cmd.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = outbox.joined(separator: "\n") + "\n"
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            outbox.removeAll()
        } catch {
            statusMessage = "Command failed: \(error.localizedDescription)"
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.flushOutbox()
                if tick % 10 == 0 {
                    // Launch and quit notices don't cover every way a game can end, so ask directly as well.
                    self.refreshRunningGame()
                    if self.isGameRunning { self.pollLiveState() }
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        outbox.removeAll()
    }

    private func pollLiveState() {
        let dir = liveDirectory
        func fresh<T: Decodable>(_ name: String, within seconds: TimeInterval, as type: T.Type) -> T? {
            let url = dir.appendingPathComponent(name)
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(date) < seconds,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        // squad_dump only exists during a mission, so a file that stops changing means the mission ended.
        liveSquad = fresh("_squad.json", within: 9, as: LiveSquad.self)
        if let state = fresh("_hubstate.json", within: 9, as: LiveHubState.self) { liveHubState = state }
        outbox.append("hubstate")
        outbox.append("cmd squad_dump")
        flushOutbox()
        refreshLogs()
    }

    // MARK: Saves

    /// Native saves are slot folders: `save/<profile>/<slot>/game.sav`. Listing them is read-only.
    public func loadSaves() {
        let fm = FileManager.default
        var list: [SilentStormSaveInfo] = []
        let saveRoot = dataDirectory.appendingPathComponent("save")
        for profile in (try? fm.contentsOfDirectory(at: saveRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            for slot in (try? fm.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                let file = slot.appendingPathComponent("game.sav")
                guard let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                list.append(SilentStormSaveInfo(slotName: slot.lastPathComponent, folderURL: slot, fileSize: Int64(vals.fileSize ?? 0),
                                                modifiedDate: vals.contentModificationDate ?? .distantPast))
            }
        }
        saves = list.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    /// Copies the whole save folder beside the game data, under Save Backups. Nothing in `save/` is touched.
    public func backUpSaves() {
        let source = dataDirectory.appendingPathComponent("save")
        let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let root = SilentStormEdition.dataRoot.appendingPathComponent("Save Backups")
        let destination = root.appendingPathComponent("\(selectedEdition.shortTitle) \(stamp)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            statusMessage = "Saves backed up to Save Backups/\(destination.lastPathComponent)"
        } catch {
            statusMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    // MARK: Mods

    private static let notMods: Set<String> = ["cfg", "res", "save", "scripts", "hd", "screenshots", "temp", "manual", "usermanual"]

    /// What the game's Custom Game menu lists: any folder in the game's root with a description.txt (`CModManager::GetAvailableMods`).
    public func loadMods() {
        let fm = FileManager.default
        var result: [SilentStormModInfo] = []
        let items = (try? fm.contentsOfDirectory(at: dataDirectory.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in items where !Self.notMods.contains(url.lastPathComponent.lowercased()) {
            let description = url.appendingPathComponent("description.txt")
            guard fm.fileExists(atPath: description.path), let data = try? Data(contentsOf: description) else { continue }
            let text = (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            let first = text.components(separatedBy: .newlines).first ?? ""
            result.append(SilentStormModInfo(folderName: url.lastPathComponent, displayName: first.isEmpty ? url.lastPathComponent : first, summaryText: text,
                                             path: url, hasDatabase: fm.fileExists(atPath: url.appendingPathComponent(selectedEdition.databaseFileName).path)))
        }
        mods = result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Copies a mod folder, or unpacks a .zip, into the game's root. Turning a mod on happens in the game, under Custom Game.
    public func installMod(from source: URL) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("hub-mod-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            if source.pathExtension.lowercased() == "zip" {
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", source.path, scratch.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { statusMessage = "Could not unpack \(source.lastPathComponent)"; return }
            } else {
                try fm.copyItem(at: source, to: scratch.appendingPathComponent(source.lastPathComponent))
            }
            guard let root = Self.findModRoot(in: scratch) else {
                statusMessage = "No description.txt found, so the game would not list this as a mod"
                return
            }
            let name = root == scratch ? source.deletingPathExtension().lastPathComponent : root.lastPathComponent
            let destination = dataDirectory.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else {
                statusMessage = "A folder named \(name) already exists"
                return
            }
            try fm.copyItem(at: root, to: destination)
            statusMessage = "Added \(name). Turn it on in the game under Custom Game."
            loadMods()
        } catch {
            statusMessage = "Mod not added: \(error.localizedDescription)"
        }
    }

    private static func findModRoot(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.lowercased() == "description.txt" {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    /// Moves a mod to the Trash, so removing one can be undone.
    public func removeMod(_ mod: SilentStormModInfo) {
        do {
            try FileManager.default.trashItem(at: mod.path, resultingItemURL: nil)
            statusMessage = "Moved \(mod.folderName) to the Trash"
            loadMods()
        } catch {
            statusMessage = "Could not remove \(mod.folderName): \(error.localizedDescription)"
        }
    }

    // MARK: Logs

    /// The engine writes `_console.log` when Settings > Advanced > Console log file is on.
    public func refreshLogs() {
        let url = liveDirectory.appendingPathComponent("_console.log")
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            consoleLogText = ""
            return
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 40_000 ? size - 40_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        consoleLogText = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<color=[a-z]+>", with: "", options: .regularExpression)
    }
}
