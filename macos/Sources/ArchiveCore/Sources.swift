import Foundation

public struct SourceInfo: Hashable, Sendable {
    public let id: String
    public let label: String
    /// Renvoi vers le site de la source plutôt qu'une intégration.
    public let handoff: Bool
}

public enum Sources {
    public static let all: [SourceInfo] = [
        .init(id: allID, label: "Toutes les sources", handoff: false),
        .init(id: "archive.org", label: "Archive.org", handoff: false),
        .init(id: "gutenberg", label: "Gutenberg (livres)", handoff: false),
        .init(id: "wikimedia", label: "Wikimedia Commons", handoff: false),
        .init(id: "librivox", label: "LibriVox (audio livres)", handoff: false),
        .init(id: "freesound", label: "Freesound (sons)", handoff: false),
        .init(id: "loc.gov", label: "Library of Congress (audio) ↗", handoff: true),
    ]

    // ── Toutes les sources d'un coup ─────────────────────────────────────

    public static let allID = "all"
    /// loc.gov n'est qu'un renvoi : il n'entre pas dans le lot.
    public static let allSources = ["archive.org", "freesound", "wikimedia", "librivox", "gutenberg"]

    /// Ce que chaque source a rendu, pour le dire à côté des résultats.
    public struct Outcome: Sendable, Hashable {
        public let source: String
        public let count: Int
        public let total: Int?
        public let error: String?
        public let seconds: Double
    }

    /// Intercale les listes source par source (1er d'archive.org, 1er de
    /// Freesound…) : concaténées, la première source à répondre occuperait
    /// tout l'écran. Chaque liste garde l'ordre de pertinence de sa source.
    public static func interleave(_ lists: [[Item]]) -> [Item] {
        var out: [Item] = [], seen = Set<String>()
        let n = lists.map(\.count).max() ?? 0
        for i in 0..<n {
            for l in lists where i < l.count && seen.insert(l[i].key).inserted { out.append(l[i]) }
        }
        return out
    }

    /// Toutes les sources en parallèle. `progress` reçoit chaque source dès
    /// qu'elle répond : Gutenberg met 15 à 30 s, il ne doit pas faire attendre
    /// les quatre autres. Une source en panne est notée, pas fatale.
    public static func searchAll(_ text: String, page: Int = 1,
                                 sources: [String] = allSources, useCache: Bool = true,
                                 progress: (@Sendable (Outcome, [Item]) async -> Void)? = nil)
        async -> (page: SearchPage, outcomes: [Outcome]) {
        var lists: [String: [Item]] = [:]
        var outcomes: [Outcome] = []
        var anyMore = false
        await withTaskGroup(of: (Outcome, [Item], Bool).self) { group in
            for src in sources {
                group.addTask {
                    let t0 = Date()
                    do {
                        let p = try await search(SearchQuery(source: src, text: text, page: page), useCache: useCache)
                        return (Outcome(source: src, count: p.results.count, total: p.total, error: nil,
                                        seconds: Date().timeIntervalSince(t0)), p.results, p.hasMore)
                    } catch {
                        return (Outcome(source: src, count: 0, total: nil, error: error.localizedDescription,
                                        seconds: Date().timeIntervalSince(t0)), [], false)
                    }
                }
            }
            for await (o, items, more) in group {
                lists[o.source] = items
                outcomes.append(o)
                anyMore = anyMore || more
                await progress?(o, items)
            }
        }
        let merged = interleave(sources.compactMap { lists[$0] })
        let totals = outcomes.compactMap(\.total)
        let page = SearchPage(results: merged, total: totals.isEmpty ? nil : totals.reduce(0, +),
                              hasMore: anyMore, related: relatedTerms(merged, query: text))
        return (page, sources.compactMap { s in outcomes.first { $0.source == s } })
    }

