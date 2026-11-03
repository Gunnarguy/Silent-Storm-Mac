import Foundation

/// A labelled number or text shown in the explorer.
public struct NamedValue: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public enum CharacterKind: String, CaseIterable, Sendable, Identifiable {
    case hire = "Squad & hires"
    case hero = "Hero presets"
    case enemy = "Enemies"
    case panzerklein = "Panzerkleins"
    case neutral = "Allies & civilians"
    case scripted = "Scripted & unplaced"
    case voiceSet = "Voice sets"
    public var id: String { rawValue }
}

public struct LoadoutEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(category)-\(itemID)-\(difficulty)" }
    public let category: String
    public let itemID: Int32
    public let name: String
    public let quantity: Int
    public let difficulty: Int
}

public struct GameCharacter: Sendable, Identifiable {
    public let id: Int32
    public let devName: String
    public let name: String
    public let longName: String
    public let className: String
    public let classID: Int32
    public let kind: CharacterKind
    public let faction: String
    public let nationality: String
    public let isFemale: Bool
    public let biography: String
    public let profile: String
    public let photoTextureID: Int32
    public let stats: [NamedValue]
    public let loadout: [LoadoutEntry]
    public let uniform: String
    public let panzerklein: String
    public let voiceOwnerID: Int32
    public let lineCount: Int
    /// Variations the game picks between.
    public let deathSoundIDs: [Int32]
    public let hitSoundIDs: [Int32]
    public let cost: Int
    public let placements: Int
    public let missions: [String]
    public let perkIDs: [Int32]
    public let perkTreeID: Int32
    public let visual: ModelVisual?
}

/// A 3D model and the texture on it, as IDs into Geometries.res and Textures.res.
public struct ModelVisual: Sendable, Hashable {
    public let geometryID: Int32
    public let textureID: Int32
    public init(geometryID: Int32, textureID: Int32) {
        self.geometryID = geometryID
        self.textureID = textureID
    }
}

public struct VoiceLine: Sendable, Identifiable {
    public let id: Int32
    public let ownerID: Int32
    public let ownerName: String
    public let text: String
    public let femaleText: String
    public let intonation: String
    public let expression: String
    /// One clip per voice slot. Most lines have one; hero lines have up to six.
    public let soundIDs: [Int32]
    public let triggers: [String]
    public let dialogs: [String]
    public let source: String
}

public struct ClassInfo: Sendable, Identifiable {
    public let id: Int32
    public let name: String
    public let summary: String
    public let growth: [NamedValue]
    public let perkTreeID: Int32
}

public struct PerkInfo: Sendable, Identifiable {
    public let id: Int32
    public let name: String
    public let text: String
    public let parameters: [NamedValue]
    public let iconTextureID: Int32
}

public struct PerkNode: Sendable, Identifiable {
    public let id: Int32
    public let treeID: Int32
    public let perkID: Int32
    public let parentPerkIDs: [Int32]
}

public struct ArsenalItem: Sendable, Identifiable {
    public var id: String { "\(category)-\(recordID)" }
    public let recordID: Int32
    public let category: String
    public let name: String
    public let devName: String
    public let summary: String
    public let values: [NamedValue]
    public let soundID: Int32
    public let reloadSoundID: Int32
    public let visual: ModelVisual?
    public let carriedByIDs: [Int32]
}

public struct MissionInfo: Sendable, Identifiable {
    public let id: Int32
    public let name: String
    public let devName: String
    public let scenario: String
    public let timeOfDay: String
    public let description: String
    public let unitCount: Int
    public let enemyRoster: [NamedValue]
    public let templateIDs: [Int32]
}

public struct SoundInfo: Sendable, Identifiable {
    public let id: Int32
    public let name: String
    public let source: String
    /// The first folder under Sounds in the original source path: Acks, Dialogs, Weapon and so on.
    public var folder: String? {
        let parts = source.split(separator: "\\")
        return parts.count > 2 ? String(parts[1]) : nil
    }
}

/// Reads an archive the way the native engine does: the game's `res/<name>.res`.
public final class ResourceSet: Sendable {
    public let readers: [ResPackageReader]
    /// Folders of loose files named by ID, which win over the archives: `res/sounds/<id>`, `hd/Textures/<id>`.
    public let looseDirectories: [URL]

    public init(urls: [URL], looseDirectories: [URL] = []) {
        readers = urls.compactMap { try? ResPackageReader(fileURL: $0) }
        self.looseDirectories = looseDirectories
    }

    public var entryCount: Int { readers.reduce(0) { $0 + $1.entries.count } }

