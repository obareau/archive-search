import Foundation
import FoundationModels
import NaturalLanguage

// ── Fouille : un thème, un champ lexical, plusieurs passes ────────────────
// Une recherche ordinaire pose UNE question. Fouiller, c'est en poser vingt et
// recouper. Deux passes, et la seconde est celle qui compte : le modèle ouvre
// la porte, mais c'est le FONDS qui fournit le vocabulaire juste.
public enum Hunt {
    public static let termsMax = 18
    public static let pass2Terms = 5
    /// Plafond de COÛT, pas de pertinence : chaque document est plongé.
    public static let keep = 250
    public static var spacing: TimeInterval {
        ProcessInfo.processInfo.environment["HUNT_SPACING_S"].flatMap(Double.init) ?? 1.2
    }
    /// Gutenberg est hors du lot : 15 à 30 s la requête, il mangerait sept minutes.
    public static let defaultSources = ["archive.org", "freesound", "wikimedia", "librivox"]

    /// Minuscules, dédoublonné, borné. Un mot collé passe : le refuser
    /// écarterait aussi « foghorn » ou « super8 ».
    public static func cleanTerms(_ raw: [String]) -> [String] {
        var out: [String] = []
        for x in raw {
            let s = x.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                .lowercased()
            if (2...40).contains(s.count), !out.contains(s) { out.append(s) }
        }
        return Array(out.prefix(termsMax))
    }

    // ── Le champ lexical ─────────────────────────────────────────────────

    public enum Model: Hashable, Sendable {
        case apple
        case ollama(String)
        public var label: String {
            switch self {
            case .apple: "Apple (sur l'appareil)"
            case .ollama(let m): "\(m) (Ollama)"
            }
        }
    }