    /// loc.gov ne s'interroge pas depuis un programme : tout leur site répond
    /// 403 derrière un défi Cloudflare, y compris leur documentation d'API. Un
    /// navigateur passe ce défi, pas nous : on ouvre la recherche chez eux.
    public static func locHandoff(_ query: String) -> URL {
        HTTP.url("https://www.loc.gov/audio/", [("q", query)])
    }

    /// `useCache: false` pour la veille : un résultat d'il y a une heure ne
    /// dirait rien de ce qui vient d'arriver.
    public static func search(_ q: SearchQuery, useCache: Bool = true) async throws -> SearchPage {
        let text = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SourceError("Requête vide") }
        let key = SearchCache.Key(query: q)
        if useCache, let hit = await SearchCache.shared.get(key) { return hit }

        let (results, total): ([Item], Int?)
        switch q.source {
        case "archive.org": (results, total) = try await archiveOrg(text, q.type, q.page, q.sort, q.collection)
        case "gutenberg": (results, total) = try await gutenberg(text, q.page)
        case "wikimedia": (results, total) = try await wikimedia(text, q.page)
        case "librivox": (results, total) = try await librivox(text, q.page)
        case "freesound": (results, total) = try await freesound(text, q.page)
        case allID:
            // Pour la veille et l'historique : la même recherche, fusionnée.
            return await searchAll(text, page: q.page, useCache: useCache).page
        case "loc.gov":
            throw SourceError("loc.gov ne peut pas être interrogé par l'app (défi Cloudflare) — la recherche s'ouvre sur leur site.")
        default: throw SourceError("Source inconnue : \(q.source)")
        }
        let rows = Config.rowsPerPage
        let hasMore = total.map { q.page * rows < $0 } ?? (results.count >= rows)
        let page = SearchPage(results: results, total: total, hasMore: hasMore,
                              related: relatedTerms(results, query: text))
        await SearchCache.shared.set(key, page)
        return page
    }

    // ── archive.org ──────────────────────────────────────────────────────

    static func archiveOrg(_ query: String, _ type: SearchType, _ page: Int,
                           _ sort: SortOption, _ collection: Collection) async throws -> ([Item], Int?) {
        var q = "\"\(query)\""
        switch type {
        case .film: q += " AND mediatype:movies AND year:[1920 TO 1980]"
        case .audio: q += " AND mediatype:audio"
        case .pdf: q += " AND mediatype:texts AND format:PDF"
        case .all: break
        }
        if collection != .all { q += " AND collection:\(collection.rawValue)" }
        var params: [(String, String)] = [
            ("q", q),
            ("fl", "identifier,title,creator,year,mediatype,description,subject,licenseurl"),
            ("output", "json"), ("rows", "\(Config.rowsPerPage)"), ("page", "\(page)"),
        ]
        if let s = sort.archiveParam { params.append(("sort[]", s)) }
        let (data, _) = try await HTTP.json(HTTP.url("https://archive.org/advancedsearch.php", params), source: "archive.org")
        let response = data["response"] as? JSON ?? [:]
        let docs = response["docs"] as? [JSON] ?? []
        return (docs.map(archiveItem), (response["numFound"] as? NSNumber)?.intValue)
    }

    static func archiveItem(_ doc: JSON) -> Item {
        let ident = str(doc["identifier"])
        return Item(
            title: or(str(doc["title"]), or(ident, "N/A")),
            creator: or(str(doc["creator"]), "N/A"),
            year: str(doc["year"]),
            type: str(doc["mediatype"]),
            description: clip(stripHTML(str(doc["description"])), 150),
            url: "https://archive.org/details/\(ident)",
            thumbnail: ident.isEmpty ? "" : "https://archive.org/services/img/\(ident)",
            source: "archive.org", identifier: ident,
            keywords: Array(strList(doc["subject"]).prefix(12)),
            license: normalizeLicense(str(doc["licenseurl"])))
    }

    // ── Gutenberg (gutendex) ─────────────────────────────────────────────

    static func gutenberg(_ query: String, _ page: Int) async throws -> ([Item], Int?) {
        let url = HTTP.url("https://gutendex.com/books/", [("search", query), ("page", "\(page)")])
        let (data, status) = try await HTTP.json(url, source: "gutenberg")
        if status >= 500 { throw SourceError("Gutendex est en difficulté (HTTP \(status)) — réessaie plus tard.") }
        let books = data["results"] as? [JSON] ?? []
        let items = books.map { book -> Item in
            let authors = (book["authors"] as? [JSON] ?? []).map { str($0["name"]) }.joined(separator: ", ")
            let formats = book["formats"] as? JSON ?? [:]
            let id = str(book["id"])
            let fileURL = [str(formats["text/html; charset=utf-8"]), str(formats["text/html"]),
                           str(formats["application/epub+zip"])].first { !$0.isEmpty }
                ?? "https://www.gutenberg.org/ebooks/\(id)"
            return Item(title: or(str(book["title"]), "N/A"), creator: or(authors, "N/A"), year: "",
                        type: "book",
                        description: strList(book["subjects"]).prefix(3).joined(separator: ", "),
                        url: fileURL, thumbnail: str(formats["image/jpeg"]),
                        source: "gutenberg", identifier: id)
        }
        return (items, (data["count"] as? NSNumber)?.intValue)
    }

    // ── Wikimedia Commons ────────────────────────────────────────────────

    static func wikimedia(_ query: String, _ page: Int) async throws -> ([Item], Int?) {
        let api = "https://commons.wikimedia.org/w/api.php"
        // srnamespace=6 = « File » : sans ça, des pages Catégorie/Galerie
        // remontent, sans imageinfo, donc sans vignette ni URL.
        let (data, _) = try await HTTP.json(HTTP.url(api, [
            ("action", "query"), ("list", "search"), ("srsearch", query), ("srnamespace", "6"),
            ("srlimit", "\(Config.rowsPerPage)"), ("sroffset", "\((page - 1) * Config.rowsPerPage)"),
            ("format", "json"),
        ]), source: "wikimedia")
        let qd = data["query"] as? JSON ?? [:]
        let total = ((qd["searchinfo"] as? JSON)?["totalhits"] as? NSNumber)?.intValue
        let titles = (qd["search"] as? [JSON] ?? []).map { str($0["title"]) }
        guard !titles.isEmpty else { return ([], total) }

        let (info, _) = try await HTTP.json(HTTP.url(api, [
            ("action", "query"), ("titles", titles.joined(separator: "|")), ("prop", "imageinfo"),
            ("iiprop", "url|extmetadata"), ("iiurlwidth", "300"), ("format", "json"),
        ]), source: "wikimedia")
        let pages = (info["query"] as? JSON)?["pages"] as? JSON ?? [:]
        var byTitle: [String: Item] = [:]
        for case let p as JSON in pages.values {
            let ii = (p["imageinfo"] as? [JSON])?.first ?? [:]
            let meta = ii["extmetadata"] as? JSON ?? [:]
            func m(_ k: String) -> String { str((meta[k] as? JSON)?["value"]) }
            let title = str(p["title"])
            let date = m("DateTimeOriginal")
            byTitle[title] = Item(
                title: or(title.replacingOccurrences(of: "File:", with: ""), "N/A"),
                creator: or(stripHTML(m("Artist")), "N/A"),
                year: String(date.prefix(4)), type: "media",
                description: clip(stripHTML(m("ImageDescription")), 150),
                url: str(ii["descriptionurl"]),
                thumbnail: or(str(ii["thumburl"]), str(ii["url"])),
                source: "wikimedia", identifier: title,
                license: normalizeLicense(or(m("LicenseUrl"), "")))
        }
        // L'API rend un dict sans ordre : on remet l'ordre de pertinence.
        return (titles.compactMap { byTitle[$0] }, total)
    }

    // ── LibriVox ─────────────────────────────────────────────────────────

    static func librivox(_ query: String, _ page: Int) async throws -> ([Item], Int?) {
        // Recherche par PRÉFIXE de titre (^) seulement, pas de plein texte, et
        // pas de total fiable : « suivant » actif si la page est pleine.
        let (data, _) = try await HTTP.json(HTTP.url("https://librivox.org/api/feed/audiobooks/", [
            ("title", "^\(query)"), ("format", "json"), ("extended", "1"),
            ("limit", "\(Config.rowsPerPage)"), ("offset", "\((page - 1) * Config.rowsPerPage)"),
        ]), source: "librivox")
        let books = data["books"] as? [JSON] ?? []
        let items = books.map { b -> Item in
            let authors = (b["authors"] as? [JSON] ?? []).map {
                "\(str($0["first_name"])) \(str($0["last_name"]))".trimmingCharacters(in: .whitespaces)
            }.joined(separator: ", ")
            return Item(title: or(str(b["title"]), "N/A"), creator: or(authors, "N/A"), year: "",
                        type: "audiobook", description: clip(stripHTML(str(b["description"])), 150),
                        url: or(str(b["url_librivox"]), str(b["url_zip_file"])), thumbnail: "",
                        source: "librivox", identifier: str(b["id"]))
        }
        return (items, nil)
    }

    // ── Freesound ────────────────────────────────────────────────────────

    static func freesound(_ query: String, _ page: Int) async throws -> ([Item], Int?) {
        // Pas de quota anonyme. Sans clé on le DIT plutôt que de rendre zéro
        // résultat, qui se confondrait avec « rien trouvé ».
        let token = FreesoundToken.read()
        guard !token.isEmpty else {
            throw SourceError("Freesound demande une clé d'API. En créer une (gratuite) sur https://freesound.org/apiv2/apply/ puis la coller dans Réglages (⌘,).")
        }
        let (data, status) = try await HTTP.json(HTTP.url("https://freesound.org/apiv2/search/text/", [
            ("query", query), ("page", "\(page)"), ("page_size", "\(Config.rowsPerPage)"),
            ("fields", "id,name,username,description,previews,images,duration,license,url,created,tags,type,channels,samplerate"),
            ("token", token),
        ]), source: "freesound")
        if status == 401 || status == 403 { throw SourceError("Freesound refuse la clé (\(status)) — la vérifier dans Réglages.") }
        if status == 404 && page > 1 { return ([], (data["count"] as? NSNumber)?.intValue) }
        let items = (data["results"] as? [JSON] ?? []).map { s -> Item in
            let previews = s["previews"] as? JSON ?? [:]
            let dur = (s["duration"] as? NSNumber)?.doubleValue
            return Item(title: or(str(s["name"]), "N/A"), creator: or(str(s["username"]), "N/A"),
                        year: String(str(s["created"]).prefix(4)),
                        type: dur.map { "son · \(Int($0.rounded()))s" } ?? "son",
                        description: clip(stripHTML(str(s["description"])), 150),
                        url: str(s["url"]), thumbnail: str((s["images"] as? JSON)?["waveform_m"]),
                        source: "freesound", identifier: str(s["id"]),
                        keywords: Array(strList(s["tags"]).prefix(12)),
                        license: normalizeLicense(str(s["license"])),
                        preview: or(str(previews["preview-hq-mp3"]), str(previews["preview-lq-mp3"])),
                        format: str(s["type"]).isEmpty ? nil : str(s["type"]).lowercased())
        }
        return (items, (data["count"] as? NSNumber)?.intValue)
    }

    // ── Fichier direct et .torrent (archive.org seulement) ───────────────

    static let preferredExt: [String: [String]] = [
        "movies": [".mp4", ".ogv", ".webm"],
        "audio": [".mp3", ".ogg"],
        "texts": [".pdf"],
    ]

    public struct ResolvedFile: Sendable { public let url: URL?; public let mediatype: String }

    static func metadata(_ identifier: String) async throws -> JSON {
        let id = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        return try await HTTP.json(URL(string: "https://archive.org/metadata/\(id)")!, source: "archive.org").0
    }

    static func downloadURL(_ identifier: String, _ name: String) -> URL? {
        let enc = name.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://archive.org/download/\(identifier)/\(enc)")
    }

    /// Le fichier lisible le plus adapté. Pas de repli vers « n'importe quel
    /// fichier » : un item sans .mp4/.mp3/.pdf reste indisponible plutôt que de
    /// rendre une vignette au hasard. Le mediatype est rendu même sans fichier.
    public static func resolveArchiveFile(_ identifier: String) async throws -> ResolvedFile {
        if let hit = await SearchCache.shared.file(identifier) { return hit }
        let data = try await metadata(identifier)
        let files = data["files"] as? [JSON] ?? []
        let mediatype = str((data["metadata"] as? JSON)?["mediatype"])
        let exts = preferredExt[mediatype] ?? []
        let candidates = files.compactMap { f -> (Int, Int, String)? in
            let name = str(f["name"])
            guard let i = exts.firstIndex(where: { name.lowercased().hasSuffix($0) }) else { return nil }
            return (i, -(Int(str(f["size"])) ?? 0), name)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        let out = ResolvedFile(url: candidates.first.flatMap { downloadURL(identifier, $0.2) }, mediatype: mediatype)
        await SearchCache.shared.setFile(identifier, out)
        return out
    }

    /// archive.org génère un .torrent pour (quasi) chaque item.
    public static func resolveArchiveTorrent(_ identifier: String) async throws -> URL? {
        let files = try await metadata(identifier)["files"] as? [JSON] ?? []
        guard let name = files.map({ str($0["name"]) }).first(where: { $0.lowercased().hasSuffix(".torrent") })
        else { return nil }
        return downloadURL(identifier, name)
    }

    // ── Surprise-moi ─────────────────────────────────────────────────────

    public static func randomArchiveItem() async throws -> Item? {
        let col = ["prelinger", "opensource_movies", "classic_tv", "oldtimeradio"].randomElement()!
        let (data, _) = try await HTTP.json(HTTP.url("https://archive.org/advancedsearch.php", [
            ("q", "collection:\(col)"),
            ("fl", "identifier,title,creator,year,mediatype,description,subject,licenseurl"),
            ("output", "json"), ("rows", "1"), ("start", "\(Int.random(in: 0...2000))"),
        ]), source: "archive.org")
        let docs = (data["response"] as? JSON)?["docs"] as? [JSON] ?? []
        return docs.first.map(archiveItem)
    }
}

/// Cache mémoire à TTL : évite de re-taper les sources sur une requête
/// identique répétée (pages précédente/suivante, propositions connexes).
public actor SearchCache {
    public static let shared = SearchCache()
    struct Key: Hashable { let query: SearchQuery }
    private let ttl: TimeInterval = 3600
    private var pages: [Key: (Date, SearchPage)] = [:]
    private var files: [String: (Date, Sources.ResolvedFile)] = [:]

    func get(_ k: Key) -> SearchPage? {
        guard let (t, v) = pages[k], Date().timeIntervalSince(t) < ttl else { return nil }
        return v
    }
    func set(_ k: Key, _ v: SearchPage) {
        pages[k] = (Date(), v)
        if pages.count > 500 {
            for (k, _) in pages.sorted(by: { $0.value.0 < $1.value.0 }).prefix(100) { pages[k] = nil }
        }
    }
    func file(_ id: String) -> Sources.ResolvedFile? {
        guard let (t, v) = files[id], Date().timeIntervalSince(t) < ttl else { return nil }
        return v
    }
    func setFile(_ id: String, _ v: Sources.ResolvedFile) { files[id] = (Date(), v) }
    public func clear() { pages = [:]; files = [:] }
}
