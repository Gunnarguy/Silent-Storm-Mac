import Foundation

public struct DBColumnInfo: Sendable, Hashable {
    public let name: String
    public let rawType: Int32
}

public struct DBTableDescriptor: Sendable, Identifiable, Hashable {
    public let id: Int32
    public let name: String
    public let objectPointer: UInt32
    public let payloadRange: Range<Int>
    public let rowCount: Int
    public let columnNames: [String]
}

public struct DBTableRow: Sendable, Identifiable {
    public let id: Int
    public let recordID: Int32
    public let values: [String: String]
}

public struct DBDecodedTable: Sendable {
    public let descriptor: DBTableDescriptor
    public let intColumns: [String]
    public let floatColumns: [String]
    public let stringColumns: [String]
    public let allColumns: [String]
    public let rows: [DBTableRow]

    public func exportCSV() -> String {
        var lines: [String] = []
        lines.append(allColumns.map { escapeCSV($0) }.joined(separator: ","))
        for row in rows {
            let cells = allColumns.map { col in
                escapeCSV(row.values[col] ?? "")
            }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func escapeCSV(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

/// Reader for Silent Storm's `game.db` (`ADOImport/BasicDB.cpp`, `CDBTableDataStorage` `0xA1843130`).
public final class NivalDatabaseReader: Sendable {
    /// A table's name, given the id it has in its own database file.
    public static func tableName(id: Int32) -> String {
        knownTableNames[id] ?? String(format: "Table_0x%08X", UInt32(bitPattern: id))
    }
    public static let knownTableNames: [Int32: String] = [
        1: "Models",
        2: "Animations",
        3: "Textures",
        4: "Templates",
        5: "TemplVariants",
        6: "Rects",
        7: "FinalElements",
        8: "BRDFs",
        9: "Materials",
        10: "Geometries",
        11: "Units",
        12: "Fonts",
        13: "Skeletons",
        14: "TerrainTiles",
        15: "ChapterMaps",
        16: "GlobalMaps",
        20: "AIGeometries",
        21: "WallModels",
        22: "FloorModels",
        23: "Walls",
        24: "Floors",
        25: "Particles",
        26: "SolidModels",
        27: "SolidObjects",
        28: "Containers",
        29: "AmbientLights",
        30: "Rooms",
        31: "MaterialTemplates",
        32: "ModelTemplates",
        33: "ContainerModels",
        34: "IntermediateFloors",
        35: "Attributes",
        36: "IntermediateSolids",
        37: "Sounds",
        38: "DebrisMaterials",
        39: "Debris",
        40: "Objects",
        41: "ObjectTemplates",
        42: "Explosions",
        43: "UIControls",
        44: "UIContainers",
        45: "Strings",
        46: "ConstructionPartTemplates",
        47: "ConstructionParts",
        48: "Grass",
        49: "UITextures",
        50: "TerrainSpots",
        51: "RPGCriticals",
        52: "AISounds",
        53: "CubeTextures",
        54: "AckInfos",
        55: "AckSeqs",
        56: "Acks",
        57: "SoundVariants",
        58: "SoundTemplates",
        59: "RPGToHits",
        60: "Waypoints",
        61: "Doors",
        62: "Guns",
        63: "WaypointNames",
        64: "ParticleInstances",
        65: "Effects",
        66: "EffectTemplates",
        67: "AnimWeaponTypes",
        68: "AISoundConstants",
        69: "Heads",
        70: "HeadSeqs",
        71: "InterruptsConstants",
        72: "RPGDmgToArmors",
        73: "LightInstances",
        74: "Lights",
        75: "ComplexHeads",
        76: "Musics",
        77: "PlacableObjects",
        78: "Spots",
        79: "ScenarioZones",
        80: "ScenarioStates",
        81: "ScenarioClues",
        82: "ScenarioObjectives",
        83: "Scenarios",
        84: "ScenarioObjective2Clues",
        86: "PassageObjects",
        87: "Panzerkleins",
        88: "Cameras",
        89: "UnitGroups",
        90: "RPGMaterials",
        91: "AutoLoadScripts",
        92: "AmbientLightTemplates",
        93: "SoundInstances",
        94: "SoundEffects",
        95: "Sides",
        96: "Nationalities",
        97: "Dialogs",
        98: "DifficultyConstants",
        99: "Diplomacies",
        100: "TranslatedStrings",
        101: "RPGPerks",
        102: "RPGPerkTreeNodes",
        103: "DialogSeqs",
        104: "DialogPers",
        105: "RPGMinesConstants",
        0x6A: "RPGChestTemplates",
        0x6B: "RPGLootInstances",
        0x6C: "RPGChests",
        0x6D: "Hints",
        0x6E: "ScenarioTasks",
        0x6F: "ScenarioGoals",
        0x70: "PhysParams",
        0x71: "UICursors",
        0x72: "RPGChestLayouts",
        0x73: "TransformableFaceTextures",
        0x74: "TransformableEyeTextures",
        0x75: "TransformableEyelashTeethTextures",
        0x76: "TransformableHeadMaterials",
        0x77: "TransformableHeadHairs",
        0x78: "Races",
        0x79: "TransformableHeadGlasses",
        0x7A: "FaceExpression2Sequences",
        0x7B: "RPGEngGrenades",
        0x7C: "AckConditions",
        0x7D: "MusicTemplates",
        0x7E: "RPGAPs",
        Int32(bitPattern: 0xE0000001): "RPGWeaponTypes",
        Int32(bitPattern: 0xE0000002): "RPGWeapons",
        Int32(bitPattern: 0xE0000003): "RPGClasses",
        Int32(bitPattern: 0xE0000004): "RPGPers",
        Int32(bitPattern: 0xE0000005): "RPGArmors",
        Int32(bitPattern: 0xE0000006): "RPGAmmos",
        Int32(bitPattern: 0xE0000007): "RPGBaseValues",
        Int32(bitPattern: 0xE0000008): "RPGClips",
        Int32(bitPattern: 0xE0000009): "RPGItems",
        Int32(bitPattern: 0xE000000A): "RPGWeapon4Pers",
        Int32(bitPattern: 0xE000000B): "RPGClip4Pers",
        Int32(bitPattern: 0xE000000C): "Scripts",
        Int32(bitPattern: 0xE000000D): "RPGGrenades",
        Int32(bitPattern: 0xE000000E): "RPGUniforms",
        Int32(bitPattern: 0xE000000F): "RPGGrenade4Pers",
        Int32(bitPattern: 0xE0000010): "RPGItem2Uniforms",
        Int32(bitPattern: 0xE0000012): "RPGFirstAids",
        Int32(bitPattern: 0xE0000013): "RPGFirstAid4Pers",
        Int32(bitPattern: 0xE0000014): "RPGMeleeWeapons",
        Int32(bitPattern: 0xE0000015): "RPGMeleeWeapon4Pers",
        Int32(bitPattern: 0xE0000016): "RPGMineDetectors",
        Int32(bitPattern: 0xE0000017): "RPGMineDetector4Pers",
        Int32(bitPattern: 0xE0000018): "RPGStoreItems",
        Int32(bitPattern: 0xE0000019): "RPGMines",
        Int32(bitPattern: 0xE0000020): "RPGMines4Pers",
        Int32(bitPattern: 0xE0000021): "RPGTools",
        Int32(bitPattern: 0xE0000022): "RPGTool4Pers",
        Int32(bitPattern: 0xE0000023): "RPGKeys",
        Int32(bitPattern: 0xE0000024): "RPGKey4Pers",
        Int32(bitPattern: 0xE0000025): "RPGPicklocks",
        Int32(bitPattern: 0xE0000026): "RPGPicklocks4Pers",
        Int32(bitPattern: 0xE0000027): "Medals",
        Int32(bitPattern: 0xE0000028): "RPGEngGrenade4Pers"
    ]

    public let fileURL: URL
    public let data: Data
    public let version: Int32
    public let tables: [DBTableDescriptor]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        self.data = fileData

        var ver: Int32 = 0
        var rootChunkRange: Range<Int>?
        var objectsDataRange: Range<Int>?

        for top in ShortChunkReader.iterateChunks(in: fileData) {
            switch top.id {
            case 4:
                if top.length >= 4 {
                    ver = ShortChunkReader.readInt32LE(fileData, at: top.payloadRange.lowerBound)
                }
            case 1:
                rootChunkRange = top.payloadRange
            case 2:
                objectsDataRange = top.payloadRange
            default:
                break
            }
        }
        self.version = ver

        // 1. Parse storageTables map (tableID -> pServer) in top-level chunk 1
        var ptrToTableID: [UInt32: Int32] = [:]
        if let rr = rootChunkRange {
            for c in ShortChunkReader.iterateChunks(in: fileData, range: rr) where c.id == 1 {
                var keys: [Int32] = []
                var ptrs: [UInt32] = []
                for sub in ShortChunkReader.iterateChunks(in: fileData, range: c.payloadRange) {
                    if sub.id == 1 && sub.length >= 4 {
                        keys.append(ShortChunkReader.readInt32LE(fileData, at: sub.payloadRange.lowerBound))
                    } else if sub.id == 2 && sub.length >= 4 {
                        ptrs.append(ShortChunkReader.readUInt32LE(fileData, at: sub.payloadRange.lowerBound))
                    }
                }
                for i in 0..<min(keys.count, ptrs.count) {
                    ptrToTableID[ptrs[i]] = keys[i]
                }
            }
        }

        // 2. Scan top-level chunk 2 for each serialized CDBTableDataStorage object
        var descriptors: [DBTableDescriptor] = []
        if let dr = objectsDataRange {
            for objChunk in ShortChunkReader.iterateChunks(in: fileData, range: dr) where objChunk.id == 1 {
                var pServer: UInt32 = 0
                var bodyRange: Range<Int>?
                for sub in ShortChunkReader.iterateChunks(in: fileData, range: objChunk.payloadRange) {
                    if sub.id == 0 && sub.length >= 4 {
                        pServer = ShortChunkReader.readUInt32LE(fileData, at: sub.payloadRange.lowerBound)
                    } else if sub.id == 1 {
                        bodyRange = sub.payloadRange
                    }
                }
                guard let br = bodyRange else { continue }
                let tableID = ptrToTableID[pServer] ?? Int32(bitPattern: pServer)
                let tableName = Self.tableName(id: tableID)

                // Quick scan of row count (tag 2) and column names (tags 6, 7, 8)
                var rowCount = 0
                var cols: [String] = []
                for tc in ShortChunkReader.iterateChunks(in: fileData, range: br) {
                    switch tc.id {
                    case 2:
                        rowCount = ShortChunkReader.iterateChunks(in: fileData, range: tc.payloadRange).count
                    case 6, 7, 8:
                        for sc in ShortChunkReader.iterateChunks(in: fileData, range: tc.payloadRange) where sc.id == 1 {
                            let col = ShortChunkReader.readASCIIString(in: fileData, range: sc.payloadRange)
                            if !col.isEmpty { cols.append(col) }
                        }
                    default:
                        break
                    }
                }

                descriptors.append(DBTableDescriptor(
                    id: tableID,
                    name: tableName,
                    objectPointer: pServer,
                    payloadRange: br,
                    rowCount: rowCount,
                    columnNames: cols
                ))
            }
        }

        self.tables = descriptors.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Decodes all rows and columns of the specified table descriptor.
    public func decodeTable(_ descriptor: DBTableDescriptor) -> DBDecodedTable {
        var intCols: [String] = []
        var floatCols: [String] = []
        var stringCols: [String] = []
        var fieldOrder: [String] = []

        var intRows: [[Int32]] = []
        var floatRows: [[Float]] = []
        var stringRows: [[String]] = []

        for tc in ShortChunkReader.iterateChunks(in: data, range: descriptor.payloadRange) {
            switch tc.id {
            case 2: // records_int: vector<vector<int>>
                let rChunks = ShortChunkReader.iterateChunks(in: data, range: tc.payloadRange)
                intRows.reserveCapacity(rChunks.count)
                for rc in rChunks where rc.id == 1 {
                    let (count, bytes) = ShortChunkReader.readDataVector(in: data, range: rc.payloadRange)
                    var vals: [Int32] = []
                    vals.reserveCapacity(count)
                    for i in 0..<count where bytes.lowerBound + (i + 1) * 4 <= bytes.upperBound {
                        vals.append(ShortChunkReader.readInt32LE(data, at: bytes.lowerBound + i * 4))
                    }
                    intRows.append(vals)
                }
            case 3: // records_float: vector<vector<float>>
                let rChunks = ShortChunkReader.iterateChunks(in: data, range: tc.payloadRange)
                floatRows.reserveCapacity(rChunks.count)
                for rc in rChunks where rc.id == 1 {
                    let (count, bytes) = ShortChunkReader.readDataVector(in: data, range: rc.payloadRange)
                    var vals: [Float] = []
                    vals.reserveCapacity(count)
                    for i in 0..<count where bytes.lowerBound + (i + 1) * 4 <= bytes.upperBound {
                        vals.append(ShortChunkReader.readFloatLE(data, at: bytes.lowerBound + i * 4))
                    }
                    floatRows.append(vals)
                }
            case 4: // records_wstring: vector<vector<wstring>>
                let rChunks = ShortChunkReader.iterateChunks(in: data, range: tc.payloadRange)
                stringRows.reserveCapacity(rChunks.count)
                for rc in rChunks where rc.id == 1 {
                    var vals: [String] = []
                    for sc in ShortChunkReader.iterateChunks(in: data, range: rc.payloadRange) where sc.id == 1 {
                        vals.append(ShortChunkReader.readUTF16String(in: data, range: sc.payloadRange))
                    }
                    stringRows.append(vals)
                }
            case 5: // fields: vector<SColumnInfo>
                for fc in ShortChunkReader.iterateChunks(in: data, range: tc.payloadRange) where fc.id == 1 {
                    for sub in ShortChunkReader.iterateChunks(in: data, range: fc.payloadRange) where sub.id == 2 {
                        let name = ShortChunkReader.readASCIIString(in: data, range: sub.payloadRange)
                        if !name.isEmpty { fieldOrder.append(name) }
                    }
                }
            case 6: // intFileds
                for sc in ShortChunkReader.iterateChunks(in: data, range: tc.payloadRange) where sc.id == 1 {
                    intCols.append(ShortChunkReader.readASCIIString(in: data, range: sc.payloadRange))
                }
            case 7: // floatFileds
                for sc in ShortChunkReader.iterateChunks(in: data, range: tc.payloadRange) where sc.id == 1 {
                    floatCols.append(ShortChunkReader.readASCIIString(in: data, range: sc.payloadRange))
                }
            case 8: // stringFileds
                for sc in ShortChunkReader.iterateChunks(in: data, range: tc.payloadRange) where sc.id == 1 {
                    stringCols.append(ShortChunkReader.readASCIIString(in: data, range: sc.payloadRange))
                }
            default:
                break
            }
        }

        let orderedColumns = fieldOrder.isEmpty ? (intCols + floatCols + stringCols) : fieldOrder
        let rowCount = max(intRows.count, max(floatRows.count, stringRows.count))
        var rows: [DBTableRow] = []
        rows.reserveCapacity(rowCount)

        for r in 0..<rowCount {
            var dict: [String: String] = [:]
            var recID: Int32 = Int32(r)

            if r < intRows.count {
                let ir = intRows[r]
                for (cIdx, cName) in intCols.enumerated() where cIdx < ir.count {
                    let v = ir[cIdx]
                    dict[cName] = String(v)
                    if cName == "ID" { recID = v }
                }
            }
            if r < floatRows.count {
                let fr = floatRows[r]
                for (cIdx, cName) in floatCols.enumerated() where cIdx < fr.count {
                    dict[cName] = String(format: "%.3f", fr[cIdx])
                }
            }
            if r < stringRows.count {
                let sr = stringRows[r]
                for (cIdx, cName) in stringCols.enumerated() where cIdx < sr.count {
                    dict[cName] = sr[cIdx]
                }
            }

            rows.append(DBTableRow(id: r, recordID: recID, values: dict))
        }

        return DBDecodedTable(
            descriptor: descriptor,
            intColumns: intCols,
            floatColumns: floatCols,
            stringColumns: stringCols,
            allColumns: orderedColumns,
            rows: rows
        )
    }
}
