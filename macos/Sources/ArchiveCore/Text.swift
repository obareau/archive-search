import Foundation

// ── Licences ──────────────────────────────────────────────────────────────
// Un fonds en accès libre n'est PAS un fonds libre de droits. « by-nc-nd »
// interdit la modification : un son sous cette licence ne peut pas entrer dans
// un morceau publié. L'outil doit le dire AVANT le téléchargement, pas après.
// L'ordre compte : « by-nc-nd » doit être testé avant « by ».
let licenseTable: [(String, String, Bool)] = [
    ("publicdomain/zero", "CC0", true),
    ("publicdomain/mark", "Domaine public", true),
    ("licenses/by-nc-nd", "CC BY-NC-ND", false),
    ("licenses/by-nc-sa", "CC BY-NC-SA", false),
    ("licenses/by-nc", "CC BY-NC", false),
    ("licenses/by-nd", "CC BY-ND", false),
    ("licenses/by-sa", "CC BY-SA", true),
    ("licenses/by", "CC BY", true),
    ("licenses/sampling+", "Sampling+", false),
]

public func normalizeLicense(_ raw: String?) -> License {
    let url = (raw ?? "").trimmingCharacters(in: .whitespaces)
    let u = url.lowercased()
    if u.isEmpty { return .none }
    for (needle, label, free) in licenseTable where u.contains(needle) {
        return License(code: label, label: label, free: free, url: url)
    }
    return License(code: "autre", label: "licence non reconnue", free: nil, url: url)
}

// ── Texte ─────────────────────────────────────────────────────────────────

/// Wikimedia (extmetadata) et LibriVox renvoient parfois du HTML brut.
public func stripHTML(_ text: String?) -> String {
    guard let text, !text.isEmpty else { return "" }
    let noTags = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    return decodeEntities(noTags).trimmingCharacters(in: .whitespacesAndNewlines)
}

func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var out = s
    for (e, c) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
        out = out.replacingOccurrences(of: e, with: c)
    }
    return out
}

func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }

// ── Propositions connexes ─────────────────────────────────────────────────
// Dérivées des résultats DÉJÀ obtenus : aucun appel réseau de plus, et ça
// marche pour toute source, même celles sans API de suggestion.

let stopwords: Set<String> = Set("""
le la les un une des du de d l et ou à a au aux en dans sur pour par avec sans
sous the a an and or of in on for to with from at by is it this that
no 01 02 03 mp3 wav flac the_ vol part no. feat remix live edit mix
""".split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

private let timestampRE = try! NSRegularExpression(pattern: "^\\d+(am|pm|h|hrs?|min|sec)$")

/// Mots de 4 lettres et plus, sans mots vides ni nombres. Les horodatages
/// (« 00am », « 14h ») sont écartés — mais PAS « 16mm » ni « super8 », qui
/// sont de vrais termes de recherche pour un fonds film.
public func tokens(_ text: String?) -> [String] {
    guard let text else { return [] }
    // Équivalent de [^\wÀ-ɏ]+ : on coupe sur tout ce qui n'est ni
    // lettre, ni chiffre, ni « _ ».
    let parts = text.lowercased().split(whereSeparator: { ch in
        !(ch.isLetter || ch.isNumber || ch == "_")
    }).map(String.init)
    return parts.filter { w in
        guard w.count >= 4, !stopwords.contains(w), !w.allSatisfy(\.isNumber) else { return false }
        let r = NSRange(w.startIndex..., in: w)
        return timestampRE.firstMatch(in: w, range: r) == nil
    }
}

public func relatedTerms(_ results: [Item], query: String) -> Related {
    let asked = Set(tokens(query))
    var kw: [String: Int] = [:], creators: [String: Int] = [:], years: [String: Int] = [:]
    for r in results {
        for k in r.keywords ?? [] {
            let k = k.trimmingCharacters(in: .whitespaces).lowercased()
            if k.count >= 3, !asked.contains(k), !stopwords.contains(k) { kw[k, default: 0] += 1 }
        }
        for w in tokens(r.title) where !asked.contains(w) { kw[w, default: 0] += 1 }
        let c = r.creator.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty, c.uppercased() != "N/A" { creators[c, default: 0] += 1 }
        let y = String(r.year.prefix(4))
        if y.count == 4, y.allSatisfy(\.isNumber) { years[y, default: 0] += 1 }
    }
    // Vu une seule fois sur vingt résultats, ce n'est pas un thème.
    func top(_ d: [String: Int], _ n: Int, mini: Int = 2) -> [String] {
        d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .filter { $0.value >= mini }.prefix(n).map(\.key)
    }
    return Related(keywords: top(kw, 10), creators: top(creators, 5),
                   years: top(years, 5).sorted(by: >))
}
