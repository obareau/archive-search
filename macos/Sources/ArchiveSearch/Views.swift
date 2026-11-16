import ArchiveCore
import SwiftUI

extension Color {
    /// Ambre sourd de la version web : lisible sur fond sombre comme clair.
    /// L'ambre d'origine. L'interface prend l'accent du thème (`.tint`) ;
    /// cette constante ne sert plus qu'aux réglages par défaut.
    static let amber = archiveAmber
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
    @EnvironmentObject var prefs: Prefs
    @StateObject private var hunt = HuntModel()
    @Local private var showInspector = true
    @Local private var pane: Pane = .results
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

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
                if !model.related.isEmpty || !model.results.isEmpty || !model.pending.isEmpty { infoBar; Divider() }
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
            PlayerPane(item: selected, player: player) { model.showSimilar($0); pane = .results }
                .asSurface(alt: true)
                .inspectorColumnWidth(min: 300, ideal: 420, max: 700)
        }
        // Les feuilles sont des fenêtres à part : elles reçoivent la racine du
        // style explicitement, comme dans AZA.
        .sheet(isPresented: $hunt.showSheet) { HuntSheet(hunt: hunt, search: model).asRoot(prefs) }
        .sheet(isPresented: $hunt.showReport) {
            if let p = hunt.last { HuntReport(p: p, theme: hunt.lastTheme).asRoot(prefs) }
        }
        .sheet(item: Binding(get: { downloads.finished.map(FinishedBox.init) },
                             set: { if $0 == nil { downloads.finished = nil } })) { box in
            DownloadReport(p: box.p, folder: downloads.folder).asRoot(prefs)
        }
        .alert("Enregistrement impossible", isPresented: Binding(get: { library.saveError != nil },
                                                                 set: { if !$0 { library.saveError = nil } })) {
            Button("OK") {}
        } message: { Text(library.saveError ?? "") }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vue", selection: $pane) {
                    Text("Résultats").tag(Pane.results)
                    // Nom court et compteur entre parenthèses : « Robōtariis ép. 12 2 »
                    // se lisait comme un seul nom.
                    Text("\(library.activeProject.count > 16 ? String(library.activeProject.prefix(15)) + "…" : library.activeProject) (\(library.cart.count))").tag(Pane.cart)
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
        .task { await Demo.run(model: model, hunt: hunt, library: library, openSettings: { openSettings() }) { pane = $0 } }
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
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FiltersRow(model: model)
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
            if !model.outcomes.isEmpty || !model.pending.isEmpty { SourcesRow(model: model) }
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
                            .foregroundStyle(.tint).fontWeight(.medium)
                    }
                }
                .asFont(.callout)
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
                                  hunt: model.huntInfo[item.id], showAnalysis: model.filters.hasBPM,
                                  onSimilar: { model.showSimilar($0) }).tag(item.id)
                    }
                    if model.page > 1 || model.hasMore { pager.listRowSeparator(.hidden) }
                }
                .listStyle(.inset)
                .asSurface()
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
                .asSurface()
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

/// Filtres passés à la source elle-même : ils ramènent vingt résultats qui
/// conviennent, au lieu de trier les vingt reçus.
struct FiltersRow: View {
    @ObservedObject var model: SearchModel

    static let durations: [(String, Double?, Double?)] = [
        ("Toute durée", nil, nil), ("< 5 s", nil, 5), ("5 à 30 s", 5, 30), ("30 s à 2 min", 30, 120), ("> 2 min", 120, nil),
    ]
    static let tempos: [(String, Int?, Int?)] = [
        ("Tout tempo", nil, nil), ("60–90 BPM", 60, 90), ("90–110 BPM", 90, 110), ("110–130 BPM", 110, 130),
        ("130–150 BPM", 130, 150), ("> 150 BPM", 150, nil),
    ]
    static let decades: [Int] = Array(stride(from: 1900, through: 2020, by: 10))

    var body: some View {
        if model.usesFreesound || model.usesArchive {
            HStack(spacing: 8) {
                if model.usesFreesound {
                    if model.isAll { Text("Freesound").asFont(.caption).foregroundStyle(.secondary) }
                    Picker("Durée", selection: Binding(
                        get: { Self.durations.firstIndex { $0.1 == model.filters.minDuration && $0.2 == model.filters.maxDuration } ?? 0 },
                        set: { model.filters.minDuration = Self.durations[$0].1; model.filters.maxDuration = Self.durations[$0].2 })) {
                        ForEach(Self.durations.indices, id: \.self) { Text(Self.durations[$0].0).tag($0) }
                    }.labelsHidden().fixedSize()
                    Picker("Tempo", selection: Binding(
                        get: { Self.tempos.firstIndex { $0.1 == model.filters.minBPM && $0.2 == model.filters.maxBPM } ?? 0 },
                        set: { model.filters.minBPM = Self.tempos[$0].1; model.filters.maxBPM = Self.tempos[$0].2 })) {
                        ForEach(Self.tempos.indices, id: \.self) { Text(Self.tempos[$0].0).tag($0) }
                    }.labelsHidden().fixedSize()
                    .help("Tempo estimé par Freesound : utile pour les boucles et la musique, sans valeur pour un son sans rythme")
                    // Étiquettes masquées sélecteur par sélecteur : posé sur la
                    // rangée, labelsHidden() effaçait aussi le libellé de la case.
                    Toggle(isOn: $model.filters.cc0Only) { Text("CC0 seulement") }.toggleStyle(.checkbox)
                        .help("Domaine public : réutilisable sans attribution. Filtré par Freesound, donc vingt résultats CC0 par page")
                }
                if model.usesArchive {
                    if model.isAll { Text("archive.org").asFont(.caption).foregroundStyle(.secondary) }
                    Picker("Décennie", selection: $model.filters.decade) {
                        Text("Toute époque").tag(Int?.none)
                        ForEach(Self.decades, id: \.self) { Text("années \(String($0))").tag(Int?.some($0)) }
                    }.labelsHidden().fixedSize()
                }
                Spacer()
                if !model.effectiveFilters.isEmpty {
                    Button("Sans filtre") { model.filters = SourceFilters() }.buttonStyle(.link).asFont(.caption)
                }
            }
            .controlSize(.small)
        }
    }
}

