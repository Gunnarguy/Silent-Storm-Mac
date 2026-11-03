import AppKit
import SwiftUI
import OpenStormCore

@main
struct OpenStormMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var hub = HubModel()

    var body: some Scene {
        WindowGroup("Silent Storm Gold") {
            HubRootView(hub: hub)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfCheck.isRequested {
            NSApp.setActivationPolicy(.accessory)
            SelfCheck.run()
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !SelfCheck.isRequested
    }
}

enum HubSection: String, CaseIterable, Identifiable {
    case play = "Play"
    case people = "People"
    case voices = "Voices"
    case arsenal = "Arsenal"
    case perks = "Perks & Classes"
    case missions = "Missions"
    case sounds = "Sounds & Music"
    case models = "3D Models"
    case textures = "Textures"
    case database = "Database"
    case squad = "Live Squad"
    case advisor = "Advisor"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .play: return "play.circle"
        case .people: return "person.3"
        case .voices: return "waveform"
        case .arsenal: return "shield.lefthalf.filled"
        case .perks: return "star.circle"
        case .missions: return "map"
        case .sounds: return "speaker.wave.2"
        case .models: return "cube"
        case .textures: return "photo.on.rectangle"
        case .database: return "tablecells"
        case .squad: return "dot.radiowaves.left.and.right"
        case .advisor: return "apple.intelligence"
        }
    }

    static let groups: [(String, [HubSection])] = [
        ("Game", [.play, .squad]),
        ("Explore", [.people, .voices, .arsenal, .perks, .missions]),
        ("Files", [.sounds, .models, .textures, .database]),
        ("Ask", [.advisor]),
    ]
}

/// What the hub is showing, kept in one place so one screen can open another (a person from a voice line, a gun from a loadout).
@MainActor
final class HubModel: ObservableObject {
    let engine = EngineController()
    let store = LibraryStore()
    let player = ClipPlayer()
    let advisor = AdvisorModel()

    @Published var section: HubSection = .play
    @Published var personID: Int32?
    @Published var voiceOwnerID: Int32?
    @Published var lineID: Int32?
    @Published var itemID: String?
    @Published var missionID: Int32?
    @Published var classID: Int32?

    func openPerson(_ id: Int32) {
        personID = id
        section = .people
    }

    func openVoices(of owner: Int32) {
        voiceOwnerID = owner
        lineID = nil
        section = .voices
    }

    func openItem(_ id: String) {
        itemID = id
        section = .arsenal
    }
}

/// Loads one game's joined data off the main thread, and keeps it so switching games back is instant.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var library: GameLibrary?
    @Published private(set) var failure: String?
    private(set) var sounds: ResourceSet?
    private(set) var textures: ResourceSet?
    private(set) var geometries: ResourceSet?
    private var cache: [SilentStormEdition: (GameLibrary, ResourceSet, ResourceSet, ResourceSet)] = [:]
    private var images: [Int32: CGImage] = [:]

    func load(_ edition: SilentStormEdition) async {
        images.removeAll()
        if let c = cache[edition] {
            install(c)
            return
        }
        library = nil
        failure = nil
        let location = edition.location
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                (try GameLibrary.load(location), location.sounds(), location.textures(), location.geometries())
            }.value
            cache[edition] = loaded
            install(loaded)
        } catch {
            failure = "Could not read \(edition.databaseFileName): \(error.localizedDescription)"
        }
    }

    private func install(_ c: (GameLibrary, ResourceSet, ResourceSet, ResourceSet)) {
        library = c.0
        sounds = c.1
        textures = c.2
        geometries = c.3
    }

    func image(_ id: Int32) async -> CGImage? {
        if let cached = images[id] { return cached }
        guard let set = textures else { return nil }
        let flip = library?.interfaceTextures.contains(id) ?? false
        let decoded = await Task.detached(priority: .userInitiated) {
            let d = set.data(id: id).flatMap { MMPTextureDecoder.decode($0) }
            return flip ? d?.flippedVertically() : d
        }.value
        let image = decoded?.makeCGImage()
        if images.count > 400 { images.removeAll() }
        if let image { images[id] = image }
        return image
    }
}

struct HubRootView: View {
    @ObservedObject var hub: HubModel
    @ObservedObject var engine: EngineController
    @ObservedObject var store: LibraryStore
    private let forcedSection: HubSection?

