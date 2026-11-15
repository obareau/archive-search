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
    }

    func reload() {
        cart = Store.readList(.cart)
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
        panel.directoryURL = root
        panel.prompt = "Télécharger ici"
        panel.message = "Choisir le dossier du lot. Depuis « \(root.lastPathComponent) » sans sous-dossier, le lot va dans un sous-dossier daté."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
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
            .help(inCart ? "Retirer du panier" : "Ajouter au panier")
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

    var body: some View {
        let items = library.cart
        let downloadable = items.filter(Downloader.isDownloadable).count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
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