    public var allIDs: [Int32] {
        Set(readers.flatMap { $0.entries.keys }).map { Int32(truncatingIfNeeded: $0) }.sorted()
    }

    public func contains(_ id: Int32) -> Bool {
        guard id > 0 else { return false }
        return readers.contains { $0.entries[UInt32(id)] != nil } || looseDirectories.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(String(id)).path) }
    }

    public func data(id: Int32) -> Data? {
        guard id > 0 else { return nil }
        for dir in looseDirectories {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(String(id))) { return d }
        }
        for reader in readers where reader.entries[UInt32(id)] != nil {
            if let d = try? reader.readEntryData(id: UInt32(id)) { return d }
        }
        return nil
    }
}

/// Where one game's data lives.
public struct GameDataLocation: Sendable {
    public let dataDirectory: URL
    public let databaseFileName: String

    public init(dataDirectory: URL, databaseFileName: String) {
        self.dataDirectory = dataDirectory
        self.databaseFileName = databaseFileName
    }

    public func archiveURLs(_ name: String) -> [URL] {
        [dataDirectory.appendingPathComponent("res/\(name).res")]
    }

    public func sounds() -> ResourceSet {
        ResourceSet(urls: archiveURLs("Sounds"), looseDirectories: [dataDirectory.appendingPathComponent("res/sounds")])
    }
    public func textures() -> ResourceSet { ResourceSet(urls: archiveURLs("Textures")) }
    public func geometries() -> ResourceSet { ResourceSet(urls: archiveURLs("Geometries")) }
    /// The HD texture pack. Files are named by texture ID and hold the same format as Textures.res.
    public var hdTextureDirectory: URL { dataDirectory.appendingPathComponent("hd/Textures") }
    public var musicDirectories: [URL] { [dataDirectory.appendingPathComponent("res/Music")] }
}

extension DecodedMMPTexture {
    /// The same picture with its rows reversed, for textures stored bottom-up.
    public func flippedVertically() -> DecodedMMPTexture {
        let row = header.width * 4
        var out = [UInt8](repeating: 0, count: rgbaPixels.count)
        for y in 0..<header.height {
            let from = y * row, to = (header.height - 1 - y) * row
            guard from + row <= rgbaPixels.count, to + row <= out.count else { continue }
            out.replaceSubrange(to..<(to + row), with: rgbaPixels[from..<(from + row)])
        }
        return DecodedMMPTexture(header: header, rgbaPixels: out)
    }
}

/// Everything the explorer shows, joined from one game's database. Read-only: it never writes to the game's files.
public struct GameLibrary: Sendable {
    public let location: GameDataLocation
    public let characters: [GameCharacter]
    public let lines: [VoiceLine]
    public let classes: [ClassInfo]
    public let perks: [Int32: PerkInfo]
    public let perkNodes: [PerkNode]
    public let arsenal: [ArsenalItem]
    public let missions: [MissionInfo]
    public let sounds: [SoundInfo]
    public let linesByOwner: [Int32: [VoiceLine]]
    public let charactersByID: [Int32: GameCharacter]
    public let textureNames: [Int32: String]
    public let geometryNames: [Int32: String]
    /// The first texture the database puts on each mesh.
    public let geometryTextures: [Int32: Int32]
    /// RPGItems ID to the name the player sees.
    public let itemNames: [Int32: String]
    /// Textures the interface draws (portraits, icons, paper). They are stored bottom-up, unlike fonts and world art.
    public let interfaceTextures: Set<Int32>

    /// Removes the engine's text markup, turning `<br>` into line breaks.
    public static func plainText(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\r", with: "")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func load(_ location: GameDataLocation) throws -> GameLibrary {
        let db = try NivalDatabaseReader(fileURL: location.dataDirectory.appendingPathComponent(location.databaseFileName))
        return Builder(db: db, location: location).build()
    }
}

private struct Builder {
    let db: NivalDatabaseReader
    let location: GameDataLocation

    func rows(_ name: String) -> [DBTableRow] {
        guard let t = db.tables.first(where: { $0.name == name }) else { return [] }
        return db.decodeTable(t).rows
    }

