// Auto-test du cœur, sans UI.
//   archive-check          → logique pure (licences, termes, propositions)
//   archive-check --live   → en plus, une vraie requête par source
import ArchiveCore
import Foundation

var failures = 0
var passed = 0
func check(_ cond: Bool, _ what: String) {
    if cond { passed += 1 } else { failures += 1; print("✗ \(what)") }
}

// ── Licences : l'ordre de la table compte (by-nc-nd avant by) ────────────
check(normalizeLicense("http://creativecommons.org/licenses/by-nc-nd/3.0/").free == false, "by-nc-nd restrictif")
check(normalizeLicense("https://creativecommons.org/licenses/by/4.0/").code == "CC BY", "by réutilisable")
check(normalizeLicense("https://creativecommons.org/licenses/by-sa/4.0/").free == true, "by-sa réutilisable")
check(normalizeLicense("http://creativecommons.org/publicdomain/zero/1.0/").code == "CC0", "CC0")
check(normalizeLicense("").free == nil && normalizeLicense("").code.isEmpty, "absente = inconnue")
check(normalizeLicense("http://example.com/terms").free == nil, "non reconnue = inconnue, pas libre")

// ── Termes : horodatages écartés, 16mm et super8 gardés ──────────────────
let t = tokens("Night fog 00am 01pm 14h 16mm super8 1956 the foghorn")
check(t.contains("16mm") && t.contains("super8") && t.contains("foghorn"), "16mm/super8/foghorn gardés : \(t)")
check(!t.contains("00am") && !t.contains("01pm") && !t.contains("1956"), "horodatages et nombres écartés : \(t)")
check(tokens("Brume côtière à l'aube").contains("côtière"), "accents conservés")

// ── Propositions connexes : seuil à 2 ────────────────────────────────────
func item(_ title: String, _ creator: String, _ year: String, _ kw: [String]) -> Item {
    Item(title: title, creator: creator, year: year, type: "audio", description: "", url: "",
         thumbnail: "", source: "archive.org", identifier: title, keywords: kw)
}
let rel = relatedTerms([
    item("Foghorn at dusk", "Ann", "1955", ["foghorn", "coast"]),
    item("Lighthouse foghorn", "Ann", "1955", ["coast"]),
    item("Harbour bells", "Bob", "1960", ["port"]),
], query: "fog")
check(rel.keywords.first == "coast" || rel.keywords.first == "foghorn", "mot-clé récurrent en tête : \(rel.keywords)")
check(!rel.keywords.contains("harbour"), "vu une seule fois ≠ thème")
check(rel.creators == ["Ann"] && rel.years == ["1955"], "auteur et année récurrents")

// ── Item : relit le JSON écrit par la version Flask (year numérique) ─────
let legacy = #"{"title":"T","creator":"C","year":1956,"type":"movies","description":"","url":"u","thumbnail":"","source":"archive.org","identifier":"abc","license":{"code":"","label":"","free":null,"url":""}}"#
let decoded = try? JSONDecoder().decode(Item.self, from: Data(legacy.utf8))
check(decoded?.year == "1956" && decoded?.key == "archive.org:abc", "item Flask relu")

// ── En ligne ──────────────────────────────────────────────────────────────
if CommandLine.arguments.contains("--live") {
    let sema = DispatchSemaphore(value: 0)
    Task {
        for src in ["archive.org", "wikimedia", "librivox", "freesound", "gutenberg"] {
            let start = Date()
            do {
                let p = try await Sources.search(SearchQuery(source: src, text: src == "librivox" ? "the" : "foghorn"))
                let lic = p.results.filter { $0.license?.free == true }.count
                print(String(format: "  %@ %2d résultats, total %@, %d réutilisables, %.1f s",
                             src.padding(toLength: 12, withPad: " ", startingAt: 0), p.results.count, p.total.map(String.init) ?? "?", lic, Date().timeIntervalSince(start)))
                if let f = p.results.first { print("               « \(f.title) » — \(f.creator)") }
                if !p.related.isEmpty { print("               connexes : \(p.related.keywords.prefix(5).joined(separator: ", "))") }
            } catch {
                print(String(format: "  %@ ⚠ %@", src.padding(toLength: 12, withPad: " ", startingAt: 0), error.localizedDescription))
            }
        }
        if let r = try? await Sources.resolveArchiveFile("DuckAndCover_185") {
            print("  fichier      \(r.mediatype) → \(r.url?.absoluteString ?? "aucun")")
        }
        sema.signal()
    }
    sema.wait()
}

print(failures == 0 ? "✓ archive-check : \(passed) vérifications" : "✗ archive-check : \(failures) échec(s) sur \(passed + failures)")
exit(failures == 0 ? 0 : 1)
