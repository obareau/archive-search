import Foundation

/// Panier, favoris, historique, journal : des fichiers JSON, la même mécanique.
/// Un fichier illisible vaut « vide » — un JSON tronqué ne doit pas empêcher
/// l'app de démarrer, elle se reconstruit à l'usage. Les formats sont ceux de
/// la version Flask, pour pouvoir reprendre ses fichiers tels quels.
public enum Store {
    public static func url(_ name: String) -> URL { Paths.dataDir.appendingPathComponent(name) }

    public static func read<T: Decodable>(_ type: T.Type, _ file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Écriture atomique : jamais de liste tronquée.
    public static func write<T: Encodable>(_ value: T, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        try enc.encode(value).write(to: file, options: .atomic)
    }

    // ── Panier et favoris ────────────────────────────────────────────────
    public enum List: String, CaseIterable, Sendable {
        case cart, favorites
        public var file: URL { Store.url("\(rawValue).json") }
    }

    /// Le « panier » est celui du projet actif (voir `Projects`) ; les favoris
    /// restent une liste unique.
    public static func readList(_ l: List) -> [Item] {
        l == .cart ? Projects.load().activeProject.items : (read([Item].self, l.file) ?? [])
    }
    public static func writeList(_ l: List, _ items: [Item]) throws {
        if l == .cart {
            var st = Projects.load()
            st.projects[st.activeIndex].items = items
            try Projects.save(st)
        } else {
            try write(items, l.file)
        }
    }

    /// Reprise des fichiers de la version web (copiés depuis l'ancien serveur).
    /// Fusion, jamais remplacement : ce qui est déjà dans l'app reste.
    /// Rend ce qui a été repris, fichier par fichier.
    public static func importLegacy(from dir: URL) -> [String] {
        var report: [String] = []
        for l in List.allCases {
            let src = dir.appendingPathComponent("\(l.rawValue).json")
            guard let incoming = read([Item].self, src) else { continue }
            var cur = readList(l)
            let have = Set(cur.map(\.key))
            let add = incoming.filter { !have.contains($0.key) }
            cur.append(contentsOf: add)
            if (try? writeList(l, cur)) != nil {
                report.append("\(l == .cart ? "panier" : "favoris") : \(add.count) ajouté(s) sur \(incoming.count)")
            }
        }
        let jsrc = dir.appendingPathComponent("downloads.json")
        if let incoming = read([String: Journal.Entry].self, jsrc) {
            let n = Journal.merge(incoming)
            report.append("journal : \(n) entrée(s) reprise(s) sur \(incoming.count)")
        }
        let hsrc = dir.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: hsrc.path),
           !FileManager.default.fileExists(atPath: url("history.json").path) {
            // L'historique sera relu à l'étape 3 ; on le garde de côté dès maintenant.
            try? FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: hsrc, to: url("history.json"))) != nil {
                report.append("historique : copié")
            }
        }
        return report
    }
}

// ── Journal des téléchargements ───────────────────────────────────────────
// C'est le pendant de la nouveauté : l'un dit ce qui est apparu à la source,
// l'autre ce qui est déjà rentré sur le disque.
public enum Journal {
    public struct Entry: Codable, Sendable {
        public var title: String
        public var source: String
        public var identifier: String
        public var url: String
        public var creator: String
        public var license: String
        public var license_url: String
        /// Plusieurs chemins : le même son sert à deux projets, donc vit à deux
        /// endroits. N'en retenir qu'un faisait recopier dans un dossier qui
        /// l'avait déjà, avec un doublon « (1) » que rien n'expliquait.
        public var paths: [String]
        public var size: Int
        public var at: String
        public var first_at: String

