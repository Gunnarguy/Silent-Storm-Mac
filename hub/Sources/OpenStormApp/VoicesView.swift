import SwiftUI
import OpenStormCore

struct VoicesView: View {
    @ObservedObject var hub: HubModel
    let library: GameLibrary
    @State private var search = ""
    @State private var speakerSearch = ""
    @State private var kind = "Everything"

    private struct Speaker: Identifiable {
        let id: Int32
        let name: String
        let count: Int
    }

    private var speakers: [Speaker] {
        let q = speakerSearch.lowercased()
        return library.linesByOwner.map { Speaker(id: $0.key, name: library.charactersByID[$0.key]?.name ?? "Persona \($0.key)", count: $0.value.count) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filtered: [VoiceLine] {
        var base = hub.voiceOwnerID.flatMap { library.linesByOwner[$0] } ?? library.lines
        switch kind {
        case "Combat and reactions": base = base.filter { !$0.triggers.isEmpty }
        case "Story scenes": base = base.filter { !$0.dialogs.isEmpty }
        case "Unused or scripted": base = base.filter { $0.triggers.isEmpty && $0.dialogs.isEmpty }
        default: break
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.text.lowercased().contains(q) || $0.ownerName.lowercased().contains(q) || $0.triggers.contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Find a speaker", text: $speakerSearch)
                List(selection: $hub.voiceOwnerID) {
                    ForEach(speakers) { s in
                        HStack {
                            Text(s.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text("\(s.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .tag(s.id)
                    }
                }
                .listStyle(.sidebar)
                if hub.voiceOwnerID != nil {
                    Button("Show every speaker") { hub.voiceOwnerID = nil }
                }
            }
            .padding(8)
            .frame(minWidth: 210, maxWidth: 270)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SearchField(prompt: "Search what they say, or when", text: $search)
                    Picker("Kind", selection: $kind) {
                        ForEach(["Everything", "Combat and reactions", "Story scenes", "Unused or scripted"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    Button("Play all") { hub.player.playAll(filtered.prefix(500).compactMap { VoiceRow.clip(for: $0, in: hub) }) }
                }
                Text("\(filtered.count) of \(library.lines.count) lines").font(.system(size: 10.5)).foregroundStyle(.secondary)
                List(filtered, selection: $hub.lineID) { line in
                    VoiceRow(hub: hub, line: line, showSpeaker: true).tag(line.id)
                }
                .listStyle(.inset)
            }
            .padding(8)
            .frame(minWidth: 460)

            if let id = hub.lineID, let line = library.lines.first(where: { $0.id == id }) {
                lineDetail(line).frame(minWidth: 260, maxWidth: 320)
            }
        }
    }

    private func lineDetail(_ line: VoiceLine) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(line.text).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                if !line.femaleText.isEmpty && line.femaleText != line.text {
                    DetailSection(title: "Female wording") { Text(line.femaleText).font(.system(size: 12)).textSelection(.enabled) }
                }
                DetailSection(title: "Speaker") {
                    Button(line.ownerName) { hub.openPerson(line.ownerID) }
                    let users = library.characters.filter { $0.voiceOwnerID == line.ownerID && $0.id != line.ownerID }
                    if !users.isEmpty { Text("Also spoken by \(users.count) others who share this voice set").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                DetailSection(title: "Recordings (\(line.soundIDs.count))") {
                    ForEach(Array(line.soundIDs.enumerated()), id: \.offset) { slot, _ in
                        HStack {
                            PlayButton(player: hub.player, clip: VoiceRow.clip(for: line, in: hub, slot: slot))
                            Text(line.soundIDs.count > 1 ? "Hero voice \(slot + 1)" : "Clip \(line.soundIDs[slot])").font(.system(size: 12))
                            if VoiceRow.clip(for: line, in: hub, slot: slot) == nil {
                                Text("Not in the game files").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !line.triggers.isEmpty {
                    DetailSection(title: "Said when") { ForEach(line.triggers, id: \.self) { Text($0).font(.system(size: 12)) } }
                }
                if !line.dialogs.isEmpty {
                    DetailSection(title: "Story scene") { ForEach(line.dialogs, id: \.self) { Text($0).font(.system(size: 12)) } }
                }
                DetailSection(title: "Delivery") {
                    ValueGrid(values: [NamedValue("Tone", line.intonation), NamedValue("Face", line.expression)].filter { !$0.value.isEmpty })
                }
                Text(line.source).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
