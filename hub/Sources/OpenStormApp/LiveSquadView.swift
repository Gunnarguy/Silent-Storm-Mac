import SwiftUI
import OpenStormCore

struct LiveSquadView: View {
    @ObservedObject var hub: HubModel
    @ObservedObject var engine: EngineController
    @ObservedObject var store: LibraryStore

    var body: some View {
        Group {
            if let squad = engine.liveSquad {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Text("Live Squad").font(.system(size: 22, weight: .bold, design: .rounded))
                            Tag(squad.realTime ? "Real time" : (squad.playerTurn ? "Your turn" : "Enemy turn"), color: squad.realTime ? .mint : .orange)
                            Spacer()
                            Text("Updates every 2.5 seconds").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(squad.squad) { SoldierCard(hub: hub, unit: $0, library: store.library) }
                        }
                        let enemies = squad.enemies.filter { $0.hp > 0 }
                        DetailSection(title: "Enemies your squad can see (\(enemies.count))") {
                            if enemies.isEmpty {
                                Text("None alive in sight.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach(enemies) { enemy in
                                HStack(spacing: 10) {
                                    Button(enemy.name) { hub.openPerson(enemy.pers) }.buttonStyle(.link).font(.system(size: 12))
                                    HealthBar(value: enemy.hp, maximum: enemy.maxHP, color: .red).frame(width: 160)
                                    Text("\(max(0, enemy.hp)) / \(enemy.maxHP)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    if enemy.down { Tag("Down", color: .red) }
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if engine.isGameRunning {
                ContentUnavailableView("Waiting for a mission", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Your squad shows here as soon as a mission is loaded."))
            } else {
                ContentUnavailableView("No game open", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Start a mission and this shows your squad's health, action points, skills and weapons, and the enemies they can see."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HealthBar: View {
    let value: Int
    let maximum: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 3).fill(color)
                    .frame(width: geo.size.width * CGFloat(max(0, min(value, maximum))) / CGFloat(max(1, maximum)))
            }
        }
        .frame(height: 8)
    }
}

struct SoldierCard: View {
    @ObservedObject var hub: HubModel
    let unit: LiveUnit
    let library: GameLibrary?

    private var person: GameCharacter? { library?.charactersByID[unit.pers] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let photo = person?.photoTextureID, photo != 0 {
                    GameImage(store: hub.store, textureID: photo, contentMode: .fill)
                        .frame(width: 46, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Button(unit.name) { hub.openPerson(unit.pers) }.buttonStyle(.plain).font(.system(size: 14, weight: .bold))
                        if unit.hero == true { Tag("Hero", color: .accentColor) }
                        if unit.down { Tag("Down", color: .red) }
                        if unit.hidden == true { Tag("Hidden", color: .mint) }
                    }
                    Text([person?.className, unit.skills?["Level"].map { "level \($0)" }].compactMap { $0 }.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let item = unit.item, item != 0, let name = library?.itemNames[item] {
                        Button { hub.section = .arsenal } label: { Label(name, systemImage: "scope").font(.system(size: 11)) }.buttonStyle(.plain)
                    }
                }
            }
            row("VP", unit.hp, unit.maxHP, .green)
            row("AP", unit.ap, unit.maxAP, .blue)
            if let criticals = unit.criticals, criticals > 0 { Tag("\(criticals) critical injury", color: .red) }
            if let skills = unit.skills {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 2) {
                    ForEach(skills.keys.filter { $0 != "Level" }.sorted(), id: \.self) { key in
                        HStack(spacing: 4) {
                            Text(key).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text("\(skills[key] ?? 0)").font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                if let sight = unit.sight { small("Sight", sight) }
                if let interrupt = unit.interrupt { small("Interrupt", interrupt) }
                if let ic = unit.ic { small("IC", ic) }
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func row(_ title: String, _ value: Int, _ maximum: Int, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).frame(width: 20, alignment: .leading)
            HealthBar(value: value, maximum: maximum, color: color)
            Text("\(max(0, value)) / \(maximum)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
        }
    }

    private func small(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 10.5, weight: .semibold))
        }
    }
}