    func build() -> GameLibrary {
        var strings: [Int32: String] = [:]
        for r in rows("Strings") { strings[r.recordID] = r.values["String"] ?? "" }
        func text(_ row: DBTableRow, _ col: String) -> String {
            guard let id = Int32(row.values[col] ?? ""), id != 0 else { return "" }
            return GameLibrary.plainText(strings[id] ?? "")
        }
        func int(_ row: DBTableRow, _ col: String) -> Int32 { Int32(row.values[col] ?? "") ?? 0 }
        func plain(_ row: DBTableRow, _ col: String) -> String {
            let v = row.values[col] ?? ""
            guard v.contains("."), Float(v) != nil else { return v }
            var t = Substring(v)
            while t.hasSuffix("0") { t = t.dropLast() }
            return String(t.hasSuffix(".") ? t.dropLast() : t)
        }

        var soundVariants: [Int32: [Int32]] = [:]
        for r in rows("SoundVariants") { soundVariants[int(r, "TemplateID"), default: []].append(int(r, "SoundID")) }

        // Art links: a template's first model, that model's first material, the material's texture.
        let geometryRows = rows("Geometries")
        var geometryNames: [Int32: String] = [:]
        for r in geometryRows { geometryNames[r.recordID] = plain(r, "SrcName").isEmpty ? plain(r, "UserName") : plain(r, "SrcName") }
        let textureRows = rows("Textures")
        var textureNames: [Int32: String] = [:]
        for r in textureRows { textureNames[r.recordID] = plain(r, "SrcName").isEmpty ? plain(r, "UserName") : plain(r, "SrcName") }
        var materialByID: [Int32: Int32] = [:], materialByTemplate: [Int32: Int32] = [:]
        for r in rows("Materials") {
            let tex = int(r, "TextureID")
            materialByID[r.recordID] = tex
            let tpl = int(r, "TemplateID")
            if tpl != 0, materialByTemplate[tpl] == nil { materialByTemplate[tpl] = tex }
        }
        var modelsByTemplate: [Int32: DBTableRow] = [:], modelsByID: [Int32: DBTableRow] = [:]
        for r in rows("Models") {
            modelsByID[r.recordID] = r
            let tpl = int(r, "TemplateID")
            if tpl != 0, modelsByTemplate[tpl] == nil { modelsByTemplate[tpl] = r }
        }
        var geometryTextures: [Int32: Int32] = [:]
        for (_, m) in modelsByID {
            let geo = int(m, "GeometryID"), mat = int(m, "Material0")
            if geo != 0, geometryTextures[geo] == nil, let tex = materialByTemplate[mat] ?? materialByID[mat], tex != 0 { geometryTextures[geo] = tex }
        }
        func visual(modelID: Int32) -> ModelVisual? {
            guard modelID != 0, let m = modelsByTemplate[modelID] ?? modelsByID[modelID] else { return nil }
            let mat = int(m, "Material0")
            let tex = materialByTemplate[mat] ?? materialByID[mat] ?? 0
            let geo = int(m, "GeometryID")
            return geo == 0 ? nil : ModelVisual(geometryID: geo, textureID: tex)
        }

        // UI images resolve to a texture at the original interface resolution.
        var uiTexture: [Int32: Int32] = [:]
        var interfaceTextures: Set<Int32> = []
        for r in rows("UITextures") {
            let ids = r.values.keys.sorted().compactMap { $0.hasPrefix("R_") ? Int32(r.values[$0] ?? "") : nil }.filter { $0 != 0 }
            uiTexture[r.recordID] = ids.first ?? 0
            interfaceTextures.formUnion(ids)
        }

        let baseRows = Dictionary(rows("RPGBaseValues").map { ($0.recordID, $0) }, uniquingKeysWith: { a, _ in a })
        let classRows = rows("RPGClasses")
        let classByID = Dictionary(classRows.map { ($0.recordID, $0) }, uniquingKeysWith: { a, _ in a })
        let nationalities = Dictionary(rows("Nationalities").map { ($0.recordID, plain($0, "UserName")) }, uniquingKeysWith: { a, _ in a })
        let uniforms = Dictionary(rows("RPGUniforms").map { ($0.recordID, $0) }, uniquingKeysWith: { a, _ in a })
        let itemRows = rows("RPGItems")
        let items = Dictionary(itemRows.map { ($0.recordID, $0) }, uniquingKeysWith: { a, _ in a })
        func itemName(_ id: Int32) -> String {
            guard let r = items[id] else { return "" }
            let n = text(r, "NameID")
            return n.isEmpty ? plain(r, "UserName") : n
        }

        // Voices: AckInfos carry the line; Acks -> AckSeqs -> AckInfos say when it plays; DialogSeqs say which scene uses it.
        let personaRows = rows("RPGPers")
        var personaNames: [Int32: String] = [:]
        for r in personaRows {
            let n = text(r, "DisplayName")
            personaNames[r.recordID] = n.isEmpty ? plain(r, "UserName") : n
        }
        var conditionText: [Int32: String] = [:]
        for r in rows("AckConditions") {
            let c = plain(r, "Comment")
            conditionText[r.recordID] = c.isEmpty ? plain(r, "UserName") : c
        }
        var seqInfos: [Int32: [Int32]] = [:]
        for r in rows("AckSeqs") { seqInfos[r.recordID] = (0..<3).map { int(r, "AckID\($0)") }.filter { $0 != 0 } }
        var triggers: [Int32: Set<String>] = [:]
        for r in rows("Acks") {
            let cond = conditionText[int(r, "ConditionID")] ?? "Condition \(int(r, "ConditionID"))"
            for info in seqInfos[int(r, "AckSeqID")] ?? [] { triggers[info, default: []].insert(cond) }
        }
        var dialogNames: [Int32: String] = [:]
        for r in rows("Dialogs") {
            let u = plain(r, "UserName")
            dialogNames[r.recordID] = u.isEmpty ? plain(r, "SrcName") : u
        }
        var infoDialogs: [Int32: Set<String>] = [:]
        for r in rows("DialogSeqs") {
            if let name = dialogNames[int(r, "DialogID")] { infoDialogs[int(r, "AckInfoID"), default: []].insert(name) }
        }
        var lines: [VoiceLine] = []
        for r in rows("AckInfos") {
            let clips = ["SoundID", "SoundID1", "SoundID2", "SoundID3", "SoundID4", "SoundID5"].map { int(r, $0) }.filter { $0 != 0 }
            let owner = int(r, "WhoID")
            lines.append(VoiceLine(
                id: r.recordID, ownerID: owner, ownerName: personaNames[owner] ?? "Persona \(owner)",
                text: text(r, "StringID"), femaleText: text(r, "FemaleStringID"),
                intonation: plain(r, "IntonationID"), expression: plain(r, "FaceExpression"),
                soundIDs: clips, triggers: (triggers[r.recordID] ?? []).sorted(), dialogs: (infoDialogs[r.recordID] ?? []).sorted(),
                source: plain(r, "UserName")))
        }
        lines.sort { $0.ownerName == $1.ownerName ? $0.id < $1.id : $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName) == .orderedAscending }
        let linesByOwner = Dictionary(grouping: lines, by: \.ownerID)

