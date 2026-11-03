import AVFoundation
import XCTest
@testable import OpenStormCore

/// Everything here reads the installed game data and writes nothing.
final class OpenStormCoreTests: XCTestCase {
    private func library(_ edition: SilentStormEdition) throws -> GameLibrary {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: edition.dataDirectory.appendingPathComponent(edition.databaseFileName).path))
        return try GameLibrary.load(edition.location)
    }

    func testOrganizersSortEverything() throws {
        do {
            let edition = SilentStormEdition.silentStorm
            let url = edition.dataDirectory.appendingPathComponent(edition.databaseFileName)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
            let other = try NivalDatabaseReader(fileURL: url).tables.map(\.name).filter { AssetGroups.databaseGroup($0) == "Other" }
            print("\(edition.rawValue): tables left in Other: \(other)")
            XCTAssertLessThanOrEqual(other.count, 6, edition.rawValue)
            let lib = try library(edition)
            let tops = Set(lib.textureNames.values.map { AssetGroups.folders(of: $0).top })
            print("\(edition.rawValue): texture folders \(tops.sorted())")
            XCTAssertTrue(tops.contains("Buildings") && tops.contains("Characters") && tops.contains("Interface"), edition.rawValue)
        }
        XCTAssertEqual(AssetGroups.folders(of: "Buildings\\Walls\\brick.tga").top, "Buildings")
        XCTAssertEqual(AssetGroups.folders(of: "Buildings\\Walls\\brick.tga").sub, "Walls")
        XCTAssertEqual(AssetGroups.folders(of: "Interface v5.0\\Icons\\a.tga").top, "Interface")
    }

    func testEveryTableHasAName() throws {
        do {
            let edition = SilentStormEdition.silentStorm
            let url = edition.dataDirectory.appendingPathComponent(edition.databaseFileName)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
            let db = try NivalDatabaseReader(fileURL: url)
            XCTAssertEqual(db.tables.filter { $0.name.hasPrefix("Table_0x") }.map(\.name), [], edition.rawValue)
            XCTAssertNotNil(db.tables.first { $0.name == "RPGPers" }, edition.rawValue)
            XCTAssertTrue(try XCTUnwrap(db.tables.first { $0.name == "RPGPers" }).columnNames.contains("CanHired"), "the table called RPGPers must really be it")
        }
    }

    func testTableNamesFollowGameDB() {
        XCTAssertEqual(NivalDatabaseReader.tableName(id: 91), "AutoLoadScripts")
        XCTAssertEqual(NivalDatabaseReader.tableName(id: 0x7f00_0000), "Table_0x7F000000")
    }

    func testLibraryJoins() throws {
        do {
            let edition = SilentStormEdition.silentStorm
            let lib = try library(edition)
            XCTAssertGreaterThan(lib.characters.count, 700)
            XCTAssertEqual(lib.characters.filter { $0.kind == .hire }.count, 40)
            XCTAssertGreaterThan(lib.lines.count, 4900)
            XCTAssertEqual(lib.lines.filter { $0.text.isEmpty }.count, 1, "one line in the database has no text")
            XCTAssertTrue(lib.characters.filter { $0.kind == .hire }.allSatisfy { !$0.biography.isEmpty && $0.photoTextureID != 0 && $0.lineCount > 0 && !$0.stats.isEmpty })
            XCTAssertFalse(lib.lines.contains { $0.text.contains("<br>") }, "markup must be stripped")
            XCTAssertGreaterThan(lib.arsenal.filter { $0.category == "Guns" }.count, 100)
            XCTAssertGreaterThan(lib.missions.count, 50)
            XCTAssertGreaterThanOrEqual(lib.perks.count, 94)
            XCTAssertFalse(lib.perks.values.contains { $0.text.contains("by  ") }, "perk numbers must be filled in")
            XCTAssertTrue(lib.characters.filter { $0.kind == .hire }.allSatisfy { !$0.hitSoundIDs.isEmpty }, "hit sounds resolve through their variants")
        }
    }

    func testEveryPersonsArtExists() throws {
        do {
            let edition = SilentStormEdition.silentStorm
            let lib = try library(edition)
            let geometries = edition.location.geometries(), textures = edition.location.textures()
            for c in lib.characters {
                if let v = c.visual {
                    XCTAssertTrue(geometries.contains(v.geometryID), "\(c.devName) mesh \(v.geometryID)")
                    XCTAssertTrue(textures.contains(v.textureID), "\(c.devName) texture \(v.textureID)")
                }
                if c.photoTextureID != 0 { XCTAssertNotNil(textures.data(id: c.photoTextureID).flatMap { MMPTextureDecoder.decode($0) }, c.devName) }
            }
        }
    }

    func testHireModelsDecode() throws {
        let lib = try library(.silentStorm)
        let geometries = SilentStormEdition.silentStorm.location.geometries(), textures = SilentStormEdition.silentStorm.location.textures()
        for c in lib.characters where c.kind == .hire {
            let v = try XCTUnwrap(c.visual, c.devName)
            XCTAssertNotNil(geometries.data(id: v.geometryID).flatMap { GGeometryDecoder.decode($0) }, c.devName)
            XCTAssertNotNil(textures.data(id: v.textureID).flatMap { MMPTextureDecoder.decode($0) }, c.devName)
        }
    }

    func testEveryVoiceClipThatShipsOpens() throws {
        do {
            let edition = SilentStormEdition.silentStorm
            let lib = try library(edition)
            let sounds = edition.location.sounds()
            var opened = 0, absent = 0
            for id in Set(lib.lines.flatMap(\.soundIDs)) {
                guard let data = sounds.data(id: id) else { absent += 1; continue }
                XCTAssertNoThrow(try AVAudioPlayer(data: data), "clip \(id)")
                opened += 1
            }
            print("\(edition.rawValue): \(opened) clips open, \(absent) never shipped")
            XCTAssertGreaterThan(opened, 5000)
            XCTAssertLessThan(absent, 500, "lines the database lists with no recording in the game files")
        }
    }

    func testAdvisorFindsWhatYouAskFor() throws {
        // lives in the app target, so this checks the data it searches instead
        let lib = try library(.silentStorm)
        XCTAssertTrue(lib.arsenal.contains { $0.name.lowercased().contains("luger") })
        XCTAssertTrue(lib.arsenal.contains { $0.name.lowercased().contains("colt") })
    }

    func testNativeCommandLines() {
        XCTAssertEqual(EngineController.nativeCommandLine("setxplevel 5"), "cmd setxplevel 5")
        XCTAssertEqual(EngineController.nativeCommandLine("  save Hub save "), "cmd save Hub save")
        XCTAssertNil(EngineController.nativeCommandLine(""))
        XCTAssertNil(EngineController.nativeCommandLine("a\nquit"))
    }

    func testLiveFilesDecode() throws {
        let squad = #"{"realTime":false,"playerTurn":true,"squad":[{"pers":182,"name":"GH","hp":41,"healed":0,"maxHP":75,"ap":0,"maxAP":54,"down":false,"item":173,"sight":18,"interrupt":28,"ic":8,"criticals":1,"hero":true,"hidden":false,"skills":{"Melee":19}}],"enemies":[{"pers":61,"name":"Officer","hp":10,"healed":0,"maxHP":50,"ap":0,"maxAP":40,"down":false}]}"#
        let decoded = try JSONDecoder().decode(LiveSquad.self, from: Data(squad.utf8))
        XCTAssertEqual(decoded.squad.first?.skills?["Melee"], 19)
        XCTAssertNil(decoded.enemies.first?.skills)
    }

    func testPlainTextStripsMarkup() {
        XCTAssertEqual(GameLibrary.plainText("<font face=Courier size=16pt><color=beige>Scout<br>Line two"), "Scout\nLine two")
    }
}