    init(hub: HubModel, forcedSection: HubSection? = nil) {
        self.hub = hub
        self.engine = hub.engine
        self.store = hub.store
        self.forcedSection = forcedSection
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 214)
            Divider()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PlayerBar(player: hub.player)
            }
        }
        .task(id: engine.selectedEdition) {
            await store.load(engine.selectedEdition)
            hub.player.soundSource = store.sounds
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SILENT STORM GOLD")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(HubSection.groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.0.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 8)
                            ForEach(group.1) { section in
                                Button {
                                    hub.section = section
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: section.icon).frame(width: 18)
                                        Text(section.rawValue)
                                        Spacer()
                                        if section == .squad, engine.liveSquad != nil {
                                            Circle().fill(.green).frame(width: 7, height: 7)
                                        }
                                    }
                                    .font(.system(size: 12.5, weight: hub.section == section ? .semibold : .regular))
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(hub.section == section ? Color.accentColor.opacity(0.28) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(engine.isGameRunning ? .green : .gray).frame(width: 8, height: 8)
                    Text(engine.isGameRunning ? "\(engine.runningEdition?.shortTitle ?? "Game") is open" : "No game open")
                        .font(.system(size: 11, weight: .medium))
                }
                Button {
                    if engine.isGameRunning { engine.terminateGame() } else { engine.launchGame() }
                } label: {
                    Label(engine.isGameRunning ? "Quit game" : "Play \(engine.selectedEdition.shortTitle)", systemImage: engine.isGameRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isGameRunning ? .red : .green)
            }
            .padding(12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        let section = forcedSection ?? hub.section
        switch section {
        case .play:
            PlayView(hub: hub, engine: engine)
        case .squad:
            LiveSquadView(hub: hub, engine: engine, store: store)
        case .advisor:
            AdvisorView(hub: hub, advisor: hub.advisor)
        default:
            if let library = store.library {
                switch section {
                case .people: PeopleView(hub: hub, library: library)
                case .voices: VoicesView(hub: hub, library: library)
                case .arsenal: ArsenalView(hub: hub, library: library)
                case .perks: PerksView(hub: hub, library: library)
                case .missions: MissionsView(hub: hub, library: library)
                case .sounds: SoundsView(hub: hub, library: library)
                case .models: ModelsView(hub: hub, engine: engine, library: library)
                case .textures: TexturesView(hub: hub, library: library)
                default: DatabaseView(engine: engine)
                }
            } else if let failure = store.failure {
                ContentUnavailableView("Game data not found", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView("Reading game data")
            }
        }
    }
}

// MARK: - Shared pieces

struct GameImage: View {
    @ObservedObject var store: LibraryStore
    let textureID: Int32
    var contentMode: ContentMode = .fit
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.white.opacity(0.04))
            }
        }
        .task(id: textureID) { image = await store.image(textureID) }
    }
}

/// One mesh with its texture, decoded off the main thread.
struct ModelPreview: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: EngineController
    let visual: ModelVisual
    var shading: MeshShadingMode = .lit
    var wireframe = false
    var autoRotate = true
    @State private var geometry: DecodedGeometry?
    @State private var texture: DecodedMMPTexture?
    @State private var loadedFor: ModelVisual?

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.09)
            if loadedFor == visual {
                MetalGeometryViewport(geometry: geometry, geometryKey: "g\(visual.geometryID)", texture: texture, textureKey: "t\(visual.textureID)",
                                      autoRotate: autoRotate, showWireframe: wireframe, shadingMode: shading, paused: engine.isGameRunning)
            }
            if loadedFor == visual, geometry == nil {
                Text("This mesh has no drawable triangles").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: visual) {
            guard let geos = store.geometries, let texs = store.textures else { return }
            let v = visual
            let loaded = await Task.detached(priority: .userInitiated) {
                (geos.data(id: v.geometryID).flatMap { GGeometryDecoder.decode($0) }, texs.data(id: v.textureID).flatMap { MMPTextureDecoder.decode($0) })
            }.value
            geometry = loaded.0
            texture = loaded.1
            loadedFor = v
        }
    }
}

struct PlayButton: View {
    @ObservedObject var player: ClipPlayer
    let clip: PlayableClip?

    var body: some View {
        Button {
            if let clip { player.toggle(clip) }
        } label: {
            Image(systemName: player.currentID == clip?.id && player.isPlaying ? "stop.fill" : "play.fill")
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .disabled(clip == nil)
        .help(clip == nil ? "The game files have no recording for this" : "Play")
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ValueGrid: View {
    let values: [NamedValue]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(values) { v in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(v.name).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(v.value).font(.system(size: 12, weight: .semibold, design: .rounded)).textSelection(.enabled)
                }
            }
        }
    }
}

struct Tag: View {
    let text: String
    var color: Color = .gray

    init(_ text: String, color: Color = .gray) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.22))
            .foregroundStyle(color == .gray ? Color.secondary : color)
            .clipShape(Capsule())
    }
}