    public static var appleAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public static var appleUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence est désactivé (Réglages Système › Apple Intelligence et Siri)"
        case .unavailable(.deviceNotEligible): return "ce Mac ne prend pas en charge Apple Intelligence"
        case .unavailable(.modelNotReady): return "le modèle d'Apple est encore en téléchargement"
        case .unavailable(let r): return "modèle d'Apple indisponible (\(r))"
        }
    }

    static var ollamaURL: String { ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434" }

    /// Les modèles Ollama installés, s'il tourne. Liste vide sinon, sans bruit.
    public static func ollamaModels() async -> [String] {
        guard let u = URL(string: "\(ollamaURL)/api/tags"),
              let (d, _) = try? await HTTP.session(3).data(from: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return (j["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            .filter { !$0.contains("embed") }
    }

    // Mesuré le 2026-11-15 avec le modèle d'Apple (~3 B) : avec le prompt de la
    // version web (en français), il répondait en français (« son rocher »,
    // « son ombre ») et jamais « foghorn ». Ce qui l'a redressé :
    //   · des instructions en anglais et un exemple sur un thème SANS rapport
    //   · une liste de mots vagues interdits (sound, recording, archive…)
    //   · la traduction du thème dans une séance à part : demandée en même
    //     temps, « orgue de barbarie » sortait « orgue of barbarity »
    static let fieldInstructions = """
    You are an archivist who knows how audio and film collections are catalogued on archive.org, Freesound and Wikimedia Commons.
    From a theme, you list the ENGLISH search phrases a cataloguer would actually have written in titles and tags.

    Example — theme "early morning fish market": fish market, fishmonger, auction bell, ice crusher, harbour gulls, crate unloading, billingsgate, trawler, wholesale market, fish auction

    Rules:
    - concrete things: objects, machines, places, trades, events, natural phenomena; include 2 or 3 expert or technical names
    - 1 to 3 lowercase English words per phrase; prefer two-word phrases
    - never use these vague words alone: sound, sounds, audio, recording, music, noise, archive, ambience, atmosphere, night, acoustic
    - no duplicates, no French
    """

    static let translateInstructions = "Translate the user's text to natural English. Use the usual English name for things (for example « orgue de barbarie » is a barrel organ). If it is already English, repeat it. Answer with the translation only."

    public struct Field: Sendable {
        public var terms: [String]
        public var english: String
        /// Dit toujours d'où vient le champ : un champ réduit en silence au
        /// thème serait une fouille qui n'en est pas une.
        public var note: String
    }

    public static func expandField(_ theme: String, model: Model = .apple, n: Int = 14) async -> Field {
        let t0 = Date()
        do {
            switch model {
            case .apple:
                if let why = appleUnavailableReason {
                    return Field(terms: [theme], english: theme, note: "\(why) — champ réduit au thème, à compléter à la main")
                }
                let tr = LanguageModelSession(instructions: translateInstructions)
                let english = try await tr.respond(to: theme, options: GenerationOptions(temperature: 0))
                    .content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"«»")))
                let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Field", properties: [
                    .init(name: "terms", description: "English search phrases",
                          schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self),
                                                          minimumElements: 6, maximumElements: n)),
                ]), dependencies: [])
                let s = LanguageModelSession(instructions: fieldInstructions)
                let r = try await s.respond(to: "Theme: \(english)", schema: schema, options: GenerationOptions(temperature: 0.4))
                let terms = cleanTerms(try r.content.value([String].self, forProperty: "terms"))
                guard !terms.isEmpty else {
                    return Field(terms: [theme], english: english, note: "le modèle d'Apple n'a rendu aucun terme — champ réduit au thème")
                }
                return Field(terms: terms, english: english,
                             note: String(format: "champ proposé par le modèle d'Apple, sur l'appareil, en %.1f s (%d termes) — à corriger librement", Date().timeIntervalSince(t0), terms.count))
            case .ollama(let name):
                let prompt = fieldInstructions + "\n\nTheme: \(theme)\nAnswer in JSON: {\"terms\": [\"...\"]} with at most \(n) terms."
                var req = URLRequest(url: URL(string: "\(ollamaURL)/api/generate")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": name, "prompt": prompt, "format": "json", "stream": false,
                    "keep_alive": "30m", "options": ["temperature": 0.7],
                ])
                req.timeoutInterval = 180
                let (d, _) = try await URLSession.shared.data(for: req)
                let resp = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["response"] as? String ?? ""
                let obj = try JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any]
                let terms = cleanTerms(obj?["terms"] as? [String] ?? [])
                guard !terms.isEmpty else { return Field(terms: [theme], english: theme, note: "\(name) n'a rendu aucun terme — champ réduit au thème") }
                return Field(terms: terms, english: theme,
                             note: String(format: "champ proposé par %@ en %.1f s (%d termes) — à corriger librement", name, Date().timeIntervalSince(t0), terms.count))
            }
        } catch let e as LanguageModelSession.GenerationError {
            let why: String = switch e {
            case .guardrailViolation: "le modèle d'Apple refuse ce thème (garde-fous)"
            case .unsupportedLanguageOrLocale: "le modèle d'Apple ne prend pas en charge cette langue"
            case .exceededContextWindowSize: "thème trop long pour le modèle d'Apple"
            default: "le modèle d'Apple a échoué (\(e.localizedDescription))"
            }
            return Field(terms: [theme], english: theme,
                         note: "\(why) — champ réduit au thème, à compléter à la main" + (model == .apple ? " (ou essayer un modèle Ollama)" : ""))
        } catch {
            return Field(terms: [theme], english: theme, note: "modèle injoignable (\(error.localizedDescription)) — champ réduit au thème, à compléter à la main")
        }
    }

    // ── Classement par proximité au thème ────────────────────────────────

    static let sourceArtifacts: Set<String> = ["geograph", "wikimedia", "commons", "freesound", "archive", "librivox", "jpg", "ogg"]

    public static func docTextPublic(_ item: Item) -> String { docText(item) }

    static func docText(_ item: Item) -> String {
        let d = String(item.description.prefix(200))
        return d.isEmpty ? item.title : "\(item.title) — \(d)"
    }

    public static func cos(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Proximité au thème d'abord, le reste pour départager. La pesée ×14 / ×1
    /// vient de la version web ; elle est re-mesurée sur ce plongement-ci
    /// (`archive-check --hunt`) et figée par l'auto-test.
    public static let relWeight = 14.0

    public static func score(item: Item, hits: Int, rel: Double?, taken: Bool) -> Double {
        var s = relWeight * (rel ?? 0) + Double(hits)
        switch item.license?.free {
        case true: s += 2
        case false: s -= 1
        default: break
        }
        if item.source == "archive.org" || item.source == "freesound" { s += 1 }   // un vrai fichier
        if !(item.preview ?? "").isEmpty { s += 1 }                                // écoutable tout de suite
        if taken { s -= 4 }                                                        // on fouille pour du neuf
        return s
    }

    // ── Le lot ───────────────────────────────────────────────────────────

    public struct TermYield: Sendable, Identifiable {
        public let term: String
        public let origin: String      // « champ » ou « fonds »
        public let found: Int
        public let new: Int
        public var id: String { origin + term }
    }

    public struct Ranked: Sendable, Identifiable {
        public let item: Item
        public let hits: [String]
        public let rel: Double?
        public let score: Double
        public var id: String { item.key }
    }

    public struct Progress: Sendable {
        public var step = 0
        public var steps = 0
        public var current = ""
        public var report: [TermYield] = []
        public var errors: [String] = []
        public var pass2: [String] = []
        public var ranking = ""
        public var results: [Ranked] = []
        public var harvested = 0
        public init() {}
    }

    public static func run(theme: String, terms: [String], sources: [String], queryText: String? = nil,
                           search: @escaping @Sendable (String, String) async throws -> [Item] = { src, term in
                               try await Sources.search(SearchQuery(source: src, text: term)).results
                           },
                           spacing: TimeInterval = Hunt.spacing,
                           report: @escaping @Sendable (Progress) -> Void) async -> Progress {
        var p = Progress()
        var harvest: [String: (item: Item, terms: [String])] = [:]
        var order: [String] = []
        var dead = Set<String>()
        p.steps = terms.count + pass2Terms + 1

        func one(_ term: String, _ origin: String) async {
            var found = 0, fresh = 0
            for src in sources where !dead.contains(src) {
                if Task.isCancelled { return }
                do {
                    let t0 = Date()
                    let results = try await search(src, term)
                    for r in results {
                        if harvest[r.key] != nil {
                            if !harvest[r.key]!.terms.contains(term) { harvest[r.key]!.terms.append(term) }
                        } else {
                            harvest[r.key] = (r, [term]); order.append(r.key); fresh += 1
                        }
                        found += 1
                    }
                    // Espacer — sauf réponse du cache (instantanée) : quinze
                    // requêtes d'affilée ressemblent à du moissonnage.
                    if Date().timeIntervalSince(t0) > 0.05 { try? await Task.sleep(for: .seconds(spacing)) }
                } catch {
                    // Une source qui tombe sort de la rotation, le rapport le dit une fois.
                    dead.insert(src)
                    p.errors.append("\(src) — \(error.localizedDescription)")
                }
            }
            p.report.append(TermYield(term: term, origin: origin, found: found, new: fresh))
            p.step += 1
            p.harvested = harvest.count
            report(p)
        }

        for t in terms {
            if Task.isCancelled { break }
            p.current = t; report(p)
            await one(t, "champ")
        }

        // Passe 2 : le vocabulaire du fonds lui-même.
        // « geograph » remonte des noms de fichiers Wikimedia (geograph.org.uk) :
        // un artefact de la source, pas du vocabulaire du thème.
        let known = Set(terms.map { $0.lowercased() }).union(tokens(theme)).union(sourceArtifacts)
        let rel = relatedTerms(order.compactMap { harvest[$0]?.item }, query: theme)
        p.pass2 = Array((rel.keywords + rel.creators).filter { !known.contains($0.lowercased()) }.prefix(pass2Terms))
        p.steps = terms.count + p.pass2.count + 1
        for t in p.pass2 {
            if Task.isCancelled { break }
            p.current = "\(t) (du fonds)"; report(p)
            await one(t, "fonds")
        }

        // Classement. Requête = le THÈME TRADUIT en anglais, mesuré le
        // 2026-11-15 sur « brume et cornes de brume sur une côte de nuit »
        // (819 documents, NLContextualEmbedding) :
        //   thème traduit   écart 0.276 — « Fog horn as heard from shore » en
        //                   tête, les huit premiers dans le thème
        //   champ anglais   écart 0.296 mais un jet « Skyhawk Tank » 7e : le
        //                   champ du modèle d'Apple porte son bruit (« kerosene
        //                   tank ») jusque dans le classement
        //   thème français  écart 0.180 — « Salt Spray », « Green Flare » en
        //                   tête : le fonds est anglophone (déjà vu sur nomic)
        let entries = order.prefix(keep).compactMap { harvest[$0] }
        p.current = "classement de \(entries.count) documents"; report(p)
        var rels: [String: Double] = [:]
        let query = queryText ?? (terms.isEmpty ? theme : terms.joined(separator: " "))
        let t0 = Date()
        if let qv = Embedder.shared.vector(query) {
            for e in entries {
                if Task.isCancelled { break }
                if let v = Embedder.shared.vector(docText(e.item)) { rels[e.item.key] = cos(qv, v) }
            }
            p.ranking = String(format: "proximité au thème (plongement NaturalLanguage, %.1f s)", Date().timeIntervalSince(t0))
        } else {
            // Sans plongement on le DIT : un classement dégradé en silence se
            // lirait comme un mauvais fonds.
            p.ranking = "mots-clés seuls — plongement NaturalLanguage indisponible"
            p.errors.append(p.ranking)
        }
        let taken = Journal.takenKeys()
        p.results = entries.map { e in
            let r = rels[e.item.key]
            return Ranked(item: e.item, hits: e.terms, rel: r,
                          score: score(item: e.item, hits: e.terms.count, rel: r, taken: taken.contains(e.item.key)))
        }.sorted { $0.score > $1.score }
        p.step += 1
        p.current = ""
        report(p)
        return p
    }
}

/// Plongement de phrase local : NLContextualEmbedding (le modèle multilingue
/// d'Apple, 512 dimensions), moyenné sur les jetons. Remplace nomic-embed-text
/// d'Ollama — aucun serveur, rien à installer.
public final class Embedder: @unchecked Sendable {
    public static let shared = Embedder()
    private let lock = NSLock()
    private var model: NLContextualEmbedding?
    private var loaded = false

    public func vector(_ text: String) -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loaded = true
            if let m = NLContextualEmbedding(language: .english), m.hasAvailableAssets, (try? m.load()) != nil { model = m }
        }
        guard let model, !text.isEmpty,
              let r = try? model.embeddingResult(for: text, language: .english) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var n = 0
        r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
            n += 1
            return true
        }
        return n > 0 ? sum.map { $0 / Double(n) } : nil
    }
}