        // Who starts with what.
        var loadouts: [Int32: [LoadoutEntry]] = [:]
        var carriers: [String: Set<Int32>] = [:]
        func addLoadout(_ table: String, _ category: String, resolve: (Int32) -> (String, Int32)) {
            for r in rows(table) {
                let pers = int(r, "RPGPersID")
                let ref = int(r, "RPGItemID")
                let (name, itemID) = resolve(ref)
                loadouts[pers, default: []].append(LoadoutEntry(category: category, itemID: itemID, name: name,
                                                                quantity: Int(int(r, "Quantity")), difficulty: Int(int(r, "DifficultyID"))))
                carriers["\(category)-\(ref)", default: []].insert(pers)
            }
        }
        func byItem(_ table: String) -> (Int32) -> (String, Int32) {
            let rowsByID = Dictionary(rows(table).map { ($0.recordID, $0) }, uniquingKeysWith: { a, _ in a })
            return { id in
                let item = rowsByID[id].map { int($0, "ItemID") } ?? id
                let n = itemName(item)
                return (n.isEmpty ? (rowsByID[id].map { plain($0, "UserName") } ?? "Item \(id)") : n, item)
            }
        }
        addLoadout("RPGWeapon4Pers", "Weapon", resolve: byItem("RPGWeapons"))
        addLoadout("RPGClip4Pers", "Ammo", resolve: byItem("RPGClips"))
        addLoadout("RPGGrenade4Pers", "Grenade", resolve: byItem("RPGGrenades"))
        addLoadout("RPGMeleeWeapon4Pers", "Melee", resolve: byItem("RPGMeleeWeapons"))
        addLoadout("RPGFirstAid4Pers", "First aid", resolve: byItem("RPGFirstAids"))
        addLoadout("RPGMines4Pers", "Mine", resolve: byItem("RPGMines"))
        addLoadout("RPGTool4Pers", "Tool", resolve: byItem("RPGTools"))
        addLoadout("RPGPicklocks4Pers", "Lockpick", resolve: byItem("RPGPicklocks"))
        addLoadout("RPGEngGrenade4Pers", "Engineer grenade", resolve: byItem("RPGEngGrenades"))

