import Foundation

/// Licence ramenée à trois états : réutilisable, restreinte, inconnue.
/// « Inconnu » n'est PAS « libre » — c'est le cas le plus fréquent sur
/// archive.org, et le plus trompeur. `free == nil` veut dire qu'on ne sait pas.
public struct License: Codable, Hashable, Sendable {
    public var code: String
    public var label: String
    public var free: Bool?
    public var url: String

    public static let none = License(code: "", label: "", free: nil, url: "")

    public init(code: String, label: String, free: Bool?, url: String) {
        self.code = code; self.label = label; self.free = free; self.url = url
    }
    // Les fichiers de la version Flask omettent parfois `label`.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? ""
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? code
        free = try? c.decodeIfPresent(Bool.self, forKey: .free)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
    }
    enum CodingKeys: String, CodingKey { case code, label, free, url }
}

/// Un résultat, quelle que soit la source. Mêmes champs que le dict Python,
/// pour pouvoir relire panier, favoris et journal écrits par la version Flask.
public struct Item: Codable, Hashable, Identifiable, Sendable {
    public var title: String
    public var creator: String
    public var year: String
    public var type: String
    public var description: String
    public var url: String
    public var thumbnail: String
    public var source: String
    public var identifier: String
    public var keywords: [String]?
    public var license: License?
    /// mp3 écoutable sans second appel (Freesound).
    public var preview: String?
    /// Format du fichier d'origine (Freesound : wav, flac, aiff, mp3…).
    public var format: String?
    /// Analyse automatique de Freesound. Calculée pour TOUS les sons, même sans
    /// rythme (une corne de brume « à 108 BPM, do mineur ») : une estimation,
    /// à présenter comme telle.
    public var bpm: Double?
    public var tonality: String?

    /// La même clé que le panier et le journal côté Python : `source:identifiant`.
    public var key: String {
        let ident = !identifier.isEmpty ? identifier : (!url.isEmpty ? url : title)
        return "\(source):\(ident)"
    }
    public var id: String { key }

    public init(title: String, creator: String, year: String, type: String, description: String,
                url: String, thumbnail: String, source: String, identifier: String,
                keywords: [String]? = nil, license: License? = nil, preview: String? = nil, format: String? = nil) {
        self.title = title; self.creator = creator; self.year = year; self.type = type
        self.description = description; self.url = url; self.thumbnail = thumbnail
        self.source = source; self.identifier = identifier; self.keywords = keywords
        self.license = license; self.preview = preview; self.format = format
    }

    // Le Python écrivait `year` tantôt en texte, tantôt en nombre (archive.org) :
    // on accepte les deux à la lecture.
    enum CodingKeys: String, CodingKey {
        case title, creator, year, type, description, url, thumbnail, source, identifier, keywords, license, preview, format, bpm, tonality
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String {
            if let v = try? c.decode(String.self, forKey: k) { return v }
            if let v = try? c.decode(Int.self, forKey: k) { return String(v) }
            if let v = try? c.decode(Double.self, forKey: k) { return String(Int(v)) }
            return ""
        }
        title = s(.title); creator = s(.creator); year = s(.year); type = s(.type)
        description = s(.description); url = s(.url); thumbnail = s(.thumbnail)
        source = s(.source); identifier = s(.identifier)
        keywords = try? c.decodeIfPresent([String].self, forKey: .keywords)
        license = try? c.decodeIfPresent(License.self, forKey: .license)
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
        bpm = try? c.decodeIfPresent(Double.self, forKey: .bpm)
        tonality = try? c.decodeIfPresent(String.self, forKey: .tonality)
    }
}

public enum SearchType: String, CaseIterable, Sendable {
    case all = "", film, audio, pdf
    public var label: String {
        switch self {
        case .all: "Tous types"
        case .film: "Films (1920-1980)"
        case .audio: "Audio"
        case .pdf: "PDFs"
        }
    }
}

public enum SortOption: String, CaseIterable, Sendable {
    case relevance = "", dateDesc = "date_desc", downloadsDesc = "downloads_desc"
    public var label: String {
        switch self {
        case .relevance: "Pertinence"
        case .dateDesc: "Plus récent"
        case .downloadsDesc: "Plus téléchargé"
        }
    }
    var archiveParam: String? {
        switch self {
        case .relevance: nil
        case .dateDesc: "date desc"
        case .downloadsDesc: "downloads desc"
        }
    }
}

