import AppKit
import ArchiveCore
import SwiftUI

/// Panier, favoris et « déjà pris ». Fichiers JSON dans Application Support,
/// au format de la version web.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var cart: [Item] = Store.readList(.cart)
    @Published private(set) var favorites: [Item] = Store.readList(.favorites)
    /// Clés dont un fichier est encore sur le disque.
    @Published private(set) var taken: Set<String> = Journal.takenKeys()
    @Published var saveError: String?
    /// Les projets, et celui dont le panier est affiché.
    @Published private(set) var projects: [Projects.Project] = Projects.load().projects
    @Published private(set) var activeProject: String = Projects.load().active

    var active: Projects.Project? { projects.first { $0.name == activeProject } }

    private func syncProjects() {
        let st = Projects.load()
        projects = st.projects; activeProject = st.active
        cart = st.activeProject.items
    }

    private func guarded(_ f: () throws -> Void) {
        do { try f() } catch { saveError = "Projet non enregistré : \(error.localizedDescription)" }
        syncProjects()
    }

    func selectProject(_ name: String) { guarded { try Projects.select(name) } }
    func createProject(_ name: String) { guarded { try Projects.create(name) } }
    func renameProject(_ old: String, to new: String) { guarded { try Projects.rename(old, to: new) } }
    func deleteProject(_ name: String) { guarded { try Projects.delete(name) } }
    func setFolder(_ folder: URL) { guarded { try Projects.setFolder(folder, for: activeProject) } }

    func items(_ l: Store.List) -> [Item] { l == .cart ? cart : favorites }

    func contains(_ l: Store.List, _ item: Item) -> Bool { items(l).contains { $0.key == item.key } }

    func toggle(_ l: Store.List, _ item: Item) {
        var list = items(l)
        if let i = list.firstIndex(where: { $0.key == item.key }) { list.remove(at: i) } else { list.append(item) }
        set(l, list)
    }

    func add(_ l: Store.List, _ new: [Item]) {
        var list = items(l)
        let have = Set(list.map(\.key))
        list.append(contentsOf: new.filter { !have.contains($0.key) })
        set(l, list)
    }

    func clear(_ l: Store.List) { set(l, []) }

    private func set(_ l: Store.List, _ list: [Item]) {
        if l == .cart { cart = list } else { favorites = list }
        do { try Store.writeList(l, list) } catch { saveError = "Liste non enregistrée : \(error.localizedDescription)" }
        if l == .cart { syncProjects() }
    }

    func reload() {
        syncProjects()
        favorites = Store.readList(.favorites)
        refreshTaken()
    }

    func refreshTaken() { taken = Journal.takenKeys() }
}

/// Le lot en cours. Un seul à la fois.
@MainActor
final class DownloadModel: ObservableObject {
    @Published private(set) var progress = Downloader.Progress()
    @Published private(set) var running = false
    @Published private(set) var folder: URL?
    /// Bilan du dernier lot, à montrer une fois terminé.
    @Published var finished: Downloader.Progress?
    private var task: Task<Void, Never>?

    /// Dialogue de dossier natif. Dans la version web, il fallait un navigateur
    /// de dossiers fait main (le serveur était ailleurs) ; ici c'est le disque local.
    func chooseAndStart(_ items: [Item], library: LibraryModel) {
        guard !running, !items.isEmpty else { return }
        let root = Downloader.defaultRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // Chaque projet se rouvre sur son dossier : l'épisode 12 retombe dans
        // le dossier de l'épisode 12, sa fiche de crédits s'y complète.
        let remembered = library.active?.folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let r = remembered, FileManager.default.fileExists(atPath: r.path) { panel.directoryURL = r } else { panel.directoryURL = root }
        panel.prompt = "Télécharger ici"
        panel.message = "Dossier du projet « \(library.activeProject) ». Depuis « \(root.lastPathComponent) » sans sous-dossier, le lot va dans un sous-dossier daté."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        if chosen.standardizedFileURL.path != root.standardizedFileURL.path { library.setFolder(chosen) }
        start(items, into: Downloader.batchFolder(chosen: chosen), library: library)
    }

    func start(_ items: [Item], into folder: URL, library: LibraryModel) {
        running = true
        self.folder = folder
        progress = Downloader.Progress()
        progress.total = items.count
        task = Task {
            let final = await Downloader.run(items, into: folder) { p in
                Task { @MainActor [weak self] in
                    guard let self, self.running else { return }
                    self.progress = p
                }
            }
            running = false
            progress = final
            finished = final
            library.refreshTaken()
        }
    }

    func cancel() { task?.cancel() }

