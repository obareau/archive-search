import ArchiveCore
import SwiftUI

extension Color {
    /// Ambre sourd de la version web : lisible sur fond sombre comme clair.
    static let amber = Color(red: 0xC9 / 255, green: 0x89 / 255, blue: 0x3F / 255)
    static let licOK = Color(red: 0x4F / 255, green: 0x9A / 255, blue: 0x63 / 255)
    static let licBad = Color(red: 0xC0 / 255, green: 0x56 / 255, blue: 0x4A / 255)
}

struct ContentView: View {
    @StateObject private var model = SearchModel()
    @StateObject private var player = PlayerModel()
    @Local private var showInspector = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if !model.related.isEmpty || !model.results.isEmpty { infoBar; Divider() }
            resultsList
        }
        .frame(minWidth: 640, minHeight: 420)
        .inspector(isPresented: $showInspector) {
            PlayerPane(item: model.selectedItem, player: player)
                .inspectorColumnWidth(min: 300, ideal: 420, max: 700)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.surprise() } label: { Label("Surprise-moi", systemImage: "dice") }
                    .help("Un item au hasard dans une collection vintage d'archive.org")
                Button { showInspector.toggle() } label: { Label("Lecteur", systemImage: "sidebar.right") }
                    .help("Afficher ou masquer le lecteur")
            }
        }
        .navigationTitle("Archive Search")
        .navigationSubtitle(model.statusLine)
        .onAppear { searchFocused = true }
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
                    .onSubmit { model.search() }
                Button(model.source == "loc.gov" ? "Ouvrir ↗" : "Chercher") { model.search() }
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
                        ResultRow(item: item).tag(item.id)
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

struct ResultRow: View {
    let item: Item

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
                LicenseBadge(license: item.license, long: false)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
