import ArchiveCore
import SwiftUI

extension Color {
    /// Ambre sourd de la version web : lisible sur fond sombre comme clair.
    static let amber = Color(red: 0xC9 / 255, green: 0x89 / 255, blue: 0x3F / 255)
    static let licOK = Color(red: 0x4F / 255, green: 0x9A / 255, blue: 0x63 / 255)
    static let licBad = Color(red: 0xC0 / 255, green: 0x56 / 255, blue: 0x4A / 255)
}

enum Pane: String, CaseIterable {
    case results, cart, favorites, journal, history
}

struct ContentView: View {
    @StateObject private var model = SearchModel()
    @StateObject private var player = PlayerModel()
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var downloads: DownloadModel
    @EnvironmentObject var watch: WatchModel
    @StateObject private var hunt = HuntModel()
    @Local private var showInspector = true
    @Local private var pane: Pane = .results
    @FocusState private var searchFocused: Bool

    /// L'item sélectionné, où qu'il soit affiché.
    private var selected: Item? {
        guard let id = model.selection else { return nil }
        return model.results.first { $0.id == id }
            ?? library.cart.first { $0.id == id }
            ?? library.favorites.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            switch pane {
            case .results:
                if !model.related.isEmpty || !model.results.isEmpty { infoBar; Divider() }
                resultsList
            case .cart:
                CartBar(); Divider()
                listOf(library.cart, empty: "Panier vide", hint: "➕ sur un résultat pour l'y mettre. Il se télécharge d'un coup, avec sa fiche de crédits.")
            case .favorites:
                listOf(library.favorites, empty: "Aucun favori", hint: "☆ sur un résultat pour le garder sous la main.")
            case .journal:
                JournalView()
            case .history:
                HistoryView(model: model) { pane = .results }
            }
            HuntStrip(hunt: hunt)
            DownloadStrip()
        }
        .frame(minWidth: 640, minHeight: 420)
        .inspector(isPresented: $showInspector) {
            PlayerPane(item: selected, player: player)
                .inspectorColumnWidth(min: 300, ideal: 420, max: 700)
        }
        .sheet(isPresented: $hunt.showSheet) { HuntSheet(hunt: hunt, search: model) }
        .sheet(isPresented: $hunt.showReport) {
            if let p = hunt.last { HuntReport(p: p, theme: hunt.lastTheme) }
        }
        .sheet(item: Binding(get: { downloads.finished.map(FinishedBox.init) },
                             set: { if $0 == nil { downloads.finished = nil } })) { box in
            DownloadReport(p: box.p, folder: downloads.folder)
        }
        .alert("Enregistrement impossible", isPresented: Binding(get: { library.saveError != nil },
                                                                 set: { if !$0 { library.saveError = nil } })) {
            Button("OK") {}
        } message: { Text(library.saveError ?? "") }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vue", selection: $pane) {
                    Text("Résultats").tag(Pane.results)
                    Text("Panier \(library.cart.count)").tag(Pane.cart)
                    Text("Favoris \(library.favorites.count)").tag(Pane.favorites)
                    Text("Journal").tag(Pane.journal)
                    // Du texte, pas un Label : dans un segment de barre d'outils,
                    // le Label n'affiche que son icône.
                    Text(watch.watchedCount > 0 ? "Historique · \(watch.watchedCount) 👁" : "Historique").tag(Pane.history)
                }
                .pickerStyle(.segmented)
                .help("Résultats (⌘1), panier (⌘2), favoris (⌘3), journal des téléchargements (⌘4), historique et veille (⌘5)")
            }
            ToolbarItemGroup {
                Button { hunt.open() } label: { Label("Fouiller", systemImage: "binoculars") }
                    .help("Fouiller un thème : un champ lexical, plusieurs passes, un classement par proximité (⇧⌘F)")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(hunt.running)
                Button { model.surprise() } label: { Label("Surprise-moi", systemImage: "dice") }
                    .help("Un item au hasard dans une collection vintage d'archive.org")
                Button { showInspector.toggle() } label: { Label("Lecteur", systemImage: "sidebar.right") }
                    .help("Afficher ou masquer le lecteur")
            }
        }
        .navigationTitle("Archive Search")
        .navigationSubtitle(model.statusLine)
        .onAppear { searchFocused = true }
        .onChange(of: model.shownLabel) { pane = .results }
        .onChange(of: watch.pendingReplay) {
            if let q = watch.pendingReplay { model.replay(q); pane = .results; watch.pendingReplay = nil }
        }
        .background {
            // Raccourcis ⌘1-⌘4 pour changer de vue.
            ForEach(Array(Pane.allCases.enumerated()), id: \.offset) { i, p in
                Button("") { pane = p }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).hidden()
            }
        }
        .onChange(of: model.selection) { if model.selection != nil { showInspector = true } }
        .focusedSceneValue(\.searchModel, model)
    }

    // ── Barre de recherche ───────────────────────────────────────────────

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Source", selection: $model.source) {
                    ForEach(Sources.all, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                TextField("Chercher : films, sons, livres, images…", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { model.search(); pane = .results }
                Button(model.source == "loc.gov" ? "Ouvrir ↗" : "Chercher") { model.search(); pane = .results }
                    .buttonStyle(.borderedProminent).tint(.amber)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.isArchive {
                HStack(spacing: 8) {
                    Picker("Type", selection: $model.type) {
                        ForEach(SearchType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.fixedSize()
                    Picker("Collection", selection: $model.collection) {
                        ForEach(Collection.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.fixedSize()
                    Picker("Tri", selection: $model.sort) {
                        ForEach(SortOption.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.fixedSize()
                    Spacer()
                }
                .labelsHidden().controlSize(.small)
            }
        }
        .padding(12)
    }

    // ── Propositions connexes, filtre de licence, messages ───────────────

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            RelatedRow(title: "Affiner", terms: model.related.keywords, action: model.searchRelated)
            RelatedRow(title: "Auteur", terms: model.related.creators, action: model.searchRelated)
            RelatedRow(title: "Année", terms: model.related.years) { y in
                // Rester dans l'époque : le thème + l'année.
                model.searchRelated("\(model.text.trimmingCharacters(in: .whitespaces)) \(y)")
            }
            if !model.results.isEmpty {
                HStack {
                    Toggle("Réutilisable seulement", isOn: $model.onlyReusable)
                        .toggleStyle(.checkbox)
                        .help("Masque les licences restrictives ET inconnues : « inconnu » n'est pas « libre ».")
                    if model.onlyReusable && model.hiddenCount > 0 {
                        Text("\(model.hiddenCount) carte\(model.hiddenCount > 1 ? "s" : "") masquée\(model.hiddenCount > 1 ? "s" : "")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isHunt && hunt.last != nil {
                        Button("Voir le rendement") { hunt.showReport = true }.controlSize(.small)
                    }
                    if !model.newIDs.isEmpty {
                        Text("✦ \(model.newIDs.count) nouveauté\(model.newIDs.count > 1 ? "s" : "") depuis la dernière fois")
                            .foregroundStyle(Color.amber).fontWeight(.medium)
                    }
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // ── Résultats ────────────────────────────────────────────────────────

    @ViewBuilder private var resultsList: some View {
        ZStack {
            if let err = model.error {
                ContentUnavailableView {
                    Label("La source n'a pas répondu", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(err).textSelection(.enabled)
                } actions: {
                    Button("Réessayer") { model.search(page: model.page) }
                }
            } else if model.results.isEmpty && !model.loading {
                ContentUnavailableView {
                    Label(model.notice == nil ? "Archive Search" : "Rien à montrer", systemImage: "archivebox")
                } description: {
                    Text(model.notice ?? "Films vintage, audio, livres et images en accès libre — archive.org, Gutenberg, Wikimedia Commons, LibriVox, Freesound.")
                }
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visible) { item in
                        ResultRow(item: item, taken: library.taken.contains(item.key), isNew: model.isNew(item),
                                  hunt: model.huntInfo[item.id]).tag(item.id)
                    }
                    if model.page > 1 || model.hasMore { pager.listRowSeparator(.hidden) }
                }
                .listStyle(.inset)
            }
            if model.loading {
                ProgressView().controlSize(.large)
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func listOf(_ items: [Item], empty: String, hint: String) -> some View {
        if items.isEmpty {
            ContentUnavailableView(empty, systemImage: "tray", description: Text(hint))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $model.selection) {
                ForEach(items) { item in
                    ResultRow(item: item, taken: library.taken.contains(item.key)).tag(item.id)
                }
            }
            .listStyle(.inset)
        }
    }

    private var pager: some View {
        HStack {
            Button("◀ Précédent") { model.search(page: model.page - 1) }.disabled(model.page <= 1)
            Spacer()
            Text("page \(model.page)").foregroundStyle(.secondary)
            Spacer()
            Button("Suivant ▶") { model.search(page: model.page + 1) }.disabled(!model.hasMore)
        }
        .padding(.vertical, 8)
    }
}

struct RelatedRow: View {
    let title: String
    let terms: [String]
    let action: (String) -> Void

    var body: some View {
        if !terms.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(terms, id: \.self) { t in
                            Button(t) { action(t) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

struct FinishedBox: Identifiable {
    let p: Downloader.Progress
    let id = UUID()
}

struct ResultRow: View {
    let item: Item
    var taken = false
    var isNew = false
    var hunt: (hits: [String], rel: Double?)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline).lineLimit(2)
                Text([item.creator, item.year, item.type, item.source].filter { !$0.isEmpty && $0 != "N/A" }
                    .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !item.description.isEmpty {
                    Text(item.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if let h = hunt {
                    Text("trouvé par " + h.hits.joined(separator: ", ")
                         + (h.rel.map { String(format: " · proximité %.2f", $0) } ?? ""))
                        .font(.caption).foregroundStyle(Color.amber)
                }
                HStack(spacing: 6) {
                    if isNew {
                        Text("nouveau").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.amber, in: Capsule())
                            .foregroundStyle(.black)
                            .help("Apparu depuis le passage précédent de cette recherche")
                    }
                    LicenseBadge(license: item.license, long: false)
                    if taken {
                        Text("déjà pris").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.amber.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.amber)
                            .help("Le fichier est déjà sur le disque : le reprendre ne redemandera rien au réseau.")
                    }
                }
            }
            Spacer(minLength: 0)
            ItemButtons(item: item)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            // Liseré ambre, comme la version web.
            if isNew { Rectangle().fill(Color.amber).frame(width: 3).offset(x: -8) }
        }
        .contextMenu {
            if let u = URL(string: item.url), !item.url.isEmpty {
                Link("Ouvrir la page", destination: u)
                Button("Copier le lien") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                }
            }
        }
    }

    @ViewBuilder private var thumb: some View {
        let box = RoundedRectangle(cornerRadius: 5)
        if let u = URL(string: item.thumbnail), !item.thumbnail.isEmpty {
            AsyncImage(url: u) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { box.fill(.quaternary) }
            }
            .frame(width: 96, height: 68).clipShape(box)
        } else {
            box.fill(.quaternary).frame(width: 96, height: 68)
                .overlay(Image(systemName: icon).foregroundStyle(.secondary))
        }
    }

    private var icon: String {
        switch item.source {
        case "gutenberg": "book"
        case "librivox": "headphones"
        case "freesound": "waveform"
        default: "film"
        }
    }
}

/// Vert réutilisable, rouge restrictif, gris inconnu. Rien quand la source ne
/// dit rien (Gutenberg, LibriVox) et qu'on n'a pas de licence du tout.
struct LicenseBadge: View {
    let license: License?
    let long: Bool

    var body: some View {
        if let l = license {
            let (color, text, tip): (Color, String, String) = switch l.free {
            case true: (.licOK, l.label, "Réutilisable, attribution selon la licence")
            case false: (.licBad, l.label, "Restrictive : pas de modification et/ou pas d'usage commercial")
            default: (.secondary, l.code.isEmpty ? "licence inconnue" : l.label,
                      "Inconnue n'est pas libre : vérifier avant de réutiliser")
            }
            HStack(spacing: 6) {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(color)
                    .overlay(Capsule().strokeBorder(color.opacity(0.6)))
                if long { Text(tip).font(.caption).foregroundStyle(.secondary) }
            }
            .help(tip)
        }
    }
}

// Pour les commandes de menu (⌘F, ⌘R).
struct SearchModelKey: FocusedValueKey { typealias Value = SearchModel }
extension FocusedValues {
    var searchModel: SearchModel? {
        get { self[SearchModelKey.self] }
        set { self[SearchModelKey.self] = newValue }
    }
}
