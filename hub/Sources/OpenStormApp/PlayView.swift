import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenStormCore

struct PlayView: View {
    @ObservedObject var hub: HubModel
    @ObservedObject var engine: EngineController
    @State private var command = ""
    @State private var saveName = "Hub save"

    private var running: Bool { engine.isGameRunning }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                liveControls
                savesSection
                modsSection
                if !engine.consoleLogText.isEmpty { consoleSection }
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .onAppear { engine.refreshEnvironment() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(engine.selectedEdition.rawValue).font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Every display, graphics, sound, camera and cheat setting is in the game: press ⌘, while it is open. They save themselves. In the game, F1 shows every key and F9 switches Original and Enhanced.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(engine.statusMessage).font(.system(size: 11, design: .monospaced)).foregroundStyle(.mint).textSelection(.enabled)
        }
    }

    private var liveControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if running {
                    if let state = engine.liveHubState {
                        HStack(spacing: 10) {
                            Text("Graphics").font(.system(size: 12, weight: .semibold))
                            Picker("Graphics", selection: Binding(get: { state.graphics }, set: { engine.setGraphics(original: $0 == "Original") })) {
                                Text("Original").tag("Original")
                                Text("Enhanced").tag("Enhanced")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 200)
                        }
                        if let speed = state.turnSpeed {
                            HStack(spacing: 10) {
                                Text("Enemy and ally turns").font(.system(size: 12, weight: .semibold))
                                Picker("Enemy and ally turns", selection: Binding(get: { speed }, set: { engine.setTurnSpeed($0) })) {
                                    ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 200)
                                Text("Same decisions, played faster. F2 in the game.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Text("Cheats").font(.system(size: 12, weight: .semibold))
                        Text("The same switches as the game's Cheats tab. They stay on until you turn them off.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(state.cheats) { cheat in
                                Toggle(isOn: Binding(get: { cheat.on }, set: { engine.setCheat(cheat, on: $0) })) {
                                    Text(cheat.title).font(.system(size: 12))
                                }
                                .help(cheat.detail)
                            }
                        }
                    } else {
                        Label("Waiting for the game to answer", systemImage: "hourglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        TextField("Console command, such as setxplevel 5", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(sendCommand)
                        Button("Send", action: sendCommand).disabled(command.isEmpty)
                    }
                } else {
                    Text("Open the game to use these: switch Original and Enhanced, flip cheats and send console commands while you play.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("While playing", systemImage: "dot.radiowaves.left.and.right")
        }
    }

    private func sendCommand() {
        engine.sendConsoleCommand(command)
        command = ""
    }

    private var savesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if running {
                        TextField("Save name", text: $saveName).textFieldStyle(.roundedBorder).frame(width: 180)
                        Button("Save now") { engine.saveGame(named: saveName); Task { try? await Task.sleep(for: .seconds(2)); engine.loadSaves() } }
                    }
                    Spacer()
                    Button("Back up all saves") { engine.backUpSaves() }
                    Button("Open save folder") { NSWorkspace.shared.open(engine.dataDirectory.appendingPathComponent("save")) }
                }
                if engine.saves.isEmpty {
                    Text("No saves yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(engine.saves) { save in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(save.slotName).font(.system(size: 12.5, weight: .semibold))
                            Text("\(save.modifiedDate.formatted(date: .abbreviated, time: .shortened)), \(save.fileSize / 1024) KB")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(running ? "Load" : "Open game and load") {
                            if running { engine.loadGame(named: save.slotName) } else { engine.launchGame(loadingSlot: save.slotName) }
                        }
                        .disabled(running && engine.runningEdition != engine.selectedEdition)
                    }
                    Divider()
                }
            }
            .padding(6)
        } label: {
            Label("Saves (\(engine.saves.count))", systemImage: "externaldrive")
        }
    }

    private var modsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Mods listed here appear in the game under Custom Game, which is where you turn them on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add mod") { addMod() }
                }
                ForEach(engine.mods) { mod in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mod.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text(mod.folderName + (mod.hasDatabase ? ", changes game data" : "")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show") { NSWorkspace.shared.open(mod.path) }
                        Button("Move to Trash") { engine.removeMod(mod) }
                    }
                    Divider()
                }
            }
            .padding(6)
        } label: {
            Label("Mods (\(engine.mods.count))", systemImage: "puzzlepiece.extension")
        }
    }

    private func addMod() {
        let panel = NSOpenPanel()
        panel.title = "Choose a mod folder or .zip"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        if panel.runModal() == .OK, let url = panel.url { engine.installMod(from: url) }
    }

    private var consoleSection: some View {
        GroupBox {
            ScrollView {
                Text(engine.consoleLogText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 170)
        } label: {
            Label("Console log", systemImage: "terminal")
        }
    }
}
