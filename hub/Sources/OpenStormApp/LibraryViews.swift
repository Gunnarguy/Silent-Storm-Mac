import SwiftUI
import OpenStormCore

struct ArsenalView: View {
    @ObservedObject var hub: HubModel
    let library: GameLibrary
    @State private var search = ""
    @State private var category = "Guns"
    @State private var type = ""

    private var categories: [(name: String, count: Int)] {
        ChipBar.counted(library.arsenal.map(\.category)).sorted { $0.name < $1.name }
    }

    /// Guns, grenades and melee weapons carry their weapon type (Pistol, Rifle...), the second level of the organizer.
    private func typeOf(_ item: ArsenalItem) -> String? {
        guard let t = item.values.first(where: { $0.name == "Type" })?.value, !t.isEmpty else { return nil }
        return t
    }

    private var types: [(name: String, count: Int)] { ChipBar.counted(library.arsenal.filter { $0.category == category }.compactMap(typeOf)) }

    private var filtered: [ArsenalItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return library.arsenal.filter { item in
            q.isEmpty ? item.category == category && (type.isEmpty || typeOf(item) == type)
                : (item.name.lowercased().contains(q) || item.devName.lowercased().contains(q))
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Search all \(library.arsenal.count) items", text: $search)
                ChipBar(items: categories, selection: $category, allTitle: nil)
                if types.count > 1 {
                    Divider()
                    ChipBar(items: types, selection: $type, allTitle: "All types")
                }
                List(filtered, selection: $hub.itemID) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(item.values.first?.value ?? item.category).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(item.id)
                }
                .listStyle(.sidebar)
            }
            .padding(8)
            .frame(minWidth: 270, maxWidth: 330)

