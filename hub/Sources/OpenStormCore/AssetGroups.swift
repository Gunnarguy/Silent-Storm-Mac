import Foundation

/// How the hub sorts assets into categories: textures and meshes by the folders of their original source path,
/// database tables by what they describe.
public enum AssetGroups {
    /// "Buildings\Walls\brick01.tga" gives ("Buildings", "Walls"); a file directly under a folder has no second level.
    public static func folders(of path: String) -> (top: String, sub: String?) {
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard let first = parts.first, parts.count > 1 else { return ("Top folder", nil) }
        let top = topNames[first.lowercased()] ?? first.prefix(1).uppercased() + first.dropFirst()
        return (top, parts.count > 2 ? parts[1] : nil)
    }

    private static let topNames: [String: String] = [
        "interface v5.0": "Interface", "interface v4.0": "Interface", "interfaces": "Interface", "interface": "Interface",
        "lshead": "Face generator", "heads": "Heads", "terrainobjects": "Terrain objects", "campzones": "Camp zones", "campzone": "Camp zones",
        "gametutorials": "Tutorials", "mapeditor": "Map editor", "refmaps": "Reference maps",
    ]

    /// The order the database groups are shown in.
    public static let databaseOrder = ["Characters", "Items and weapons", "Combat rules", "Voices and sound", "Story and missions",
                                       "Maps and world", "Graphics", "Interface", "Other"]

    public static func databaseGroup(_ table: String) -> String {
        let t = table.lowercased()
        if exact[t] != nil { return exact[t]! }
        for (prefixes, group) in prefixRules where prefixes.contains(where: { t.hasPrefix($0) }) { return group }
        return "Other"
    }

    private static let exact: [String: String] = {
        var m: [String: String] = [:]
        func put(_ group: String, _ names: [String]) { for n in names { m[n.lowercased()] = group } }
        put("Characters", ["RPGPers", "RPGClasses", "RPGPerks", "RPGPerkTreeNodes", "Nationalities", "Races", "Sides",
                           "Attributes", "RPGBaseValues", "DialogPers", "Medals"])
        put("Items and weapons", ["RPGWeapons", "RPGItems", "RPGClips", "RPGAmmos", "RPGGrenades", "RPGEngGrenades", "RPGMeleeWeapons",
                                  "RPGFirstAids", "RPGMines", "RPGTools", "RPGKeys", "RPGPicklocks", "RPGMineDetectors", "RPGUniforms",
                                  "RPGItem2Uniforms", "RPGWeaponTypes", "Guns", "Panzerkleins", "RPGStoreItems", "RPGChests", "RPGChestLayouts", "RPGChestTemplates",
                                  "RPGLootInstances"])
        put("Combat rules", ["RPGToHits", "RPGCriticals", "RPGAPs", "RPGArmors", "RPGDmgToArmors", "RPGMaterials", "DifficultyConstants", "InterruptsConstants", "RPGMinesConstants", "PhysParams", "Diplomacies"])
        put("Voices and sound", ["AckConditions", "AckInfos", "Acks", "AckSeqs", "Sounds", "SoundTemplates", "SoundVariants", "SoundInstances",
                                 "SoundEffects", "Musics", "MusicTemplates", "AISounds", "AISoundConstants"])
        put("Story and missions", ["Dialogs", "DialogSeqs", "Hints", "Scripts", "Strings",
                                   "ChapterMaps", "GlobalMaps", "AutoLoadScripts", "TranslatedStrings"])
        put("Maps and world", ["Templates", "TemplVariants", "Units", "UnitGroups", "Waypoints", "WaypointNames", "FinalElements", "Objects",
                               "ObjectTemplates", "Doors", "PassageObjects", "PlacableObjects", "ContainerModels", "TerrainSpots",
                               "TerrainTiles", "Spots", "Grass", "Debris", "DebrisMaterials", "AIGeometries",
                               "Containers", "FloorModels", "Floors", "IntermediateFloors", "IntermediateSolids", "Rooms", "SolidModels",
                               "SolidObjects", "WallModels", "Walls"])
        put("Graphics", ["Textures", "CubeTextures", "Materials", "MaterialTemplates", "Models", "ModelTemplates", "Geometries", "Skeletons",
                         "Animations", "AnimWeaponTypes", "Effects", "EffectTemplates", "Particles", "ParticleInstances", "Lights",
                         "LightInstances", "AmbientLights", "AmbientLightTemplates", "Explosions", "Heads", "HeadSeqs", "ComplexHeads",
                         "FaceExpression2Sequences", "Fonts", "Cameras", "BRDFs"])
        put("Interface", ["UIContainers", "UIControls", "UICursors", "UITextures", "Rects"])
        return m
    }()

    private static let prefixRules: [([String], String)] = [
        (["scenario"], "Story and missions"),
        (["transformable"], "Graphics"),
        (["constructionpart"], "Maps and world"),
        (["ack", "sound", "music"], "Voices and sound"),
        (["ui"], "Interface"),
        (["rpg"], "Items and weapons"),
    ]
}
