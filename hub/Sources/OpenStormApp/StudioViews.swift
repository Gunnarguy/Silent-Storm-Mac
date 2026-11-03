import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenStormCore

struct ModelsView: View {
    @ObservedObject var hub: HubModel
    @ObservedObject var engine: EngineController
    let library: GameLibrary
    @State private var search = ""
    @State private var selected: Int32?
    @State private var shading: MeshShadingMode = .lit
    @State private var wireframe = false
    @State private var rotate = true
    @State private var folders = FolderIndex()

    private var ids: [Int32] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return folders.filtered(hub.store.geometries?.allIDs ?? []).filter { q.isEmpty || String($0).contains(q) || (library.geometryNames[$0] ?? "").lowercased().contains(q) }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Search meshes by name or number", text: $search)
                FolderChips(index: $folders)
                Text("\(ids.count) meshes").font(.system(size: 10.5)).foregroundStyle(.secondary)
                List(ids, id: \.self, selection: $selected) { id in
                    Text(library.geometryNames[id].map(displayName) ?? "Mesh \(id)").font(.system(size: 12)).lineLimit(1).truncationMode(.middle).tag(id)
                }
                .listStyle(.sidebar)
            }
            .padding(8)
            .frame(minWidth: 290, maxWidth: 360)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Picker("Look", selection: $shading) {
                        ForEach(MeshShadingMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 180)
                    Toggle("Wireframe", isOn: $wireframe)
                    Toggle("Turn", isOn: $rotate)
                    Spacer()
                    Button("Export .obj") { exportOBJ() }.disabled(selected == nil)
                }
                .padding(8)
                if let id = selected {
                    ModelPreview(store: hub.store, engine: engine, visual: ModelVisual(geometryID: id, textureID: library.geometryTextures[id] ?? 0),
                                 shading: shading, wireframe: wireframe, autoRotate: rotate)
                } else {
                    ContentUnavailableView("Choose a mesh", systemImage: "cube").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(engine.isGameRunning ? "Paused while the game is open, so it keeps the GPU." : "Drag to turn, scroll to zoom. The texture comes from the game's own materials.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .task { if selected == nil { selected = ids.first { library.geometryTextures[$0] != nil } ?? ids.first } }
        .task(id: library.location.dataDirectory) { folders = FolderIndex(ids: hub.store.geometries?.allIDs ?? [], names: library.geometryNames) }
    }

    private func displayName(_ source: String) -> String { source.replacingOccurrences(of: "\\", with: " / ") }

    private func exportOBJ() {
        guard let id = selected, let data = hub.store.geometries?.data(id: id), let geometry = GGeometryDecoder.decode(data) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "obj") ?? .plainText]
        panel.nameFieldStringValue = "SilentStorm_\(id).obj"
        if panel.runModal() == .OK, let url = panel.url {
            try? geometry.exportWavefrontOBJ(name: "Geometry_\(id)").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct TexturesView: View {
    @ObservedObject var hub: HubModel
    let library: GameLibrary
    @State private var search = ""
    @State private var selected: Int32?
    @State private var original: DecodedMMPTexture?
    @State private var hd: DecodedMMPTexture?
    @State private var folders = FolderIndex()
    @State private var hdIDs: Set<Int32> = []
    @State private var hdOnly = false

    private var ids: [Int32] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return folders.filtered(hub.store.textures?.allIDs ?? []).filter {
            (!hdOnly || hdIDs.contains($0)) && (q.isEmpty || String($0).contains(q) || (library.textureNames[$0] ?? "").lowercased().contains(q))
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Search textures by name or number", text: $search)
                FolderChips(index: $folders)
                Toggle("Only textures with an HD version (\(hdIDs.count))", isOn: $hdOnly).font(.system(size: 11)).disabled(hdIDs.isEmpty)
                Text("\(ids.count) textures").font(.system(size: 10.5)).foregroundStyle(.secondary)
                List(ids, id: \.self, selection: $selected) { id in
                    Text(library.textureNames[id]?.replacingOccurrences(of: "\\", with: " / ") ?? "Texture \(id)").font(.system(size: 12)).lineLimit(1).truncationMode(.middle).tag(id)
                }
                .listStyle(.sidebar)
            }
            .padding(8)
            .frame(minWidth: 290, maxWidth: 360)

            HStack(spacing: 10) {
                pane("Original", original)
                pane("HD pack", hd)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if selected == nil { selected = library.characters.first { $0.photoTextureID != 0 }?.photoTextureID ?? ids.first } }
        .task(id: selected) { await loadSelection() }
        .task(id: library.location.dataDirectory) {
            folders = FolderIndex(ids: hub.store.textures?.allIDs ?? [], names: library.textureNames)
            let dir = library.location.hdTextureDirectory
            hdIDs = await Task.detached(priority: .utility) {
                Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { Int32($0) })
            }.value
        }
    }

    private func pane(_ title: String, _ texture: DecodedMMPTexture?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let texture { Text("\(texture.header.width) x \(texture.header.height), \(texture.header.format.displayName)").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                Spacer()
                if let texture { Button("Export PNG") { export(texture, title) }.controlSize(.small) }
            }
            ZStack {
                Color(red: 0.07, green: 0.08, blue: 0.11)
                if let image = texture?.makeCGImage() {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(8)
                } else {
                    Text(title == "HD pack" ? "No HD version: the game uses the original" : "Not a picture this viewer can read").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadSelection() async {
        guard let id = selected, let set = hub.store.textures else { return }
        let hdFile = library.location.hdTextureDirectory.appendingPathComponent(String(id))
        let flip = library.interfaceTextures.contains(id)
        let loaded = await Task.detached(priority: .userInitiated) {
            let plain = set.data(id: id).flatMap { MMPTextureDecoder.decode($0) }
            let better = (try? Data(contentsOf: hdFile)).flatMap { MMPTextureDecoder.decode($0) }
            return flip ? (plain?.flippedVertically(), better?.flippedVertically()) : (plain, better)
        }.value
        original = loaded.0
        hd = loaded.1
    }

    private func export(_ texture: DecodedMMPTexture, _ title: String) {
        guard let image = texture.makeCGImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "SilentStorm_\(selected ?? 0)_\(texture.header.width)x\(texture.header.height).png"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}

struct DatabaseView: View {
    @ObservedObject var engine: EngineController
    @State private var reader: NivalDatabaseReader?
    @State private var tableSearch = ""
    @State private var rowSearch = ""
    @State private var selectedTable: Int32?
    @State private var table: DBDecodedTable?
    @State private var selectedRow: Int?
    @State private var group = ""

    private var tables: [DBTableDescriptor] {
        guard let reader else { return [] }
        let q = tableSearch.lowercased()
        return reader.tables.filter { (q.isEmpty || $0.name.lowercased().contains(q)) && (group.isEmpty || AssetGroups.databaseGroup($0.name) == group) }
    }

    private var groups: [(name: String, count: Int)] {
        let counts = ChipBar.counted((reader?.tables ?? []).map { AssetGroups.databaseGroup($0.name) })
        return AssetGroups.databaseOrder.compactMap { g in counts.first { $0.name == g } }
    }

    private var rows: [DBTableRow] {
        guard let table else { return [] }
        let q = rowSearch.lowercased()
        return q.isEmpty ? table.rows : table.rows.filter { $0.values.values.contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Filter \(reader?.tables.count ?? 0) tables", text: $tableSearch)
                ChipBar(items: groups, selection: $group)
                List(selection: $selectedTable) {
                    ForEach(AssetGroups.databaseOrder, id: \.self) { g in
                        let inGroup = tables.filter { AssetGroups.databaseGroup($0.name) == g }
                        if !inGroup.isEmpty {
                            Section(g) {
                                ForEach(inGroup) { t in
                                    HStack {
                                        Text(t.name).font(.system(size: 12)).lineLimit(1)
                                        Spacer()
                                        Text("\(t.rowCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    .tag(t.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .padding(8)
            .frame(minWidth: 250, maxWidth: 310)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(table?.descriptor.name ?? "Choose a table").font(.system(size: 13, weight: .semibold))
                    Text("\(rows.count) rows").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export CSV") { exportCSV() }.disabled(table == nil)
                }
                SearchField(prompt: "Search every column", text: $rowSearch)
                List(rows.prefix(1000), selection: $selectedRow) { row in
                    HStack(spacing: 10) {
                        Text("#\(row.recordID)").font(.system(size: 11, weight: .bold, design: .monospaced)).frame(width: 66, alignment: .leading)
                        Text(summary(row)).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                    }
                    .tag(row.id)
                }
                .listStyle(.inset)
            }
            .padding(8)
            .frame(minWidth: 420)

            ScrollView {
                if let table, let id = selectedRow, let row = table.rows.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(table.allColumns, id: \.self) { col in
                            HStack(alignment: .top) {
                                Text(col).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                                Text(row.values[col] ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                            }
                            Divider()
                        }
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 280, maxWidth: 400)
        }
        .task(id: engine.selectedEdition) {
            let url = engine.dataDirectory.appendingPathComponent(engine.selectedEdition.databaseFileName)
            reader = await Task.detached(priority: .userInitiated) { try? NivalDatabaseReader(fileURL: url) }.value
            table = nil
            selectedTable = reader?.tables.first { $0.name == "RPGPers" }?.id ?? reader?.tables.first?.id
        }
        .task(id: selectedTable) {
            guard let reader, let id = selectedTable, let descriptor = reader.tables.first(where: { $0.id == id }) else { return }
            table = await Task.detached(priority: .userInitiated) { reader.decodeTable(descriptor) }.value
            selectedRow = table?.rows.first?.id
        }
    }

    private func summary(_ row: DBTableRow) -> String {
        var parts: [String] = []
        for col in table?.allColumns ?? [] where col != "ID" {
            if let v = row.values[col], !v.isEmpty, v != "0", v != "0.000" {
                parts.append("\(col)=\(v)")
                if parts.count >= 4 { break }
            }
        }
        return parts.joined(separator: "  ")
    }

    private func exportCSV() {
        guard let table else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(table.descriptor.name).csv"
        if panel.runModal() == .OK, let url = panel.url { try? table.exportCSV().write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// The folders of each asset's source path, for the two rows of chips over Textures and 3D Models.
struct FolderIndex {
    var folderOf: [Int32: (top: String, sub: String?)] = [:]
    var top = ""
    var sub = ""

    init() {}
    init(ids: [Int32], names: [Int32: String]) {
        // an archive file with no database record has no source path to sort by
        for id in ids { folderOf[id] = names[id].map { AssetGroups.folders(of: $0) } ?? ("No database entry", nil) }
    }

    var tops: [(name: String, count: Int)] { ChipBar.counted(folderOf.values.map(\.top)) }
    var subs: [(name: String, count: Int)] { top.isEmpty ? [] : ChipBar.counted(folderOf.values.filter { $0.top == top }.compactMap(\.sub)) }

    func filtered(_ ids: [Int32]) -> [Int32] {
        guard !top.isEmpty else { return ids }
        return ids.filter { id in
            guard let f = folderOf[id], f.top == top else { return false }
            return sub.isEmpty || f.sub == sub
        }
    }
}

struct FolderChips: View {
    @Binding var index: FolderIndex

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChipBar(items: index.tops, selection: Binding(get: { index.top }, set: { index.top = $0; index.sub = "" }))
            if index.subs.count > 1 {
                Divider()
                ScrollView { ChipBar(items: index.subs, selection: $index.sub, allTitle: "All \(index.top.lowercased())") }
                    .frame(maxHeight: 92)
            }
        }
    }
}
