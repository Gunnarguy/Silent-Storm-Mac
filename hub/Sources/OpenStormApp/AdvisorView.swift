import Foundation
import FoundationModels
import SwiftUI
import OpenStormCore

struct AdvisorMessage: Identifiable {
    let id = UUID()
    let fromYou: Bool
    let text: String
    let sources: [String]
}

/// Answers questions on this Mac from the game's own data, the live squad when a mission is open, and Apple Intelligence when available.
/// It only reads; it never changes the game.
@MainActor
final class AdvisorModel: ObservableObject {
    @Published var messages: [AdvisorMessage] = []
    @Published var isWorking = false
    @Published private(set) var modelReady = false
    @Published private(set) var modelStatus = ""

    init() { refreshAvailability() }

    func refreshAvailability() {
        let model = SystemLanguageModel.default
        modelReady = model.isAvailable
        modelStatus = model.isAvailable ? "Apple Intelligence on this Mac" : "Apple Intelligence is off, so answers are the matching game data"
    }

    func ask(_ question: String, library: GameLibrary?, squad: LiveSquad?) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        messages.append(AdvisorMessage(fromYou: true, text: q, sources: []))
        isWorking = true
        defer { isWorking = false }
        let facts = Self.facts(for: q, library: library, squad: squad)
        guard !facts.isEmpty else {
            messages.append(AdvisorMessage(fromYou: false, text: "Nothing in this game's data matches that. Try a name, a weapon, a perk or a class.", sources: []))
            return
        }
        if modelReady {
            let session = LanguageModelSession(instructions: """
                You answer questions about the game Silent Storm for someone playing it. Use only the facts given. If they do not answer the question, say so. Quote numbers exactly as given, and do not call one bigger or better unless the numbers show it. Be brief and plain.
                """)
            do {
                let prompt = "Question: \(q)\n\nFacts from the game:\n\(facts.joined(separator: "\n"))"
                let answer = try await session.respond(to: String(prompt.prefix(6000)))
                messages.append(AdvisorMessage(fromYou: false, text: answer.content, sources: facts))
                return
            } catch {
                modelStatus = "Apple Intelligence declined that one, so this is the matching game data"
            }
        }
        messages.append(AdvisorMessage(fromYou: false, text: facts.prefix(12).joined(separator: "\n"), sources: []))
    }

    /// The rows that share the most words with the question, each as one line of plain facts.
    nonisolated static func facts(for question: String, library: GameLibrary?, squad: LiveSquad?) -> [String] {
        let stop: Set<String> = ["the", "and", "for", "what", "who", "how", "does", "can", "with", "best", "use", "are", "has", "have", "that", "this", "which", "should", "about"]
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 && !stop.contains($0) }
        guard let library else { return [] }
        var scored: [(Int, String)] = []
        func consider(_ haystack: String, _ fact: @autoclosure () -> String, bonus: Int = 0) {
            let lower = haystack.lowercased()
            let hits = words.filter { lower.contains($0) }.count
            if hits > 0 { scored.append((hits * 10 + bonus, fact())) }
        }
        for c in library.characters where c.kind != .voiceSet {
            consider("\(c.name) \(c.longName) \(c.className) \(c.kind.rawValue)",
                     "Person: \(c.longName.isEmpty ? c.name : c.longName), \(c.className), \(c.kind.rawValue), \(c.stats.filter { $0.value != "0" }.prefix(6).map { "\($0.name) \($0.value)" }.joined(separator: ", ")). Gear: \(Set(c.loadout.map(\.name)).sorted().prefix(6).joined(separator: ", ")).",
                     bonus: c.kind == .hire ? 3 : 0)
        }
        for item in library.arsenal where item.category != "Uniforms" {
            consider("\(item.name) \(item.devName) \(item.category)", "\(item.category): \(item.name). \(item.values.map { "\($0.name) \($0.value)" }.joined(separator: ", ")).")
        }
        for perk in library.perks.values { consider("\(perk.name) \(perk.text)", "Perk: \(perk.text.replacingOccurrences(of: "\n", with: " "))") }
        for cls in library.classes { consider("\(cls.name) class", "Class \(cls.name): \(cls.growth.map { "\($0.name) \($0.value)" }.joined(separator: ", ")).") }
        for m in library.missions { consider("\(m.name) mission", "Mission \(m.name): enemies \(m.enemyRoster.prefix(6).map { "\($0.value) \($0.name)" }.joined(separator: ", ")).") }
        var out = scored.sorted { $0.0 > $1.0 }.prefix(14).map(\.1)
        if let squad {
            let lines = squad.squad.map { u in "\(u.name): VP \(u.hp) of \(u.maxHP), AP \(u.ap) of \(u.maxAP), skills \(u.skills?.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ") ?? "")." }
            out.insert(contentsOf: ["Current squad:"] + lines + ["Enemies in sight: \(squad.enemies.map(\.name).joined(separator: ", "))."], at: 0)
        }
        return out
    }
}

struct AdvisorView: View {
    @ObservedObject var hub: HubModel
    @ObservedObject var advisor: AdvisorModel
    @ObservedObject private var engine: EngineController
    @ObservedObject private var store: LibraryStore
    @State private var prompt = ""

    init(hub: HubModel, advisor: AdvisorModel) {
        self.hub = hub
        self.advisor = advisor
        self.engine = hub.engine
        self.store = hub.store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Advisor").font(.system(size: 22, weight: .bold, design: .rounded))
                Tag(advisor.modelStatus, color: advisor.modelReady ? .mint : .gray)
                if engine.liveSquad != nil { Tag("Sees your squad", color: .green) }
                Spacer()
            }
            Text("Answers come from \(engine.selectedEdition.shortTitle)'s data, on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if advisor.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(["Compare the Luger and the Colt M1911", "What can a Scout do?", "Who starts with a sniper rifle?"], id: \.self) { sample in
                                Button(sample) { send(sample) }.buttonStyle(.link)
                            }
                        }
                    }
                    ForEach(advisor.messages) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.fromYou ? "You" : "Advisor").font(.system(size: 10.5, weight: .bold)).foregroundStyle(m.fromYou ? .cyan : .mint)
                            Text(m.text).font(.system(size: 12.5)).textSelection(.enabled)
                            if !m.sources.isEmpty {
                                DisclosureGroup("Game data used (\(m.sources.count))") {
                                    Text(m.sources.joined(separator: "\n")).font(.system(size: 10.5)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                .font(.system(size: 10.5))
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(m.fromYou ? 0.03 : 0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                TextField("Ask about a soldier, weapon, perk, class or mission", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(prompt) }
                Button(advisor.isWorking ? "Thinking" : "Ask") { send(prompt) }.disabled(advisor.isWorking || prompt.isEmpty)
            }
        }
        .padding(18)
    }

    private func send(_ text: String) {
        prompt = ""
        Task { await advisor.ask(text, library: store.library, squad: engine.liveSquad) }
    }
}