            if let id = hub.itemID, let item = library.arsenal.first(where: { $0.id == id }) {
                itemDetail(item).id(item.id)
            } else {
                ContentUnavailableView("Choose an item", systemImage: "shield.lefthalf.filled", description: Text("Numbers, sounds, the 3D model and who starts with it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if let id = hub.itemID, let item = library.arsenal.first(where: { $0.id == id }) { category = item.category }
            else { hub.itemID = filtered.first?.id }
        }
        .onChange(of: category) { type = "" }
    }

    private func itemDetail(_ item: ArsenalItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    if let visual = item.visual {
                        ModelPreview(store: hub.store, engine: hub.engine, visual: visual)
                            .frame(width: 280, height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.system(size: 21, weight: .bold, design: .rounded)).textSelection(.enabled)
                        Tag(item.category, color: .accentColor)
                        Text("In the database as \(item.devName), #\(item.recordID)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        HStack(spacing: 14) {
                            if hub.store.sounds?.contains(item.soundID) == true {
                                HStack(spacing: 4) {
                                    PlayButton(player: hub.player, clip: PlayableClip(soundID: item.soundID, title: "\(item.name): sound"))
                                    Text("Sound").font(.system(size: 11))
                                }
                            }
                            if hub.store.sounds?.contains(item.reloadSoundID) == true {
                                HStack(spacing: 4) {
                                    PlayButton(player: hub.player, clip: PlayableClip(soundID: item.reloadSoundID, title: "\(item.name): reload"))
                                    Text("Reload").font(.system(size: 11))
                                }
                            }
                        }
                    }
                }
                if !item.values.isEmpty { DetailSection(title: "Numbers") { ValueGrid(values: item.values) } }
                if !item.summary.isEmpty { DetailSection(title: "In-game description") { Text(item.summary).font(.system(size: 12)).textSelection(.enabled) } }
                if !item.carriedByIDs.isEmpty {
                    DetailSection(title: "Starting gear of \(item.carriedByIDs.count) people") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 3) {
                            ForEach(item.carriedByIDs, id: \.self) { id in
                                Button(library.charactersByID[id]?.name ?? "Persona \(id)") { hub.openPerson(id) }.buttonStyle(.link).font(.system(size: 12)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PerksView: View {
    @ObservedObject var hub: HubModel
    let library: GameLibrary

    private var playable: [ClassInfo] { library.classes.filter { c in library.perkNodes.contains { $0.treeID == c.perkTreeID } } }

    /// Perks in rows by how many perks must come first.
    private func tiers(_ cls: ClassInfo) -> [[PerkNode]] {
        let nodes = library.perkNodes.filter { $0.treeID == cls.perkTreeID }
        let byPerk = Dictionary(nodes.map { ($0.perkID, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [Int32: Int] = [:]
        func depth(_ n: PerkNode, _ guardCount: Int = 0) -> Int {
            if let d = memo[n.perkID] { return d }
            guard guardCount < 32 else { return 0 }
            let d = n.parentPerkIDs.compactMap { byPerk[$0] }.map { depth($0, guardCount + 1) + 1 }.max() ?? 0
            memo[n.perkID] = d
            return d
        }
        let grouped = Dictionary(grouping: nodes, by: { depth($0) })
        return grouped.keys.sorted().map { grouped[$0] ?? [] }
    }

    var body: some View {
        HSplitView {
            List(playable, selection: $hub.classID) { c in
                Text(c.name).font(.system(size: 12.5, weight: .medium)).tag(c.id)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, maxWidth: 210)

            if let id = hub.classID, let cls = library.classes.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(cls.name).font(.system(size: 22, weight: .bold, design: .rounded))
                        if !cls.summary.isEmpty { Text(cls.summary).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                        DetailSection(title: "Class ratings") { ValueGrid(values: cls.growth) }
                        ForEach(Array(tiers(cls).enumerated()), id: \.offset) { tier, nodes in
                            DetailSection(title: tier == 0 ? "First perks" : "Needs \(tier) before it") {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .topLeading)], alignment: .leading, spacing: 8) {
                                    ForEach(nodes) { node in perkCard(node) }
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Choose a class", systemImage: "star.circle").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if hub.classID == nil { hub.classID = playable.first?.id } }
    }

    private func perkCard(_ node: PerkNode) -> some View {
        let perk = library.perks[node.perkID]
        return HStack(alignment: .top, spacing: 8) {
            if let icon = perk?.iconTextureID, icon != 0 {
                GameImage(store: hub.store, textureID: icon).frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(perk?.name ?? "Perk \(node.perkID)").font(.system(size: 12.5, weight: .semibold))
                Text((perk?.text ?? "").components(separatedBy: "\n").dropFirst().joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.secondary)
                let needs = node.parentPerkIDs.compactMap { library.perks[$0]?.name }
                if !needs.isEmpty { Text("Needs \(needs.joined(separator: ", "))").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct MissionsView: View {
    @ObservedObject var hub: HubModel
    let library: GameLibrary
    @State private var search = ""

    private var filtered: [MissionInfo] {
        let q = search.lowercased()
        return library.missions.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.devName.lowercased().contains(q) || $0.scenario.lowercased().contains(q) }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Search \(library.missions.count) missions", text: $search)
                List(filtered, selection: $hub.missionID) { m in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text([m.scenario, m.timeOfDay].filter { !$0.isEmpty }.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .tag(m.id)
                }
                .listStyle(.sidebar)
            }
            .padding(8)
            .frame(minWidth: 280, maxWidth: 340)

            if let id = hub.missionID, let m = library.missions.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(m.name).font(.system(size: 21, weight: .bold, design: .rounded)).textSelection(.enabled)
                        HStack(spacing: 5) {
                            if !m.scenario.isEmpty { Tag(m.scenario, color: .accentColor) }
                            if !m.timeOfDay.isEmpty { Tag(m.timeOfDay) }
                        }
                        Text("\(m.unitCount > 0 ? "\(m.unitCount) units placed on this map. " : "")Zone \(m.devName), #\(m.id).").font(.system(size: 11)).foregroundStyle(.secondary)
                        DetailSection(title: "Enemies placed here") {
                            if m.enemyRoster.isEmpty {
                                Text("None placed in the map data. Scripts may still spawn them.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach(m.enemyRoster) { row in
                                HStack {
                                    Text("\(row.value) x").font(.system(size: 11, design: .monospaced)).frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
                                    Text(row.name).font(.system(size: 12))
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Choose a mission", systemImage: "map").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if hub.missionID == nil { hub.missionID = (filtered.first { !$0.enemyRoster.isEmpty } ?? filtered.first)?.id } }
    }
}

struct SoundsView: View {
    @ObservedObject var hub: HubModel
    let library: GameLibrary
    @State private var search = ""
    @State private var folder = ""
    @State private var music: [URL] = []

    private var folders: [(name: String, count: Int)] { ChipBar.counted(library.sounds.compactMap(\.folder)) }

    private var filtered: [SoundInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return library.sounds.filter { s in
            (folder.isEmpty || s.folder == folder) && (q.isEmpty || s.name.lowercased().contains(q) || s.source.lowercased().contains(q) || String(s.id) == q)
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Search \(library.sounds.count) sound records", text: $search)
                ChipBar(items: folders, selection: $folder)
                Text("\(filtered.count) shown").font(.system(size: 10.5)).foregroundStyle(.secondary)
                List(filtered.prefix(1500)) { s in
                    HStack(spacing: 8) {
                        let exists = hub.store.sounds?.contains(s.id) ?? false
                        PlayButton(player: hub.player, clip: exists ? PlayableClip(soundID: s.id, title: s.name, subtitle: s.source) : nil)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.name).font(.system(size: 12)).lineLimit(1)
                            Text(s.source).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .listStyle(.inset)
            }
            .padding(8)
            .frame(minWidth: 520)

            VStack(alignment: .leading, spacing: 8) {
                Text("MUSIC (\(music.count))").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                List(music, id: \.path) { url in
                    HStack(spacing: 8) {
                        PlayButton(player: hub.player, clip: PlayableClip(file: url))
                        Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(1)
                    }
                }
                .listStyle(.inset)
            }
            .padding(8)
            .frame(minWidth: 240, maxWidth: 320)
        }
        .task(id: library.location.dataDirectory) { music = MusicFolder.files(library.location) }
    }
}

enum MusicFolder {
    static func files(_ location: GameDataLocation) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for dir in location.musicDirectories {
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where ["ogg", "mp3", "wav"].contains(url.pathExtension.lowercased()) {
                if seen.insert(url.lastPathComponent.lowercased()).inserted { out.append(url) }
            }
        }
        return out.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}
