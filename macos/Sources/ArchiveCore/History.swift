import Foundation

// ── Historique des recherches ─────────────────────────────────────────────
// Chaque entrée retient les identifiants déjà vus, ce qui permet de dire ce
// qui est APPARU depuis la dernière fois — c'est tout l'intérêt de relancer
// une recherche sur un fonds vivant. Même format que history.json du Flask.
public enum History {
    public static let maxEntries = 120
    /// Par recherche : au-delà, on oublie les plus anciens.
    public static let seenMax = 400

    public struct Entry: Codable, Sendable {
        public var query: String
        public var source: String
        public var type: String
        public var sort: String
        public var collection: String
        public var first_seen: String
        public var last_run: String
        public var runs: Int
        public var seen: [String: String]
        public var new_count: Int
        public var watch: Bool

        enum CodingKeys: String, CodingKey {
            case query, source, type, sort, collection, first_seen, last_run, runs, seen, new_count, watch
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            query = s(.query); source = s(.source); type = s(.type); sort = s(.sort)
            collection = s(.collection); first_seen = s(.first_seen); last_run = s(.last_run)
            runs = (try? c.decodeIfPresent(Int.self, forKey: .runs)) ?? 0
            seen = (try? c.decodeIfPresent([String: String].self, forKey: .seen)) ?? [:]
            new_count = (try? c.decodeIfPresent(Int.self, forKey: .new_count)) ?? 0
            watch = (try? c.decodeIfPresent(Bool.self, forKey: .watch)) ?? false
        }
        init(_ q: SearchQuery, now: String) {
            query = q.text; source = q.source; type = q.type.rawValue; sort = q.sort.rawValue
            collection = q.collection.rawValue; first_seen = now; last_run = now
            runs = 0; seen = [:]; new_count = 0; watch = false
        }
        /// La recherche à relancer, toujours en page 1.
        public var searchQuery: SearchQuery {
            SearchQuery(source: source, text: query, type: SearchType(rawValue: type) ?? .all,
                        sort: SortOption(rawValue: sort) ?? .relevance,
                        collection: Collection(rawValue: collection) ?? .all, page: 1)
        }
    }

    public struct Listed: Identifiable, Sendable {
        public let key: String
        public let entry: Entry
        public var id: String { key }
    }

    private static let lock = NSLock()
    public static var file: URL {
        if let f = ProcessInfo.processInfo.environment["HISTORY_FILE"], !f.isEmpty { return URL(fileURLWithPath: f) }
        return Store.url("history.json")
    }
    static func readAll() -> [String: Entry] { Store.read([String: Entry].self, file) ?? [:] }
    static func writeAll(_ d: [String: Entry]) { try? Store.write(d, file) }

    /// La PAGE n'entre pas dans la clé : les pages 1 et 2 d'une même recherche
    /// sont la même recherche, et alimentent le même « déjà vu ».
    public static func key(_ q: SearchQuery) -> String {
        [q.source, q.text.trimmingCharacters(in: .whitespaces).lowercased(), q.type.rawValue,
         q.sort.rawValue, q.collection.rawValue].joined(separator: "|")
    }

    /// Identifiant de « déjà vu » : celui de la version web.
    public static func seenID(_ item: Item) -> String {
        !item.identifier.isEmpty ? item.identifier : (!item.url.isEmpty ? item.url : item.title)
    }

    /// Enregistre le passage et rend les identifiants JAMAIS vus avant.
    /// ⚠️ Une recherche inédite ne rend RIEN comme nouveau : tout l'est, et
    /// badger vingt résultats sur vingt n'apprendrait rien.
    @discardableResult
    public static func record(_ q: SearchQuery, _ results: [Item]) -> Set<String> {
        let k = key(q)
        let ids = results.map(seenID)
        let now = Journal.now()
        lock.lock(); defer { lock.unlock() }
        var data = readAll()
        let firstRun = data[k] == nil
        var e = data[k] ?? Entry(q, now: now)
        let fresh = firstRun ? [] : ids.filter { e.seen[$0] == nil }
        for i in ids where e.seen[i] == nil { e.seen[i] = now }
        if e.seen.count > seenMax {
            e.seen = Dictionary(uniqueKeysWithValues: e.seen.sorted { $0.value > $1.value }.prefix(seenMax).map { ($0.key, $0.value) })
        }
        // Le compteur ne vaut que pour la page 1 : feuilleter trois pages ne
        // doit pas gonfler le chiffre sans qu'il soit rien arrivé.
        if q.page == 1 { e.new_count = fresh.count; e.runs += 1 }
        e.last_run = now
        data[k] = e
        if data.count > maxEntries {
            for (old, _) in data.sorted(by: { $0.value.last_run < $1.value.last_run }).prefix(data.count - maxEntries) {
                data[old] = nil
            }
        }
        writeAll(data)
        return Set(fresh)
    }

    public static func list() -> [Listed] {
        lock.lock(); let d = readAll(); lock.unlock()
        return d.map { Listed(key: $0.key, entry: $0.value) }.sorted { $0.entry.last_run > $1.entry.last_run }
    }

    public static func watched() -> [Listed] { list().filter(\.entry.watch) }

    public static func setWatch(_ key: String, _ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        var d = readAll()
        guard d[key] != nil else { return }
        d[key]?.watch = on
        writeAll(d)
    }

    /// Oublier UNE recherche : son « déjà vu » part avec elle.
    public static func forget(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var d = readAll()
        d[key] = nil
        writeAll(d)
    }

    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        writeAll([:])
    }
}

// ── Veille ────────────────────────────────────────────────────────────────
// Sur des fonds qui bougent lentement, personne ne va vérifier tous les jours :
// c'est la machine qui regarde, et elle ne parle QUE s'il y a du neuf.
public enum Watch {
    public static var interval: TimeInterval {
        TimeInterval(ProcessInfo.processInfo.environment["WATCH_INTERVAL_S"].flatMap(Int.init) ?? 6 * 3600)
    }
    /// Entre deux recherches : six requêtes d'affilée ressemblent à du
    /// moissonnage et finissent limitées.
    public static var spacing: TimeInterval {
        TimeInterval(ProcessInfo.processInfo.environment["WATCH_SPACING_S"].flatMap(Int.init) ?? 20)
    }

    public struct Finding: Sendable {
        public let key: String
        public let query: SearchQuery
        public let fresh: [Item]
    }

    public struct PassReport: Sendable {
        public var checked = 0
        public var findings: [Finding] = []
        public var failures: [String] = []
        public init() {}
    }

    /// Un passage sur toutes les recherches surveillées. Une source en panne
    /// est notée et n'arrête pas les autres ; elle ne réveille personne.
    public static func pass(spacing: TimeInterval = Watch.spacing,
                            search: @Sendable (SearchQuery) async throws -> [Item] = { try await Sources.search($0, useCache: false).results })
        async -> PassReport {
        var r = PassReport()
        let entries = History.watched()
        for (i, w) in entries.enumerated() {
            if Task.isCancelled { break }
            let q = w.entry.searchQuery
            do {
                let results = try await search(q)
                let fresh = History.record(q, results)
                r.checked += 1
                if !fresh.isEmpty {
                    r.findings.append(Finding(key: w.key, query: q,
                                              fresh: results.filter { fresh.contains(History.seenID($0)) }))
                }
            } catch {
                r.failures.append("\(q.source) « \(q.text) » : \(error.localizedDescription)")
            }
            if i < entries.count - 1 { try? await Task.sleep(for: .seconds(spacing)) }
        }
        return r
    }
}
