import ArchiveCore
import SwiftUI

/// La fouille. Une à la fois. Rien n'est écrit dans l'historique (quinze termes
/// y enterreraient un mois de recherches) et rien ne part au panier tout seul.
@MainActor
final class HuntModel: ObservableObject {
    @Published var theme = ""
    @Published var termsText = ""
    @Published var model: Hunt.Model = .apple
    @Published private(set) var ollama: [String] = []
    @Published var sources: Set<String> = Set(Hunt.defaultSources)
    @Published private(set) var proposing = false
    @Published private(set) var note: String?
    @Published private(set) var english: String?

    @Published private(set) var running = false
    @Published private(set) var progress = Hunt.Progress()
    /// Le dernier rapport complet, pour « Voir le rendement ».
    @Published private(set) var last: Hunt.Progress?
    @Published private(set) var lastTheme = ""
    @Published var showSheet = false
    @Published var showReport = false

    private var task: Task<Void, Never>?

    var models: [Hunt.Model] { [.apple] + ollama.map { .ollama($0) } }
    var terms: [String] {
        Hunt.cleanTerms(termsText.split(whereSeparator: { $0 == "\n" || $0 == "," }).map(String.init))
    }

    func open() {
        showSheet = true
        Task { ollama = await Hunt.ollamaModels() }
    }

    func propose() {
        let t = theme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !proposing else { return }
        proposing = true
        note = nil
        Task {
            let f = await Hunt.expandField(t, model: model)
            termsText = f.terms.joined(separator: "\n")
            english = f.english == t ? nil : f.english
            note = f.note
            proposing = false
        }
    }

    func start(into search: SearchModel) {
        let terms = self.terms
        let theme = self.theme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !terms.isEmpty, !sources.isEmpty else { return }
        showSheet = false
        running = true
        lastTheme = theme
        progress = Hunt.Progress()
        progress.steps = terms.count + Hunt.pass2Terms + 1
        let order = Hunt.defaultSources + ["gutenberg"]
        let srcs = order.filter(sources.contains)
        // Requête de classement : le thème traduit (mesuré meilleur que le
        // champ ou le thème français), sinon le champ.
        let query = english
        task = Task {
            let p = await Hunt.run(theme: theme.isEmpty ? terms.joined(separator: " ") : theme,
                                   terms: terms, sources: srcs, queryText: query) { p in
                Task { @MainActor [weak self] in
                    guard let self, self.running else { return }
                    self.progress = p
                }
            }
            running = false
            progress = p
            last = p
            search.showHunt(p.results, theme: theme.isEmpty ? terms.first ?? "" : theme)
        }
    }

    func cancel() { task?.cancel() }

    var fraction: Double { progress.steps > 0 ? min(1, Double(progress.step) / Double(progress.steps)) : 0 }
}

struct HuntSheet: View {
    @ObservedObject var hunt: HuntModel
    @ObservedObject var search: SearchModel
    @FocusState private var themeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fouiller un thème").font(.title2.weight(.semibold))
            Text("Un modèle déplie le thème en champ lexical, surtout en anglais. Chaque terme interroge les sources, puis le vocabulaire du fonds lui-même relance une seconde passe. Le tout est classé par proximité au thème.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("brume et cornes de brume sur une côte de nuit", text: $hunt.theme)
                .textFieldStyle(.roundedBorder).focused($themeFocused)
                .onSubmit { hunt.propose() }
            HStack {
                Picker("Modèle", selection: $hunt.model) {
                    ForEach(hunt.models, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Button {
                    hunt.propose()
                } label: {
                    if hunt.proposing { ProgressView().controlSize(.small) } else { Text("Proposer un champ") }
                }
                .disabled(hunt.theme.trimmingCharacters(in: .whitespaces).isEmpty || hunt.proposing)
                Spacer()
            }
            if let note = hunt.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let en = hunt.english {
                Text("thème compris : « \(en) » — c'est lui qui classe la récolte").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Champ — un terme par ligne, à corriger : le modèle en propose toujours deux ou trois à jeter")
                    .font(.caption.weight(.medium))
                TextEditor(text: $hunt.termsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 160, maxHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }

            HStack(spacing: 14) {
                Text("Sources").font(.caption.weight(.medium))
                ForEach(Hunt.defaultSources + ["gutenberg"], id: \.self) { s in
                    Toggle(s, isOn: Binding(get: { hunt.sources.contains(s) },
                                            set: { if $0 { hunt.sources.insert(s) } else { hunt.sources.remove(s) } }))
                        .toggleStyle(.checkbox)
                        .help(s == "gutenberg" ? "15 à 30 s par requête : hors du lot par défaut" : "")
                }
            }
            .font(.callout)

            HStack {
                let n = hunt.terms.count
                Text(n == 0 ? "Aucun terme" : "\(n) terme\(n > 1 ? "s" : "") × \(hunt.sources.count) source\(hunt.sources.count > 1 ? "s" : ""), plus \(Hunt.pass2Terms) du fonds — compter une à trois minutes")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { hunt.showSheet = false }.keyboardShortcut(.cancelAction)
                Button("Lancer la fouille") { hunt.start(into: search) }
                    .buttonStyle(.borderedProminent).tint(.amber)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hunt.terms.isEmpty || hunt.sources.isEmpty || hunt.running)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear { themeFocused = true }
    }
}

/// Progression de la fouille, en bas de la fenêtre.
struct HuntStrip: View {
    @ObservedObject var hunt: HuntModel

    var body: some View {
        if hunt.running {
            let p = hunt.progress
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("🔎 \(p.step)/\(p.steps)").monospacedDigit()
                    Text(p.current).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(p.harvested) documents").monospacedDigit().foregroundStyle(.secondary)
                    if !p.errors.isEmpty { Text("\(p.errors.count) source(s) hors rotation").foregroundStyle(.orange) }
                    Button("Arrêter") { hunt.cancel() }.controlSize(.small)
                }
                .font(.callout)
                ProgressView(value: hunt.fraction).tint(.amber)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// « Voir le rendement » : quels termes ont donné, lesquels n'ont rien rendu.
/// Sans ça, le champ du modèle reste invérifiable.
struct HuntReport: View {
    let p: Hunt.Progress
    let theme: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rendement de la fouille").font(.title2.weight(.semibold))
            Text("« \(theme) » — \(p.harvested) documents récoltés, \(p.results.count) classés").foregroundStyle(.secondary)
            Text(p.ranking).font(.caption).foregroundStyle(.secondary)
            Table(p.report) {
                TableColumn("Terme") { y in
                    Text(y.origin == "fonds" ? "↳ \(y.term)" : y.term)
                        .foregroundStyle(y.found == 0 ? .red : .primary)
                }
                TableColumn("Origine") { y in Text(y.origin == "fonds" ? "du fonds" : "champ").foregroundStyle(.secondary) }
                    .width(70)
                TableColumn("Trouvés") { y in Text("\(y.found)").monospacedDigit() }.width(60)
                TableColumn("Neufs") { y in Text("\(y.new)").monospacedDigit() }.width(50)
            }
            .frame(minHeight: 280)
            if !p.errors.isEmpty {
                ForEach(p.errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
            }
            HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560)
    }
}