        // Where everyone is placed.
        var templateByVariant: [Int32: Int32] = [:]
        for r in rows("TemplVariants") { templateByVariant[r.recordID] = int(r, "TemplateID") }
        let scenarioRows = rows("Scenarios")
        var scenarioNames: [Int32: String] = [:]
        for r in scenarioRows { scenarioNames[r.recordID] = plain(r, "Name") }
        let zoneRows = rows("ScenarioZones")
        var zoneByTemplate: [Int32: DBTableRow] = [:]
        func zoneTemplates(_ r: DBTableRow) -> [Int32] {
            r.values.keys.filter { $0.hasPrefix("TemplateID") }.sorted().map { int(r, $0) }.filter { $0 != 0 }
        }
        for r in zoneRows { for t in zoneTemplates(r) { zoneByTemplate[t] = r } }
        func zoneName(_ r: DBTableRow) -> String {
            let n = text(r, "Name")
            return n.isEmpty ? plain(r, "UserName") : n
        }
        var placedCount: [Int32: Int] = [:], hostileCount: [Int32: Int] = [:]
        var persMissions: [Int32: Set<String>] = [:]
        var zoneRoster: [Int32: [Int32: Int]] = [:], zoneUnits: [Int32: Int] = [:]
        for r in rows("Units") {
            let who = int(r, "MonsterID")
            guard who != 0 else { continue }
            placedCount[who, default: 0] += 1
            let player = int(r, "Player")
            if player == 1 { hostileCount[who, default: 0] += 1 }
            if let tpl = templateByVariant[int(r, "VariantID")], let zone = zoneByTemplate[tpl] {
                persMissions[who, default: []].insert(zoneName(zone))
                zoneUnits[zone.recordID, default: 0] += 1
                if player == 1 { zoneRoster[zone.recordID, default: [:]][who, default: 0] += 1 }
            }
        }

