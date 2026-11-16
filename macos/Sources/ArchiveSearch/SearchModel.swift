import AppKit
import ArchiveCore
import Foundation

/// État de la recherche. ObservableObject et pas @Observable : sans Xcode, les
/// plugins de macro n'existent pas.
@MainActor
final class SearchModel: ObservableObject {
    /// Toutes les sources par défaut : c'est le geste qu'on refaisait le plus.
    @Published var source = Sources.allID
    @Published var text = ""
    @Published var type: SearchType = .all
    @Published var sort: SortOption = .relevance
    @Published var collection: Collection = .all

    @Published private(set) var results: [Item] = []
    @Published private(set) var total: Int?
    @Published private(set) var hasMore = false
    @Published private(set) var page = 1
    @Published private(set) var related = Related()
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var notice: String?
    /// Libellé de ce qui est affiché (« foghorn · archive.org », « Surprise »).
    @Published private(set) var shownLabel = ""

    /// « Réutilisable seulement » masque rouge ET gris : inconnu n'est pas libre.
    @Published var onlyReusable = false
    @Published var selection: Item.ID?
    /// Identifiants apparus depuis le passage précédent de cette recherche.
    @Published private(set) var newIDs: Set<String> = []
    /// Bump à chaque recherche enregistrée : la vue Historique se relit.
    @Published private(set) var historyTick = 0
    /// Résultats d'une fouille : par quels termes et à quelle proximité.
    @Published private(set) var huntInfo: [String: (hits: [String], rel: Double?)] = [:]
    @Published private(set) var isHunt = false
    /// Recherche sur toutes les sources : ce que chacune a rendu, et celles
    /// qui n'ont pas encore répondu.
    @Published private(set) var outcomes: [Sources.Outcome] = []
    @Published private(set) var pending: [String] = []
    /// N'afficher qu'une source parmi les résultats fusionnés.
    @Published var sourceFilter: String?

    private var task: Task<Void, Never>?

    var visible: [Item] {
        results.filter { (!onlyReusable || $0.license?.free == true) && (sourceFilter == nil || $0.source == sourceFilter) }
    }
    var isAll: Bool { source == Sources.allID }
    var hiddenCount: Int { results.count - visible.count }
    var isArchive: Bool { source == "archive.org" }
    var sourceLabel: String { Sources.all.first { $0.id == source }?.label ?? source }

    func search(page: Int = 1) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        error = nil; notice = nil
        if source == "loc.gov" {
            NSWorkspace.shared.open(Sources.locHandoff(q))
            notice = "La Library of Congress s'ouvre dans le navigateur : leur site refuse tout programme (défi Cloudflare)."
            return
        }
        let query = SearchQuery(source: source, text: q,
                                type: isArchive ? type : .all, sort: isArchive ? sort : .relevance,
                                collection: isArchive ? collection : .all, page: page)
        task?.cancel()
        loading = true
        sourceFilter = nil
        if isAll { searchAll(query); return }
        outcomes = []; pending = []
        task = Task {
            do {
                let p = try await Sources.search(query)
                guard !Task.isCancelled else { return }
                // L'historique s'enregistre MÊME sur un cache touché : relancer
                // est un geste de l'usager, il doit être daté.
                let fresh = History.record(query, p.results)
                newIDs = fresh
                historyTick += 1
                // Les nouveautés remontent en tête.
                results = fresh.isEmpty ? p.results
                    : p.results.filter { fresh.contains(History.seenID($0)) } + p.results.filter { !fresh.contains(History.seenID($0)) }
                total = p.total; hasMore = p.hasMore; huntInfo = [:]; isHunt = false
                related = p.related; self.page = page
                shownLabel = "« \(q) » · \(sourceLabel)"
                selection = nil
                if p.results.isEmpty { notice = "Rien trouvé." }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    /// Toutes les sources en parallèle, affichées au fil des réponses :
    /// Gutenberg (15 à 30 s) ne fait pas attendre les autres.
    private func searchAll(_ query: SearchQuery) {
        let q = query.text
        outcomes = []
        pending = Sources.allSources
        results = []; total = nil; hasMore = false; related = Related(); newIDs = []
        huntInfo = [:]; isHunt = false; page = query.page; selection = nil
        shownLabel = "« \(q) » · toutes les sources"
        task = Task {
            var lists: [String: [Item]] = [:]
            let (p, outs) = await Sources.searchAll(q, page: query.page) { [weak self] o, items in
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    lists[o.source] = items
                    self.outcomes.append(o)
                    self.pending.removeAll { $0 == o.source }
                    self.results = Sources.interleave(Sources.allSources.compactMap { lists[$0] })
                    // Dès la première source, on montre : c'est tout l'intérêt.
                    if self.loading && !self.results.isEmpty { self.loading = false }
                }
            }
            guard !Task.isCancelled else { return }
            let fresh = History.record(query, p.results)
            newIDs = fresh
            historyTick += 1
            results = fresh.isEmpty ? p.results
                : p.results.filter { fresh.contains(History.seenID($0)) } + p.results.filter { !fresh.contains(History.seenID($0)) }
            outcomes = outs
            pending = []
            total = p.total; hasMore = p.hasMore; related = p.related
            if p.results.isEmpty {
                notice = outs.allSatisfy { $0.error != nil } ? "Aucune source n'a répondu." : "Rien trouvé."
            }
            loading = false
        }
    }

    /// La récolte classée d'une fouille. Pas d'historique : une fouille de
    /// quinze termes y créerait quinze entrées.
    static let huntShown = 120
    func showHunt(_ ranked: [Hunt.Ranked], theme: String) {
        task?.cancel(); loading = false; error = nil; notice = nil
        let shown = Array(ranked.prefix(Self.huntShown))
        results = shown.map(\.item); outcomes = []; pending = []; sourceFilter = nil
        huntInfo = Dictionary(uniqueKeysWithValues: shown.map { ($0.item.id, ($0.hits, $0.rel)) })
        total = ranked.count; hasMore = false; page = 1; newIDs = []; isHunt = true
        related = relatedTerms(results, query: theme)
        selection = nil
        shownLabel = "🔎 « \(theme) »"
        if ranked.isEmpty { notice = "La fouille n'a rien ramené." }
    }

    func isNew(_ item: Item) -> Bool { newIDs.contains(History.seenID(item)) }

    /// Relancer une recherche de l'historique, avec ses réglages.
    func replay(_ q: SearchQuery) {
        source = q.source; text = q.text; type = q.type; sort = q.sort; collection = q.collection
        search(page: 1)
    }

    func historyChanged() { historyTick += 1 }

    /// Une proposition connexe relance sur la MÊME source.
    func searchRelated(_ term: String) {
        text = term
        search(page: 1)
    }

    func surprise() {
        task?.cancel()
        error = nil; notice = nil; loading = true
        task = Task {
            do {
                if let item = try await Sources.randomArchiveItem() {
                    outcomes = []; pending = []; sourceFilter = nil
                    results = [item]; total = 1; hasMore = false; page = 1; newIDs = []; huntInfo = [:]; isHunt = false
                    related = Related(); shownLabel = "🎲 Surprise"
                    selection = item.id
                } else {
                    notice = "Aucun résultat au hasard, réessaie."
                }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    var statusLine: String {
        guard !results.isEmpty else { return "" }
        var s = shownLabel
        if let total { s += " — \(total.formatted()) résultat\(total > 1 ? "s" : "")" }
        if page > 1 || hasMore { s += " · page \(page)" }
        return s
    }
}