        enum CodingKeys: String, CodingKey {
            case title, source, identifier, url, creator, license, license_url, paths, path, size, at, first_at
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            title = s(.title); source = s(.source); identifier = s(.identifier); url = s(.url)
            creator = s(.creator); license = s(.license); license_url = s(.license_url)
            at = s(.at); first_at = s(.first_at)
            size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? 0
            // Forme ancienne : un seul `path`.
            if let p = try? c.decodeIfPresent([String].self, forKey: .paths) { paths = p }
            else if let p = try? c.decodeIfPresent(String.self, forKey: .path), !p.isEmpty { paths = [p] }
            else { paths = [] }
        }
        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title); try c.encode(source, forKey: .source)
            try c.encode(identifier, forKey: .identifier); try c.encode(url, forKey: .url)
            try c.encode(creator, forKey: .creator); try c.encode(license, forKey: .license)
            try c.encode(license_url, forKey: .license_url); try c.encode(paths, forKey: .paths)
            try c.encode(size, forKey: .size); try c.encode(at, forKey: .at)
            try c.encode(first_at, forKey: .first_at)
        }
        init(item: Item, paths: [String], size: Int, at: String, firstAt: String) {
            title = item.title; source = item.source; identifier = item.identifier; url = item.url
            creator = item.creator; license = item.license?.code ?? ""; license_url = item.license?.url ?? ""
            self.paths = paths; self.size = size; self.at = at; first_at = firstAt
        }
    }

    public static let pathsPerItem = 12
    private static let lock = NSLock()
    public static var file: URL {
        if let f = ProcessInfo.processInfo.environment["DOWNLOADS_FILE"], !f.isEmpty { return URL(fileURLWithPath: f) }
        return Store.url("downloads.json")
    }

    static func now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date())
    }

    static func readAll() -> [String: Entry] { Store.read([String: Entry].self, file) ?? [:] }

    private static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    public static func note(_ item: Item, dest: URL, size: Int) {
        lock.lock(); defer { lock.unlock() }
        var log = readAll()
        let prev = log[item.key]
        let t = now()
        // Les chemins morts partent ici : c'est le seul moment où on écrit, et
        // une liste qui ne s'élague jamais finit par mentir.
        let kept = (prev?.paths ?? []).filter { $0 != dest.path && exists($0) }
        log[item.key] = Entry(item: item, paths: [dest.path] + kept.prefix(pathsPerItem - 1),
                              size: size, at: t, firstAt: (prev?.first_at).flatMap { $0.isEmpty ? nil : $0 } ?? t)
        try? Store.write(log, file)
    }

    /// (entrée, chemins encore présents) — le plus récent d'abord. Un fichier
    /// effacé à la main doit se re-télécharger, pas afficher « déjà pris ».
    public static func live(_ item: Item) -> (Entry?, [URL]) {
        lock.lock(); let e = readAll()[item.key]; lock.unlock()
        guard let e else { return (nil, []) }
        let live = e.paths.filter(exists).map { URL(fileURLWithPath: $0) }
        return (live.isEmpty ? nil : e, live)
    }

    /// Les clés dont au moins un fichier est encore sur le disque.
    public static func takenKeys() -> Set<String> {
        lock.lock(); let log = readAll(); lock.unlock()
        return Set(log.filter { $0.value.paths.contains(where: exists) }.map(\.key))
    }

    public struct Listed: Identifiable, Sendable {
        public let key: String
        public let entry: Entry
        public let livePaths: [String]
        public var id: String { key }
        public var missing: Bool { livePaths.isEmpty }
    }

    /// Le journal entier. On ne purge PAS ce qui manque : le dire absent permet
    /// de le reprendre, l'effacer ferait croire qu'on ne l'a jamais eu.
    public static func list() -> [Listed] {
        lock.lock(); let log = readAll(); lock.unlock()
        return log.map { Listed(key: $0.key, entry: $0.value, livePaths: $0.value.paths.filter(exists)) }
            .sorted { $0.entry.at > $1.entry.at }
    }

    static func merge(_ incoming: [String: Entry]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var log = readAll()
        var n = 0
        for (k, v) in incoming where log[k] == nil { log[k] = v; n += 1 }
        try? Store.write(log, file)
        return n
    }
}

// ── Fiche de crédits ──────────────────────────────────────────────────────
// Le badge dit « réutilisable avec attribution » : la fiche donne de quoi le faire.
public enum Credits {
    static let header = """
    CRÉDITS — fichiers récupérés avec Archive Search
    ================================================

    Les licences Creative Commons en « BY » IMPOSENT de créditer l'auteur. Ce
    fichier donne de quoi le faire ; il ne dispense pas de le faire.

    Une licence « non déclarée » ou « non reconnue » n'est PAS une autorisation :
    l'absence d'information veut dire qu'il faut aller vérifier à la source.

    """

    public static func line(_ item: Item, file: String) -> String {
        let lic = item.license ?? .none
        var lines = [
            "· \(item.title.isEmpty ? "sans-titre" : item.title)",
            "  fichier : \(file)",
            "  auteur  : \(item.creator.isEmpty ? "inconnu" : item.creator)",
            "  source  : \(item.source) — \(item.url)",
            "  licence : \(lic.code.isEmpty ? "non déclarée" : lic.code)" + (lic.url.isEmpty ? "" : "  \(lic.url)"),
        ]
        if lic.free != true {
            lines.append("  ⚠ vérifier avant publication : " + (lic.free == false
                ? "licence restrictive (pas de modification et/ou pas de commercial)" : "licence inconnue"))
        }
        return lines.joined(separator: "\n")
    }