        // Classes and perks.
        let classes: [ClassInfo] = classRows.map { r in
            ClassInfo(id: r.recordID, name: plain(r, "UserName").hasSuffix("UK") ? "\(Self.className(plain(r, "UserName"))) (British)" : plain(r, "UserName"),
                      summary: { (s: String) in s.contains(" ") ? s : "" }(text(r, "ToolTip").components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)),
                      growth: ["Melee", "Shooting", "Throwing", "Burst", "Snipe", "Stealth", "Spot", "Medicine", "Engineering",
                               "VP", "Interrupt", "AP", "IC"].map { NamedValue($0, plain(r, $0)) },
                      perkTreeID: int(r, "PerkTreeID"))
        }
        var perks: [Int32: PerkInfo] = [:]
        for r in rows("RPGPerks") {
            // The game fills these in when it shows a perk (SetPerkParam, Main/iCommonUI.cpp): points truncate; a percentage above 1 is a multiplier.
            var raw = strings[int(r, "ToolTip")] ?? ""
            for (i, word) in [(1, "one"), (2, "two")] {
                let value = Float(r.values["Param\(i)"] ?? "") ?? 0
                raw = raw.replacingOccurrences(of: "<value id=param\(word)point>", with: String(Int(value)))
                raw = raw.replacingOccurrences(of: "<value id=param\(word)perc>", with: String(Int(((value > 1 ? value - 1 : value) * 100).rounded())))
            }
            let tip = GameLibrary.plainText(raw)
            let title = tip.components(separatedBy: "\n").first ?? ""
            perks[r.recordID] = PerkInfo(id: r.recordID, name: title.isEmpty ? plain(r, "UserName") : title, text: tip,
                                         parameters: [], iconTextureID: uiTexture[int(r, "Icon")] ?? 0)
        }
        let perkNodes = rows("RPGPerkTreeNodes").map { r in
            PerkNode(id: r.recordID, treeID: int(r, "PerkTreeID"), perkID: int(r, "PerkID"),
                     parentPerkIDs: (1...3).map { int(r, "ParentPerkID\($0)") }.filter { $0 != 0 })
        }
        var persPerks: [Int32: [Int32]] = [:]
        for r in rows("PerksToTake") { persPerks[int(r, "PersID"), default: []].append(int(r, "PerkID")) }

        // Sorting people into the groups the explorer shows.
        var heroIDs: Set<Int32> = []
        for r in rows("Sides") {
            for (k, v) in r.values where k.hasPrefix("Male") || k.hasPrefix("Female") { if let id = Int32(v), id != 0 { heroIDs.insert(id) } }
        }
        let voiceHolders = Set(personaRows.map { int($0, "AckUnit") }.filter { $0 != 0 })

        var characters: [GameCharacter] = []
        for r in personaRows {
            let id = r.recordID
            let classID = int(r, "ClassID")
            let display = text(r, "DisplayName")
            let placed = placedCount[id] ?? 0
            let isPanzer = int(r, "IsPanzerkleinID") != 0 || int(r, "WearingPanzerkleinID") != 0
            let kind: CharacterKind
            if int(r, "CanHired") == 1 { kind = .hire }
            else if heroIDs.contains(id) { kind = .hero }
            else if voiceHolders.contains(id) && placed == 0 { kind = .voiceSet }
            else if isPanzer { kind = .panzerklein }
            else if placed == 0 { kind = .scripted }
            else if (hostileCount[id] ?? 0) * 2 >= placed { kind = .enemy }
            else { kind = .neutral }

            var stats: [NamedValue] = []
            if let b = baseRows[int(r, "BaseValueID")] {
                stats = ["Lvl", "Str", "Dex", "Int", "XP", "VP", "AP", "IC", "Interrupt", "Melee", "Shooting", "Throwing", "Burst", "Snipe",
                         "Stealth", "Spot", "Medicine", "Engineering"].map { NamedValue($0, plain(b, $0)) }
            }
            let ownerID = int(r, "AckUnit") != 0 ? int(r, "AckUnit") : id
            var faction = plain(r, "Side")
            if faction.isEmpty || faction == "NPC" {
                let word = display.split(separator: " ").first.map { $0.replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "\\'s", with: "") } ?? ""
                faction = Self.factions.contains(word) ? word : (kind == .voiceSet ? "Voice set" : "Named or other")
            }
            let uniformID = int(r, "UniformID")
            let cls = classByID[classID]
            characters.append(GameCharacter(
                id: id, devName: plain(r, "UserName"), name: display.isEmpty ? plain(r, "UserName") : display,
                longName: text(r, "LongNameID"), className: cls.map { Self.className(plain($0, "UserName")) } ?? "Class \(classID)", classID: classID,
                kind: kind, faction: faction, nationality: nationalities[int(r, "NationalityID")] ?? "",
                isFemale: int(r, "IsFemale") != 0, biography: text(r, "BiographyID"), profile: text(r, "CharacteristicsID"),
                photoTextureID: uiTexture[int(r, "PhotoID")] ?? 0, stats: stats,
                loadout: (loadouts[id] ?? []).sorted { ($0.category, $0.name) < ($1.category, $1.name) },
                uniform: uniforms[uniformID].map { plain($0, "UserName") } ?? "",
                panzerklein: isPanzer ? (nonZero(int(r, "WearingPanzerkleinID")) ?? nonZero(int(r, "IsPanzerkleinID")) ?? "") : "",
                voiceOwnerID: ownerID, lineCount: linesByOwner[ownerID]?.count ?? 0,
                deathSoundIDs: soundVariants[int(r, "DeathSoundID")] ?? [], hitSoundIDs: soundVariants[int(r, "HitSoundID")] ?? [], cost: Int(int(r, "Cost")),
                placements: placed, missions: (persMissions[id] ?? []).sorted(), perkIDs: persPerks[id] ?? [],
                perkTreeID: cls.map { int($0, "PerkTreeID") } ?? 0, visual: visual(modelID: int(r, "ModelID"))))
        }
        characters.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // The arsenal.
        var arsenal: [ArsenalItem] = []
        func common(_ item: DBTableRow?) -> (String, String, [NamedValue], ModelVisual?) {
            guard let item else { return ("", "", [], nil) }
            var v: [NamedValue] = []
            if let w = Int(plain(item, "Weight")), w > 0 { v.append(NamedValue("Weight", "\(w) g")) }
            if int(item, "SizeX") > 0 { v.append(NamedValue("Inventory size", "\(int(item, "SizeX")) x \(int(item, "SizeY"))")) }
            if int(item, "Cost") > 0 { v.append(NamedValue("Cost", "\(int(item, "Cost"))")) }
            let d = text(item, "DescrID")
            return (itemName(item.recordID), d.isEmpty ? text(item, "TooltipID") : d, v, visual(modelID: int(item, "ModelID")))
        }
        func add(_ table: String, _ category: String, carrierKey: String?, build: (DBTableRow) -> [NamedValue], sound: (DBTableRow) -> (Int32, Int32) = { _ in (0, 0) }) {
            for r in rows(table) {
                let (name, summary, base, vis) = common(items[int(r, "ItemID")])
                let dev = plain(r, "UserName")
                arsenal.append(ArsenalItem(
                    recordID: r.recordID, category: category, name: name.isEmpty ? dev : name, devName: dev, summary: summary,
                    values: build(r).filter { !$0.value.isEmpty && $0.value != "0" } + base,
                    soundID: sound(r).0, reloadSoundID: sound(r).1, visual: vis,
                    carriedByIDs: carrierKey.map { (carriers["\($0)-\(r.recordID)"] ?? []).sorted() } ?? []))
            }
        }
        let clipRows = Dictionary(rows("RPGClips").map { ($0.recordID, $0) }, uniquingKeysWith: { a, _ in a })
        let weaponTypes = Dictionary(rows("RPGWeaponTypes").map { (r: DBTableRow) in (r.recordID, text(r, "NameID").isEmpty ? plain(r, "UserName") : text(r, "NameID")) }, uniquingKeysWith: { a, _ in a })
        add("RPGWeapons", "Guns", carrierKey: "Weapon", build: { r in
            var v = [NamedValue("Type", weaponTypes[int(r, "WeaponTypeID")] ?? ""),
                     NamedValue("Damage modifier", "\(plain(r, "DamageMod"))% to \(plain(r, "DamageModMax"))%"),
                     NamedValue("Range", "\(plain(r, "MinRange")) to \(plain(r, "MaxRange"))"),
                     NamedValue("Shot AP", plain(r, "ShotAP")), NamedValue("Reload AP", plain(r, "ReloadAP")),
                     NamedValue("Magazine", clipRows[int(r, "InnerClip")].map { "\(plain($0, "UserName")), \(plain($0, "Quantity")) rounds" } ?? ""),
                     NamedValue("Accuracy", plain(r, "Targeting")),
                     NamedValue("Recoil", plain(r, "Recoil")), NamedValue("Fire rate", plain(r, "BPM")),
                     NamedValue("Quality", plain(r, "Quality")), NamedValue("Bullet speed", plain(r, "InitialVelocity"))]
            let modes = ["SnapShot": "Snap", "AimedShot": "Aimed", "CarefulShot": "Careful", "SnipeShot": "Snipe", "ShortBurst": "Short burst",
                         "LongBurst": "Long burst", "FanFire": "Fan", "SuppressiveFire": "Suppressive"]
            let on = modes.keys.sorted().filter { plain(r, $0) == "1" }.map { modes[$0]! }
            v.append(NamedValue("Fire modes", on.joined(separator: ", ")))
            if int(r, "MaxDurability") > 0 { v.append(NamedValue("Durability", plain(r, "MaxDurability"))) }
            return v
        }, sound: { (int($0, "SoundID"), int($0, "ReloadSoundID")) })
        add("RPGMeleeWeapons", "Melee", carrierKey: "Melee", build: { r in
            [NamedValue("Damage", "\(plain(r, "DmgMin")) to \(plain(r, "DmgMax"))"), NamedValue("To-hit bonus", plain(r, "ToHitBonus")),
             NamedValue("Critical bonus", plain(r, "CriticalBonus")), NamedValue("AP", "\(plain(r, "MinAP")) to \(plain(r, "MaxAP"))")]
        })
        add("RPGGrenades", "Grenades", carrierKey: "Grenade", build: { r in
            [NamedValue("Blast damage", "\(plain(r, "WaveDmgMin")) to \(plain(r, "WaveDmgMax"))"), NamedValue("Blast radius", plain(r, "WaveRadius")),
             NamedValue("Fragments", plain(r, "FragmentNumber")), NamedValue("Fragment damage", "\(plain(r, "FragmentDmgMin")) to \(plain(r, "FragmentDmgMax"))"),
             NamedValue("Fragment range", plain(r, "FragmentRange")), NamedValue("Critical chance", plain(r, "CriticalProbability")), NamedValue("Fuse", plain(r, "MaxDelay"))]
        }, sound: { (soundVariants[int($0, "Sound1ID")]?.first ?? 0, 0) })
        add("RPGFirstAids", "First aid", carrierKey: "First aid", build: { r in
            [NamedValue("Heals", plain(r, "TotalHealVP")), NamedValue("Uses", plain(r, "Quantity")), NamedValue("Required skill", plain(r, "RequiredSkill")), NamedValue("AP", plain(r, "APToUse")), NamedValue("Effect", plain(r, "Effect"))]
        })
        add("RPGClips", "Magazines", carrierKey: "Ammo", build: { r in [NamedValue("Rounds", plain(r, "Quantity"))] })
        add("RPGMines", "Mines", carrierKey: "Mine", build: { _ in [] })
        add("RPGTools", "Tools", carrierKey: "Tool", build: { _ in [] })
        add("RPGUniforms", "Uniforms", carrierKey: nil, build: { r in [NamedValue("Group", plain(r, "UniformGroup"))] })
        for r in rows("RPGAmmos") {
            let n = text(r, "NameID")
            arsenal.append(ArsenalItem(recordID: r.recordID, category: "Ammunition", name: n.isEmpty ? plain(r, "UserName") : n, devName: plain(r, "UserName"), summary: "",
                                       values: [NamedValue("Damage", "\(plain(r, "DmgMin")) to \(plain(r, "DmgMax"))"), NamedValue("Calibre", plain(r, "Calibr")), NamedValue("Range modifier", plain(r, "RangeMod"))],
                                       soundID: 0, reloadSoundID: 0, visual: nil, carriedByIDs: []))
        }
        for r in rows("Panzerkleins") {
            let weapons = (1...10).filter { plain(r, "AllowWeaponType\($0)") == "1" }.compactMap { weaponTypes[Int32($0)] }
            arsenal.append(ArsenalItem(recordID: r.recordID, category: "Panzerklein suits", name: plain(r, "UserName"), devName: plain(r, "UserName"), summary: "",
                                       values: [NamedValue("VP", plain(r, "MaxVP")), NamedValue("Ricochet chance", plain(r, "RicochetProb")), NamedValue("Extra move AP", plain(r, "AddMoveAP")),
                                                NamedValue("Sensor range", plain(r, "SensorRange")), NamedValue("Regeneration", plain(r, "RegenerationValue")),
                                                NamedValue("Critical resist", plain(r, "CriticalResist")), NamedValue("Weapons", weapons.joined(separator: ", "))].filter { !$0.value.isEmpty && $0.value != "0" },
                                       soundID: soundVariants[int(r, "StepSoundID")]?.first ?? 0, reloadSoundID: 0, visual: nil,
                                       carriedByIDs: characters.filter { $0.panzerklein == String(r.recordID) }.map(\.id)))
        }
        for r in rows("Medals") {
            let n = text(r, "NameID")
            arsenal.append(ArsenalItem(recordID: r.recordID, category: "Medals", name: n.isEmpty ? plain(r, "UserName") : n, devName: plain(r, "UserName"), summary: "",
                                       values: [NamedValue("Points to start", plain(r, "PointsNeededToStart")), NamedValue("Starting chance", "\(plain(r, "StartingProbabilityPercent"))%")],
                                       soundID: 0, reloadSoundID: 0, visual: visual(modelID: int(r, "ModelID")), carriedByIDs: []))
        }
        arsenal.sort { $0.category == $1.category ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.category < $1.category }

        // Missions, with who the game places against you.
        var missions: [MissionInfo] = []
        for r in zoneRows {
            let roster = (zoneRoster[r.recordID] ?? [:]).sorted { $0.value > $1.value }.map { NamedValue(personaNames[$0.key] ?? "Persona \($0.key)", "\($0.value)") }
            let scenarioID = int(r, "Scenario")
            missions.append(MissionInfo(id: r.recordID, name: zoneName(r), devName: plain(r, "UserName"),
                                        scenario: scenarioNames[scenarioID] ?? (scenarioID == 0 ? "" : "Scenario \(scenarioID)"),
                                        timeOfDay: plain(r, "TimeOfDay"), description: plain(r, "Description"),
                                        unitCount: zoneUnits[r.recordID] ?? 0, enemyRoster: roster, templateIDs: zoneTemplates(r)))
        }
        missions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let sounds = rows("Sounds").map { r in
            SoundInfo(id: r.recordID, name: plain(r, "UserName"), source: plain(r, "SrcName"))
        }

        return GameLibrary(location: location, characters: characters, lines: lines, classes: classes, perks: perks, perkNodes: perkNodes,
                           arsenal: arsenal, missions: missions, sounds: sounds, linesByOwner: linesByOwner,
                           charactersByID: Dictionary(characters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                           textureNames: textureNames, geometryNames: geometryNames, geometryTextures: geometryTextures,
                           itemNames: Dictionary(itemRows.map { ($0.recordID, itemName($0.recordID)) }, uniquingKeysWith: { a, _ in a }),
                           interfaceTextures: interfaceTextures)
    }

    private func nonZero(_ v: Int32) -> String? { v == 0 ? nil : String(v) }
    /// The British soldier and scout are separate database classes with the same job.
    private static func className(_ raw: String) -> String { raw.hasSuffix("UK") ? String(raw.dropLast(2)) : raw }
    private static let factions: Set<String> = ["Allies", "Axis", "Renegade", "Russian", "Armed", "Hammer", "US", "Italian", "Civilian"]
}