    var fraction: Double {
        guard progress.total > 0 else { return 0 }
        let inFile = progress.bytesTotal > 0 ? Double(progress.bytes) / Double(progress.bytesTotal) : 0
        return min(1, (Double(progress.done) + inFile) / Double(progress.total))
    }
}

// ── Vues ──────────────────────────────────────────────────────────────────

/// Les deux boutons de chaque ligne : panier et favori.
struct ItemButtons: View {
    let item: Item
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        HStack(spacing: 2) {
            let inCart = library.contains(.cart, item)
            Button { library.toggle(.cart, item) } label: {
                Image(systemName: inCart ? "basket.fill" : "plus.circle")
                    .foregroundStyle(inCart ? Color.amber : .secondary)
            }
            .help(inCart ? "Retirer de « \(library.activeProject) »" : "Ajouter à « \(library.activeProject) »")
            let fav = library.contains(.favorites, item)
            Button { library.toggle(.favorites, item) } label: {
                Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? Color.amber : .secondary)
            }
            .help(fav ? "Retirer des favoris" : "Ajouter aux favoris")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }
}

/// Barre d'actions du panier.
struct CartBar: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var downloads: DownloadModel
    @Local private var copying = false
    @Local private var copied: String?
    @Local private var confirmClear = false
    @Local private var naming: NameAsk?
    @Local private var nameField = ""
    @Local private var confirmDelete = false

    enum NameAsk: Identifiable { case create, rename; var id: Int { self == .create ? 0 : 1 } }

    var body: some View {
        let items = library.cart
        let downloadable = items.filter(Downloader.isDownloadable).count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Projet", selection: Binding(get: { library.activeProject }, set: { library.selectProject($0) })) {
                    ForEach(library.projects) { p in Text("\(p.name) (\(p.items.count))").tag(p.name) }
                }
                .labelsHidden().fixedSize()
                .help("Chaque projet a son panier, sa fiche de crédits et son dossier de téléchargement")
                Menu {
                    Button("Nouveau projet…") { nameField = ""; naming = .create }
                    Button("Renommer « \(library.activeProject) »…") { nameField = library.activeProject; naming = .rename }
                    Divider()
                    Button("Copier les crédits en Markdown") {
                        if let p = library.active {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Projects.creditsMarkdown(p), forType: .string)
                            copied = "Crédits de « \(p.name) » copiés en Markdown (\(p.items.count) item\(p.items.count > 1 ? "s" : ""))."
                        }
                    }
                    .disabled(items.isEmpty)
                    if let f = library.active?.folder {
                        Button("Afficher le dossier du projet") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)])
                        }
                    }
                    Divider()
                    Button("Supprimer « \(library.activeProject) »…", role: .destructive) { confirmDelete = true }
                        .disabled(library.projects.count < 2)
                } label: { Image(systemName: "folder.badge.gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
                Divider().frame(height: 18)
                Button {
                    downloads.chooseAndStart(items, library: library)
                } label: { Label("Télécharger…", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).tint(.amber)
                    .disabled(items.isEmpty || downloads.running)
                Button {
                    copyLinks(items)
                } label: { Label(copying ? "Liens…" : "Copier les liens", systemImage: "link") }
                    .disabled(items.isEmpty || copying)
                    .help("Un lien par ligne : .torrent d'abord pour archive.org, sinon le fichier, sinon la page")
                Spacer()
                Button("Vider le panier", role: .destructive) { confirmClear = true }
                    .disabled(items.isEmpty)
            }
            Text(downloadable == items.count
                 ? "\(items.count) item\(items.count > 1 ? "s" : "")"
                 : "\(items.count) items, dont \(items.count - downloadable) sans fichier téléchargeable (Gutenberg, Wikimedia, LibriVox ne renvoient qu'une page)")
                .font(.caption).foregroundStyle(.secondary)
            if let copied { Text(copied).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .alert(naming == .rename ? "Renommer le projet" : "Nouveau projet",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Nom du projet", text: $nameField)
            Button(naming == .rename ? "Renommer" : "Créer") {
                if naming == .rename { library.renameProject(library.activeProject, to: nameField) }
                else { library.createProject(nameField) }
                naming = nil
            }
            Button("Annuler", role: .cancel) { naming = nil }
        } message: {
            Text(naming == .rename ? "Les items et le dossier restent attachés au projet." : "Le nouveau projet devient le panier actif.")
        }
        .confirmationDialog("Supprimer « \(library.activeProject) » ?", isPresented: $confirmDelete) {
            Button("Supprimer le projet (\(items.count) item\(items.count > 1 ? "s" : ""))", role: .destructive) {
                library.deleteProject(library.activeProject)
            }
        } message: {
            Text("La liste disparaît ; les fichiers déjà téléchargés et leur fiche de crédits restent sur le disque.")
        }
        .confirmationDialog("Vider le panier ?", isPresented: $confirmClear) {
            Button("Vider (\(items.count))", role: .destructive) { library.clear(.cart) }
        } message: {
            Text("Les fichiers déjà téléchargés restent sur le disque.")
        }
    }

    private func copyLinks(_ items: [Item]) {
        copying = true
        Task {
            var lines: [String] = []
            for item in items {
                let l = await Downloader.shareLink(item)
                lines.append(l.url)
                // Un par un, et pas trop vite : c'est le même serveur.
                try? await Task.sleep(for: .milliseconds(300))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            copied = "\(lines.count) lien\(lines.count > 1 ? "s" : "") copié\(lines.count > 1 ? "s" : "")."
            copying = false
        }
    }
}

/// Progression du lot, en bas de la fenêtre.
struct DownloadStrip: View {
    @EnvironmentObject var downloads: DownloadModel

    var body: some View {
        if downloads.running {
            let p = downloads.progress
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("⬇ \(p.done)/\(p.total)").monospacedDigit()
                    Text(p.current).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    if p.bytesTotal > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: p.bytesTotal, countStyle: .file))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    if p.attempt > 1 { Text("essai \(p.attempt)/\(Downloader.retries)").foregroundStyle(.orange) }
                    Button("Arrêter") { downloads.cancel() }.controlSize(.small)
                }
                .font(.callout)
                ProgressView(value: downloads.fraction).tint(.amber)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// Bilan d'un lot terminé.
struct DownloadReport: View {
    let p: Downloader.Progress
    let folder: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(p.cancelled ? "Lot arrêté" : p.errors.isEmpty ? "Lot terminé" : "Lot terminé, avec des refus")
                .font(.title2.weight(.semibold))
            Text("\(p.written.count) fichier\(p.written.count > 1 ? "s" : "") en place sur \(p.total)"
                 + (p.reused.isEmpty ? "" : ", dont \(p.reused.count) repris sans réseau") + ".")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("Écrits", p.written, "checkmark.circle", .green)
                    section("Repris", p.reused, "arrow.triangle.2.circlepath", .secondary)
                    section("En aperçu mp3, pas l'original", p.previews, "waveform.badge.exclamationmark", .orange)
                    section("Écartés", p.errors, "xmark.circle", .red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            if p.creditsFailed {
                Label("CREDITS.txt n'a pas pu être écrit dans ce dossier.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                if let folder {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String], _ icon: String, _ color: Color) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon).foregroundStyle(color).font(.headline)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}

/// Le journal : ce qui est rentré sur le disque, et où.
struct JournalView: View {
    @EnvironmentObject var library: LibraryModel
    @Local private var entries: [Journal.Listed] = Journal.list()

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Journal vide", systemImage: "tray",
                                       description: Text("Chaque fichier téléchargé y est noté, avec tous les endroits où il a été rangé."))
            } else {
                List(entries) { e in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.entry.title).font(.headline).lineLimit(1)
                            Text([e.entry.source, e.entry.creator, e.entry.license].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(e.missing ? e.entry.paths : e.livePaths, id: \.self) { path in
                                Text(path).font(.caption.monospaced()).foregroundStyle(e.missing ? .red : .secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(String(e.entry.at.prefix(10))).font(.caption).monospacedDigit()
                            if e.missing {
                                Text("disparu").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                            } else {
                                Button("Afficher") {
                                    NSWorkspace.shared.activateFileViewerSelecting(e.livePaths.map { URL(fileURLWithPath: $0) })
                                }.controlSize(.small)
                                if e.livePaths.count > 1 {
                                    Text("\(e.livePaths.count) copies").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { entries = Journal.list() }
        .onChange(of: library.taken) { entries = Journal.list() }
    }
}

/// Reprise des fichiers de la version web (panier, favoris, journal, historique).
@MainActor
func importLegacyData(library: LibraryModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Importer"
    panel.message = "Choisir le dossier qui contient cart.json, favorites.json, downloads.json (copie de ~/.local/share/archive-search de l'ancien serveur)."
    let legacy = Paths.legacyDataDir
    if FileManager.default.fileExists(atPath: legacy.path) { panel.directoryURL = legacy }
    guard panel.runModal() == .OK, let dir = panel.url else { return }
    let report = Store.importLegacy(from: dir)
    library.reload()
    let alert = NSAlert()
    alert.messageText = report.isEmpty ? "Rien à importer" : "Import terminé"
    alert.informativeText = report.isEmpty
        ? "Aucun fichier cart.json, favorites.json ou downloads.json lisible dans ce dossier."
        : report.joined(separator: "\n") + "\n\nFusion : ce qui était déjà dans l'app est resté."
    alert.runModal()
}