    /// AJOUT, jamais écrasement : le second lot dans un dossier ne doit pas
    /// effacer l'attribution du premier. Un fichier déjà crédité ici ne l'est
    /// pas deux fois. Une fiche ratée ne transforme pas un lot réussi en échec.
    @discardableResult
    public static func write(in folder: URL, _ entries: [(file: String, block: String)]) -> Bool {
        guard !entries.isEmpty else { return true }
        let path = folder.appendingPathComponent("CREDITS.txt")
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let blocks = entries.filter { !existing.contains("fichier : \($0.file)") }.map(\.block)
        guard !blocks.isEmpty else { return true }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var add = existing.isEmpty ? header : ""
        add += "\n── lot du \(f.string(from: Date())) \(String(repeating: "─", count: 34))\n\n"
            + blocks.joined(separator: "\n\n") + "\n"
        do {
            if existing.isEmpty {
                try add.write(to: path, atomically: true, encoding: .utf8)
            } else {
                let h = try FileHandle(forWritingTo: path)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: Data(add.utf8))
            }
            return true
        } catch {
            return false
        }
    }
}

// ── Paniers par projet ────────────────────────────────────────────────────
// Un panier unique mélangeait l'épisode 12 et la séance AZA 14. Chaque projet
// a ses items, sa fiche de crédits et le dossier où il se télécharge.
public enum Projects {
    public struct Project: Codable, Sendable, Identifiable, Hashable {
        public var name: String
        public var items: [Item]
        /// Dernier dossier de téléchargement : le dialogue s'y rouvre.
        public var folder: String?
        public var id: String { name }
        public init(name: String, items: [Item] = [], folder: String? = nil) {
            self.name = name; self.items = items; self.folder = folder
        }
    }

    public struct State: Codable, Sendable {
        public var active: String
        public var projects: [Project]
        public var activeIndex: Int { projects.firstIndex { $0.name == active } ?? 0 }
        public var activeProject: Project { projects[activeIndex] }
    }

    public static let defaultName = "Panier"
    public static var file: URL { Store.url("projects.json") }

    /// Premier lancement : l'ancien `cart.json` devient le projet « Panier ».
    public static func load() -> State {
        if let st = Store.read(State.self, file), !st.projects.isEmpty { return st }
        let legacy = Store.read([Item].self, Store.List.cart.file) ?? []
        return State(active: defaultName, projects: [Project(name: defaultName, items: legacy)])
    }

    public static func save(_ st: State) throws { try Store.write(st, file) }

    /// Nom libre, unique, sans espaces autour. Rend le nom retenu.
    static func uniqueName(_ raw: String, in st: State, except: String? = nil) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Projet" : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = base, n = 2
        while st.projects.contains(where: { $0.name == name && $0.name != except }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    @discardableResult
    public static func create(_ raw: String) throws -> String {
        var st = load()
        let name = uniqueName(raw, in: st)
        st.projects.append(Project(name: name))
        st.active = name
        try save(st)
        return name
    }

    public static func select(_ name: String) throws {
        var st = load()
        guard st.projects.contains(where: { $0.name == name }) else { return }
        st.active = name
        try save(st)
    }

    @discardableResult
    public static func rename(_ old: String, to raw: String) throws -> String {
        var st = load()
        guard let i = st.projects.firstIndex(where: { $0.name == old }) else { return old }
        let name = uniqueName(raw, in: st, except: old)
        st.projects[i].name = name
        if st.active == old { st.active = name }
        try save(st)
        return name
    }

    /// Le dernier projet ne se supprime pas : il en faut toujours un actif.
    public static func delete(_ name: String) throws {
        var st = load()
        guard st.projects.count > 1 else { return }
        st.projects.removeAll { $0.name == name }
        if st.active == name { st.active = st.projects[0].name }
        try save(st)
    }

    public static func setFolder(_ folder: URL, for name: String) throws {
        var st = load()
        guard let i = st.projects.firstIndex(where: { $0.name == name }) else { return }
        st.projects[i].folder = folder.path
        try save(st)
    }

    /// Crédits du projet en Markdown, prêts pour des notes d'épisode ou le vault.
    public static func creditsMarkdown(_ p: Project) -> String {
        var lines = ["## Crédits — \(p.name)", ""]
        for it in p.items {
            let lic = it.license ?? .none
            var l = "- **\(it.title)**"
            if !it.creator.isEmpty && it.creator != "N/A" { l += " — \(it.creator)" }
            l += " · [\(it.source)](\(it.url))"
            l += " · " + (lic.code.isEmpty ? "licence non déclarée" : (lic.url.isEmpty ? lic.code : "[\(lic.code)](\(lic.url))"))
            if lic.free != true { l += lic.free == false ? " ⚠ restrictive" : " ⚠ à vérifier" }
            lines.append(l)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