public enum Collection: String, CaseIterable, Sendable {
    case all = "", prelinger, opensourceMovies = "opensource_movies", classicTV = "classic_tv", oldtimeradio
    public var label: String {
        switch self {
        case .all: "Toutes collections"
        case .prelinger: "Prelinger (films éphémères)"
        case .opensourceMovies: "Films libres"
        case .classicTV: "TV classique"
        case .oldtimeradio: "Radio vintage"
        }
    }
}

/// Filtres appliqués PAR la source : ils ramènent vingt résultats qui
/// conviennent, là où un filtre local trie les vingt reçus.
public struct SourceFilters: Hashable, Sendable, Codable {
    /// Freesound : durée en secondes, bornes incluses.
    public var minDuration: Double?
    public var maxDuration: Double?
    /// Freesound : CC0 seulement (domaine public, aucune attribution).
    public var cc0Only = false
    /// Freesound : tempo estimé, bornes incluses.
    public var minBPM: Int?
    public var maxBPM: Int?
    /// archive.org : première année de la décennie (1950 = 1950-1959).
    public var decade: Int?

    public init(minDuration: Double? = nil, maxDuration: Double? = nil, cc0Only: Bool = false,
                minBPM: Int? = nil, maxBPM: Int? = nil, decade: Int? = nil) {
        self.minDuration = minDuration; self.maxDuration = maxDuration; self.cc0Only = cc0Only
        self.minBPM = minBPM; self.maxBPM = maxBPM; self.decade = decade
    }

    public var isEmpty: Bool { self == SourceFilters() }
    public var hasBPM: Bool { minBPM != nil || maxBPM != nil }

    /// Le paramètre `filter` de l'API Freesound (syntaxe Solr), ou nil.
    public var freesoundFilter: String? {
        var parts: [String] = []
        if minDuration != nil || maxDuration != nil {
            parts.append("duration:[\(minDuration.map { String($0) } ?? "*") TO \(maxDuration.map { String($0) } ?? "*")]")
        }
        if cc0Only { parts.append("license:\"Creative Commons 0\"") }
        if hasBPM { parts.append("bpm:[\(minBPM.map(String.init) ?? "*") TO \(maxBPM.map(String.init) ?? "*")]") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Fragment de requête archive.org, ou nil.
    public var archiveClause: String? {
        decade.map { " AND year:[\($0) TO \($0 + 9)]" }
    }

    /// Pour la clé d'historique : vide sans filtre, pour rester compatible.
    var keySuffix: String {
        guard !isEmpty else { return "" }
        return "|" + [minDuration.map { "d>\($0)" }, maxDuration.map { "d<\($0)" }, cc0Only ? "cc0" : nil,
                      minBPM.map { "b>\($0)" }, maxBPM.map { "b<\($0)" }, decade.map { "y\($0)" }]
            .compactMap { $0 }.joined(separator: ",")
    }
}

public struct SearchQuery: Hashable, Sendable {
    public var source: String
    public var text: String
    public var type: SearchType
    public var sort: SortOption
    public var collection: Collection
    public var page: Int
    public var filters: SourceFilters

    public init(source: String, text: String, type: SearchType = .all, sort: SortOption = .relevance,
                collection: Collection = .all, page: Int = 1, filters: SourceFilters = SourceFilters()) {
        self.source = source; self.text = text; self.type = type
        self.sort = sort; self.collection = collection; self.page = max(1, page); self.filters = filters
    }
}

public struct Related: Hashable, Sendable {
    public var keywords: [String] = []
    public var creators: [String] = []
    public var years: [String] = []
    public var isEmpty: Bool { keywords.isEmpty && creators.isEmpty && years.isEmpty }
    public init(keywords: [String] = [], creators: [String] = [], years: [String] = []) {
        self.keywords = keywords; self.creators = creators; self.years = years
    }
}

public struct SearchPage: Sendable {
    public var results: [Item]
    public var total: Int?
    public var hasMore: Bool
    public var related: Related
}

/// Erreur dite en clair : « HTTPSConnectionPool… Read timed out » n'apprenait
/// rien à l'usager, NSURLErrorDomain -1001 non plus.
public struct SourceError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension Item {
    /// Copie modifiée, pour compléter un item en une expression.
    func with(_ change: (inout Item) -> Void) -> Item { var c = self; change(&c); return c }

    /// « ≈ 108 BPM · do mineur » — toujours marqué comme estimation.
    public var analysisLabel: String? {
        var parts: [String] = []
        if let b = bpm, b > 0 { parts.append("≈ \(Int(b.rounded())) BPM") }
        if let t = tonality, !t.isEmpty { parts.append(t) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
