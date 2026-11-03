import SwiftUI
import OpenStormCore

struct PeopleView: View {
    @ObservedObject var hub: HubModel
    let library: GameLibrary
    @State private var search = ""
    @State private var kind: CharacterKind? = .hire
    @State private var faction = "All"
    @State private var showModel = true

    private var factions: [String] {
        ["All"] + Set(library.characters.filter { kind == nil || $0.kind == kind }.map(\.faction)).sorted()
    }

    private var filtered: [GameCharacter] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return library.characters.filter { c in
            if q.isEmpty {
                if let kind, c.kind != kind { return false }
            } else if !(c.name.lowercased().contains(q) || c.longName.lowercased().contains(q) || c.devName.lowercased().contains(q) || c.className.lowercased().contains(q)) {
                return false
            }
            return faction == "All" || c.faction == faction
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Search all \(library.characters.count) people", text: $search)
                Picker("Group", selection: $kind) {
                    Text("Everyone (\(library.characters.count))").tag(CharacterKind?.none)
                    ForEach(CharacterKind.allCases) { k in
                        Text("\(k.rawValue) (\(library.characters.filter { $0.kind == k }.count))").tag(Optional(k))
                    }
                }
                .labelsHidden()
                Picker("Faction", selection: $faction) {
                    ForEach(factions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Text("\(filtered.count) shown").font(.system(size: 10.5)).foregroundStyle(.secondary)
                List(filtered, selection: $hub.personID) { c in
                    HStack(spacing: 8) {
                        if c.photoTextureID != 0 {
                            GameImage(store: hub.store, textureID: c.photoTextureID, contentMode: .fill)
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text("\(c.className), \(c.faction)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if c.lineCount > 0 { Text("\(c.lineCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                    .tag(c.id)
                }
                .listStyle(.sidebar)
            }
            .padding(8)
            .frame(minWidth: 280, maxWidth: 340)

            if let id = hub.personID, let person = library.charactersByID[id] {
                PersonDetail(hub: hub, library: library, person: person).id(person.id)
            } else {
                ContentUnavailableView("Choose someone", systemImage: "person.3", description: Text("Stats, perks, gear, voice lines and where they appear."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: kind) { _, _ in faction = "All" }
        .task {
            if hub.personID == nil { hub.personID = filtered.first?.id }
        }
    }
}

struct PersonDetail: View {
    @ObservedObject var hub: HubModel
    let library: GameLibrary
    let person: GameCharacter
    @State private var trigger = "All"

    private var lines: [VoiceLine] { library.linesByOwner[person.voiceOwnerID] ?? [] }
    private var triggers: [String] { ["All"] + Set(lines.flatMap { $0.triggers + $0.dialogs.map { "Scene: \($0)" } }).sorted() }
    private var shownLines: [VoiceLine] {
        trigger == "All" ? lines : lines.filter { $0.triggers.contains(trigger) || $0.dialogs.contains { "Scene: \($0)" == trigger } }
    }
    private var cls: ClassInfo? { library.classes.first { $0.id == person.classID } }
    private var treePerks: [PerkNode] { library.perkNodes.filter { $0.treeID == person.perkTreeID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    if person.photoTextureID != 0 {
                        GameImage(store: hub.store, textureID: person.photoTextureID)
                            .frame(width: 150, height: 190)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    if let visual = person.visual {
                        VStack(spacing: 3) {
                            ModelPreview(store: hub.store, engine: hub.engine, visual: visual)
                                .frame(width: 230, height: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Body mesh only. The game adds the head and limbs when it runs.").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 230)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(person.longName.isEmpty ? person.name : person.longName)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .textSelection(.enabled)
                        HStack(spacing: 5) {
                            Tag(person.kind.rawValue, color: .accentColor)
                            Tag(person.className, color: .mint)
                            Tag(person.faction)
                            if !person.nationality.isEmpty { Tag(person.nationality) }
                            Tag(person.isFemale ? "Female" : "Male")
                        }
                        if person.cost > 0 { Text("Hire cost: \(person.cost)").font(.system(size: 12)) }
                        Text("In the database as \(person.devName), #\(person.id)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        HStack(spacing: 14) {
                            soundButton("Hit sounds", person.hitSoundIDs)
                            soundButton("Death sounds", person.deathSoundIDs)
                        }
                        if person.placements > 0 {
                            Text("Placed \(person.placements) times across the game's maps").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }

                if !person.stats.isEmpty {
                    DetailSection(title: "Starting attributes") {
                        ValueGrid(values: person.stats.filter { $0.value != "0" })
                        Text("Hit points, action points and skills come from these and level up in play. Live Squad shows the real numbers during a mission.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                if let cls {
                    DetailSection(title: "\(cls.name) class") {
                        ValueGrid(values: cls.growth)
                        if !cls.summary.isEmpty { Text(cls.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                if !person.perkIDs.isEmpty {
                    DetailSection(title: "Perks this character starts with") { perkList(person.perkIDs) }
                }
                if !treePerks.isEmpty {
                    DetailSection(title: "Perk tree") {
                        Button("Open the \(cls?.name ?? "class") tree (\(treePerks.count) perks)") {
                            hub.classID = person.classID
                            hub.section = .perks
                        }
                    }
                }
                if !person.loadout.isEmpty { loadoutSection }
                if !person.uniform.isEmpty || !person.panzerklein.isEmpty {
                    DetailSection(title: "Worn") {
                        if !person.uniform.isEmpty { Text("Uniform: \(person.uniform)").font(.system(size: 12)) }
                        if !person.panzerklein.isEmpty { Text("Panzerklein suit").font(.system(size: 12)) }
                    }
                }
                if !person.biography.isEmpty {
                    DetailSection(title: "Biography") { Text(person.biography).font(.system(size: 12)).textSelection(.enabled) }
                }
                if !person.profile.isEmpty {
                    DetailSection(title: "Service record") { Text(person.profile).font(.system(size: 12)).textSelection(.enabled) }
                }
                if !person.missions.isEmpty {
                    DetailSection(title: "Appears in \(person.missions.count) missions") {
                        Text(person.missions.joined(separator: ", ")).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
                voiceSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func soundButton(_ title: String, _ ids: [Int32]) -> some View {
        let clips = ids.filter { hub.store.sounds?.contains($0) == true }.map { PlayableClip(soundID: $0, title: "\(person.name): \(title)") }
        return Button {
            hub.player.playAll(clips)
        } label: {
            Label("\(title) (\(clips.count))", systemImage: "play.fill").font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .disabled(clips.isEmpty)
    }

    private func perkList(_ ids: [Int32]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ids, id: \.self) { id in
                if let perk = library.perks[id] {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(perk.name).font(.system(size: 12, weight: .semibold))
                        Text(perk.text.components(separatedBy: "\n").dropFirst().joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var loadoutSection: some View {
        DetailSection(title: "Starting gear") {
            let grouped = Dictionary(grouping: person.loadout, by: \.category)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(grouped.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(key).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(Set((grouped[key] ?? []).map { "\($0.name) x\($0.quantity)" }).sorted().joined(separator: ", "))
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var voiceSection: some View {
        DetailSection(title: "Voice lines (\(lines.count))") {
            if lines.isEmpty {
                Text("No voice lines of their own.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("When", selection: $trigger) {
                        ForEach(triggers, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 380)
                    Button("Play these (\(shownLines.count))") {
                        hub.player.playAll(shownLines.compactMap { VoiceRow.clip(for: $0, in: hub) })
                    }
                    Button("Open in Voices") { hub.openVoices(of: person.voiceOwnerID) }
                }
                if person.voiceOwnerID != person.id {
                    Text("Shares the voice set of \(library.charactersByID[person.voiceOwnerID]?.name ?? "another character").")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(shownLines) { VoiceRow(hub: hub, line: $0, showSpeaker: false) }
                }
            }
        }
    }
}

struct VoiceRow: View {
    @ObservedObject var hub: HubModel
    let line: VoiceLine
    var showSpeaker: Bool

    static func clip(for line: VoiceLine, in hub: HubModel, slot: Int = 0) -> PlayableClip? {
        guard slot < line.soundIDs.count, hub.store.sounds?.contains(line.soundIDs[slot]) == true else { return nil }
        return PlayableClip(soundID: line.soundIDs[slot], title: line.text.isEmpty ? line.source : line.text, subtitle: line.ownerName)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PlayButton(player: hub.player, clip: Self.clip(for: line, in: hub))
            VStack(alignment: .leading, spacing: 1) {
                Text(line.text.isEmpty ? "(no text)" : line.text).font(.system(size: 12)).textSelection(.enabled)
                HStack(spacing: 6) {
                    if showSpeaker { Text(line.ownerName).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.mint) }
                    Text((line.triggers + line.dialogs.map { "Scene: \($0)" }).joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !line.intonation.isEmpty { Text(line.intonation).font(.system(size: 10.5)).italic().foregroundStyle(.tertiary) }
                }
            }
        }
    }
}