/// Ce que chaque source a rendu dans une recherche « toutes les sources ».
/// Un clic n'affiche que cette source ; un second clic les remet toutes.
struct SourcesRow: View {
    @Environment(\.archiveStyle) private var style
    @ObservedObject var model: SearchModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Sources").asFont(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .frame(width: style.labelWidth, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Sources.allSources, id: \.self) { src in chip(src) }
                }
            }
        }
    }

    @ViewBuilder private func chip(_ src: String) -> some View {
        if let o = model.outcomes.first(where: { $0.source == src }) {
            let on = model.sourceFilter == src
            Button {
                model.sourceFilter = on ? nil : src
            } label: {
                HStack(spacing: 4) {
                    if o.error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(src)
                    if o.error == nil { Text("\(o.count)").monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .disabled(o.error != nil || o.count == 0)
            .help(o.error ?? String(format: "%d résultat%@ en %.1f s%@ — un clic n'affiche que cette source",
                                    o.count, o.count > 1 ? "s" : "", o.seconds,
                                    o.total.map { " (\($0.formatted()) en tout)" } ?? ""))
        } else if model.pending.contains(src) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(src).foregroundStyle(.secondary)
            }
            .asFont(.callout)
            .padding(.horizontal, 6)
            .help(src == "gutenberg" ? "Gutenberg met 15 à 30 s : ses résultats s'ajouteront à l'arrivée" : "en attente")
        }
    }
}

struct RelatedRow: View {
    @Environment(\.archiveStyle) private var style
    let title: String
    let terms: [String]
    let action: (String) -> Void

    var body: some View {
        if !terms.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).asFont(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    .frame(width: style.labelWidth, alignment: .leading)
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
    /// Montrer BPM et tonalité sur la ligne : seulement quand on filtre par
    /// tempo. Sinon ils mentent sur un son sans rythme.
    var showAnalysis = false
    var onSimilar: ((Item) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).asFont(.headline).lineLimit(2)
                Text(([item.creator, item.year, item.type, item.source] + (showAnalysis ? [item.analysisLabel ?? ""] : []))
                    .filter { !$0.isEmpty && $0 != "N/A" }
                    .joined(separator: " · "))
                    .asFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !item.description.isEmpty {
                    Text(item.description).asFont(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if let h = hunt {
                    Text("trouvé par " + h.hits.joined(separator: ", ")
                         + (h.rel.map { String(format: " · proximité %.2f", $0) } ?? ""))
                        .asFont(.caption).foregroundStyle(.tint)
                }
                HStack(spacing: 6) {
                    if isNew {
                        Text("nouveau").asFont(.caption2).fontWeight(.bold)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.black)
                            .help("Apparu depuis le passage précédent de cette recherche")
                    }
                    LicenseBadge(license: item.license, long: false)
                    if taken {
                        Label("glisser vers le DAW", systemImage: "hand.draw").labelStyle(.iconOnly)
                            .asFont(.caption2).foregroundStyle(.secondary)
                            .help("Fichier sur le disque : glisser la vignette dépose le fichier lui-même (Logic, Ableton, Finder)")
                        Text("déjà pris").asFont(.caption2).fontWeight(.semibold)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
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
            if isNew { Rectangle().fill(.tint).frame(width: 3).offset(x: -8) }
        }
        .contextMenu {
            if item.source == "freesound", let onSimilar {
                Button("Sons similaires") { onSimilar(item) }
                Divider()
            }
            if let f = Journal.live(item).1.first {
                Button("Afficher le fichier dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            }
            if let u = URL(string: item.url), !item.url.isEmpty {
                Link("Ouvrir la page", destination: u)
                Button("Copier le lien") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                }
            }
        }
    }

    /// Le glisser part de la VIGNETTE seulement. Posé sur toute la ligne,
    /// `.onDrag` captait le clic avant les boutons : ➕ et ☆ ne répondaient
    /// plus (constaté le 2026-11-16).
    @ViewBuilder private var thumb: some View {
        thumbImage
            .onDrag { Drag.provider(for: item) } preview: {
                thumbImage.frame(width: 96, height: 68)
            }
            .help(taken ? "Glisser le fichier vers Logic, Ableton ou le Finder"
                  : Downloader.isDownloadable(item) ? "Glisser : le fichier est téléchargé au moment du dépôt (Logic, Ableton, Finder)"
                  : "Glisser le lien de la page : cette source ne donne pas de fichier")
    }

    @ViewBuilder private var thumbImage: some View {
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
                    .asFont(.caption2).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(color)
                    .overlay(Capsule().strokeBorder(color.opacity(0.6)))
                if long { Text(tip).asFont(.caption).foregroundStyle(.secondary) }
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
