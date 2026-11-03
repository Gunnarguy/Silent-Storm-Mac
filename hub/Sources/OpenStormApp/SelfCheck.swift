import AppKit
import AVFoundation
import SwiftUI
import OpenStormCore

/// `--self-check <folder>` opens every screen of the game in a window placed far off every display, saves a picture of each and
/// writes a report. The hub stays out of the Dock and never takes focus or the pointer. `--self-check-live` also drives a running
/// test game. Nothing here runs in normal use.
@MainActor
enum SelfCheck {
    static var folder: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(where: { $0.hasPrefix("--self-check") }), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }
    static var isLive: Bool { ProcessInfo.processInfo.arguments.contains("--self-check-live") }
    static var isRequested: Bool { folder != nil }

    private static var window: NSWindow?
    private static var host: NSHostingView<AnyView>?
    private static var report: [String] = []

    private static func note(_ line: String) {
        report.append(line)
        print(line)
    }

    private static func picture(_ name: String) {
        guard let host, let folder else { return }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private static func settle(_ seconds: Double = 1.2) async { try? await Task.sleep(for: .seconds(seconds)) }

    static func run() {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            let hub = HubModel()
            hub.player.volume = 0
            let hosting = NSHostingView(rootView: AnyView(HubRootView(hub: hub).frame(width: 1440, height: 900).preferredColorScheme(.dark)))
            hosting.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = .windowBackgroundColor
            win.contentView = hosting
            win.orderFrontRegardless()
            window = win
            host = hosting
            if ProcessInfo.processInfo.arguments.contains("--self-check-files") {
                await fileChecks(hub.engine)
            } else if isLive {
                await liveChecks(hub)
            } else {
                await screenChecks(hub)
            }
            try? report.joined(separator: "\n").appending("\n").write(to: folder.appendingPathComponent(isLive ? "live-report.txt" : "report.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    private static func screenChecks(_ hub: HubModel) async {
        for edition in SilentStormEdition.allCases {
            let tag = "ss"
            hub.engine.selectedEdition = edition
            while hub.store.library == nil {
                if hub.store.failure != nil { note("FAIL \(tag) library: \(hub.store.failure ?? "")"); return }
                await settle(0.2)
            }
            await settle(0.5)
            guard let library = hub.store.library else { return }
            note("game app: \(edition.appURL.path), exists \(FileManager.default.fileExists(atPath: edition.appURL.path))")
            note("[\(edition.rawValue)] people \(library.characters.count), lines \(library.lines.count), items \(library.arsenal.count), missions \(library.missions.count)")
            for section in HubSection.allCases {
                hub.section = section
                await settle(section == .database ? 2.5 : 1.5)
                picture("\(tag)-\(section.id.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "&", with: "and"))")
                note("screen \(section.rawValue): opened")
            }
            // One of each kind of person, with the 3D model read back from the GPU.
            for kind in CharacterKind.allCases {
                guard let person = library.characters.first(where: { $0.kind == kind && $0.lineCount > 0 && $0.visual != nil }) ?? library.characters.first(where: { $0.kind == kind }) else {
                    note("person kind \(kind.rawValue): none")
                    continue
                }
                hub.openPerson(person.id)
                await settle(1.4)
                picture("\(tag)-person-\(kind.id.prefix(6).replacingOccurrences(of: " ", with: "-"))")
                if person.visual == nil {
                    note("model \(kind.rawValue): none listed")
                } else if let coordinator = MetalGeometryCoordinator.latest, let shot = coordinator.snapshot(width: 460, height: 560) {
                    if let data = NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:]) {
                        try? data.write(to: folder!.appendingPathComponent("\(tag)-model-\(kind.id.prefix(6).replacingOccurrences(of: " ", with: "-")).png"))
                    }
                } else {
                    note("FAIL model \(kind.rawValue): nothing drawn")
                }
                note("person \(kind.rawValue): \(person.name), \(person.lineCount) lines")
            }
            // A line, played through the real player at zero volume.
            if let line = library.lines.first(where: { VoiceRow.clip(for: $0, in: hub) != nil }), let clip = VoiceRow.clip(for: line, in: hub) {
                hub.openVoices(of: line.ownerID)
                hub.lineID = line.id
                hub.player.play(clip)
                await settle(1.5)
                picture("\(tag)-voice-line")
                // progress, not isPlaying: the old player said playing while its clip never started
                let moved = hub.player.progress
                note("\(moved > 0 ? "" : "FAIL ")voice line: playing=\(hub.player.isPlaying), progress \(String(format: "%.2f", moved)) after 1.5 s, duration \(String(format: "%.2f", hub.player.duration)) s, waveform bars \(hub.player.waveform.count), peak \(hub.player.waveform.max() ?? 0)")
                hub.player.stop()
            }
            if let gun = library.arsenal.first(where: { $0.name.hasPrefix("Colt M1911") && $0.visual != nil }) {
                hub.openItem(gun.id)
                await settle(1.4)
                picture("\(tag)-gun")
                if let shot = MetalGeometryCoordinator.latest?.snapshot(width: 560, height: 440), let data = NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:]) {
                    try? data.write(to: folder!.appendingPathComponent("\(tag)-model-gun.png"))
                }
                note("gun \(gun.name): \(gun.values.count) values")
            }
            hub.section = .advisor
            await hub.advisor.ask("Compare the Luger and the Colt M1911", library: library, squad: nil)
            await settle(0.8)
            picture("\(tag)-advisor-answer")
            note("advisor: \(hub.advisor.modelStatus): \(hub.advisor.messages.last?.text.prefix(160) ?? "")")
            hub.advisor.messages.removeAll()
        }
        note("DONE")
    }

    /// Backup and mod buttons, against the disposable data folder the check runs on.
    private static func fileChecks(_ engine: EngineController) async {
        let fm = FileManager.default
        guard ProcessInfo.processInfo.environment["OPENSTORM_DATA_ROOT"] != nil else { return }
        engine.backUpSaves()
        let backups = (try? fm.contentsOfDirectory(atPath: SilentStormEdition.dataRoot.appendingPathComponent("Save Backups").path)) ?? []
        note("backup: \(engine.statusMessage), folders \(backups.count)")
        let scratch = fm.temporaryDirectory.appendingPathComponent("hub-check-\(UUID().uuidString)")
        let mod = scratch.appendingPathComponent("HubCheckMod")
        try? fm.createDirectory(at: mod, withIntermediateDirectories: true)
        try? Data("Hub check mod\nA folder test.".utf8).write(to: mod.appendingPathComponent("description.txt"))
        engine.loadMods()
        let before = engine.mods.count
        engine.installMod(from: mod)
        note("mod from folder: \(before) -> \(engine.mods.count), \(engine.statusMessage)")
        if let added = engine.mods.first(where: { $0.folderName == "HubCheckMod" }) {
            engine.removeMod(added)
            note("mod removed: \(engine.mods.count), \(engine.statusMessage)")
        }
        let zip = scratch.appendingPathComponent("HubCheckZip.zip")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pack.arguments = ["-c", "-k", "--keepParent", mod.path, zip.path]
        try? pack.run()
        pack.waitUntilExit()
        engine.installMod(from: zip)
        note("mod from zip: \(engine.mods.count), \(engine.statusMessage)")
        if let added = engine.mods.first(where: { $0.folderName == "HubCheckMod" }) { engine.removeMod(added) }
        let empty = scratch.appendingPathComponent("NotAMod")
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        engine.installMod(from: empty)
        note("folder without description.txt: \(engine.statusMessage)")
        try? fm.removeItem(at: scratch)
    }

    /// With a hidden test game already running: every control that reaches the game, ending with the game quitting under the hub.
    private static func liveChecks(_ hub: HubModel) async {
        let engine = hub.engine
        func wait(_ what: String, seconds: Double = 90, _ test: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if test() { note("ok: \(what)"); return true }
                await settle(0.3)
            }
            note("FAIL: \(what)")
            return false
        }
        guard await wait("hub sees the running game", { engine.isGameRunning }) else { return }
        hub.section = .play
        guard await wait("game answers hubstate", { engine.liveHubState != nil }) else { return }
        await settle(0.5)
        picture("live-play")
        if let cheat = engine.liveHubState?.cheats.first(where: { $0.var == "cheat_golden_shot" }) {
            engine.setCheat(cheat, on: true)
            _ = await wait("cheat on is reported back", seconds: 20) { engine.liveHubState?.cheats.first { $0.var == cheat.var }?.on == true }
            if let now = engine.liveHubState?.cheats.first(where: { $0.var == cheat.var }) {
                engine.setCheat(now, on: false)
                _ = await wait("cheat off is reported back", seconds: 20) { engine.liveHubState?.cheats.first { $0.var == cheat.var }?.on == false }
            }
        }
        let start = engine.liveHubState?.graphics
        engine.setGraphics(original: start != "Original")
        _ = await wait("graphics switch is reported back", seconds: 30) { engine.liveHubState?.graphics != start }
        engine.setGraphics(original: start == "Original")
        _ = await wait("graphics back as they were", seconds: 30) { engine.liveHubState?.graphics == start }
        if await wait("a mission reports the squad", seconds: 120, { engine.liveSquad != nil }) {
            hub.section = .squad
            await settle(1.5)
            picture("live-squad")
            note("squad: \(engine.liveSquad?.squad.map { "\($0.name) \($0.hp)/\($0.maxHP)" }.joined(separator: ", ") ?? ""); enemies seen \(engine.liveSquad?.enemies.count ?? 0)")
            hub.section = .advisor
            await hub.advisor.ask("How is my squad?", library: hub.store.library, squad: engine.liveSquad)
            await settle(0.8)
            picture("live-advisor")
            note("advisor saw squad: \(hub.advisor.messages.last?.sources.contains("Current squad:") ?? false || hub.advisor.messages.last?.text.contains("Current squad") ?? false)")
            hub.section = .squad
        }
        let before = engine.saves.count
        engine.saveGame(named: "Hub check save")
        await settle(6)
        engine.loadSaves()
        note("save: slots \(before) -> \(engine.saves.count), newest \(engine.saves.first?.slotName ?? "")")
        engine.send("quit")
        _ = await wait("hub sees the game quit", seconds: 60) { !engine.isGameRunning }
        await settle(3)
        picture("live-after-quit")
        note("hub alive after the game quit, status: \(engine.statusMessage)")
        await fileChecks(engine)
        note("DONE")
    }
}
