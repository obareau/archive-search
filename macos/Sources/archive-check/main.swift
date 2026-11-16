// Auto-test du cœur, sans UI.
//   archive-check          → logique pure (licences, termes, propositions)
//   archive-check --live   → en plus, une vraie requête par source
import ArchiveCore
import Foundation

// Données dans un dossier jetable : l'auto-test ne touche jamais au vrai
// panier ni au vrai journal.
let TMP = FileManager.default.temporaryDirectory.appendingPathComponent("archive-check-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: TMP, withIntermediateDirectories: true)
setenv("DATA_DIR", TMP.path, 1)
setenv("DOWNLOADS_FILE", TMP.appendingPathComponent("downloads.json").path, 1)
setenv("DOWNLOAD_DIR", TMP.appendingPathComponent("dl").path, 1)
setenv("HISTORY_FILE", TMP.appendingPathComponent("history.json").path, 1)
defer { try? FileManager.default.removeItem(at: TMP) }

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


// ── Journal et crédits (port de test_downloads.py) ───────────────────────
let fm = FileManager.default
func lic(_ code: String, _ free: Bool?) -> License { License(code: code, label: code, free: free, url: code.isEmpty ? "" : "https://x/\(code)") }
let SON = Item(title: "Pluie sur tôle.wav", creator: "fieldrec", year: "", type: "son", description: "",
               url: "https://freesound.org/s/4242/", thumbnail: "", source: "freesound", identifier: "4242",
               license: lic("CC BY", true))
let FILM = Item(title: "Coronet Instructional", creator: "Coronet", year: "", type: "movies", description: "",
                url: "https://archive.org/details/coronet01", thumbnail: "", source: "archive.org", identifier: "coronet01",
                license: lic("", nil))
let ND = Item(title: "Piste verrouillée", creator: "qqn", year: "", type: "son", description: "", url: "u",
              thumbnail: "", source: "freesound", identifier: "9", license: lic("CC BY-NC-ND", false))
func touch(_ u: URL) { try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); fm.createFile(atPath: u.path, contents: Data("x".utf8)) }

check(SON.key == "freesound:4242", "clé identique au panier")

do {  // un fichier disparu est oublié
    let f = TMP.appendingPathComponent("pluie.wav"); touch(f)
    Journal.note(SON, dest: f, size: 4)
    let (e, live) = Journal.live(SON)
    check(e != nil && live.map(\.path) == [f.path] && e?.license == "CC BY", "journal note un fichier")
    check(Journal.live(FILM).0 == nil, "item jamais pris → rien")
    try? fm.removeItem(at: f)
    check(Journal.live(SON).0 == nil && Journal.live(SON).1.isEmpty, "fichier effacé à la main → à reprendre")
}
do {  // chaque emplacement est retenu, le plus récent d'abord, élagage des morts
    let a = TMP.appendingPathComponent("projA/s.mp3"), b = TMP.appendingPathComponent("projB/s.mp3")
    touch(a); touch(b)
    Journal.note(SON, dest: a, size: 1); Journal.note(SON, dest: b, size: 1)
    let live = Journal.live(SON).1.map(\.path)
    check(Set(live) == [a.path, b.path] && live.first == b.path, "deux emplacements, le plus récent d'abord : \(live)")
    try? fm.removeItem(at: a)
    Journal.note(SON, dest: b, size: 1)
    check(Journal.live(SON).1.map(\.path) == [b.path], "chemin mort élagué")
}
do {  // forme ancienne `path`
    let old = #"{"k":{"title":"t","path":"/x/y.mp3","at":"2026-10-11T10:00:00"},"j":{"paths":["/a","/b"]},"z":{}}"#
    let d = try? JSONDecoder().decode([String: Journal.Entry].self, from: Data(old.utf8))
    check(d?["k"]?.paths == ["/x/y.mp3"] && d?["j"]?.paths == ["/a", "/b"] && d?["z"]?.paths == [], "journal ancien relu")
}
check(!Credits.line(SON, file: "a.wav").contains("⚠"), "crédit libre sans ⚠")
check(Credits.line(FILM, file: "b.mp4").contains("licence inconnue") && Credits.line(FILM, file: "b.mp4").contains("non déclarée"), "crédit inconnu signalé")
check(Credits.line(ND, file: "c.wav").contains("restrictive"), "crédit restrictif signalé")
do {  // ajout sans écraser
    let d = TMP.appendingPathComponent("lot"); try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    Credits.write(in: d, [("a.wav", Credits.line(SON, file: "a.wav"))])
    Credits.write(in: d, [("b.mp4", Credits.line(FILM, file: "b.mp4"))])
    let txt = (try? String(contentsOf: d.appendingPathComponent("CREDITS.txt"), encoding: .utf8)) ?? ""
    check(txt.components(separatedBy: "CRÉDITS").count == 2, "en-tête une seule fois")
    check(txt.contains("a.wav") && txt.contains("b.mp4") && txt.components(separatedBy: "── lot du").count == 3, "second lot ajouté, pas écrasé")
}
do {  // pas de double crédit
    let d = TMP.appendingPathComponent("lot2"); try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    Credits.write(in: d, [("a.wav", Credits.line(SON, file: "a.wav"))])
    Credits.write(in: d, [("a.wav", Credits.line(SON, file: "a.wav"))])
    let txt = (try? String(contentsOf: d.appendingPathComponent("CREDITS.txt"), encoding: .utf8)) ?? ""
    check(txt.components(separatedBy: "fichier : a.wav").count == 2 && txt.components(separatedBy: "── lot du").count == 2, "fichier déjà crédité non recrédité")
}
do {
    let d = TMP.appendingPathComponent("vide"); try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    Credits.write(in: d, [])
    check(!fm.fileExists(atPath: d.appendingPathComponent("CREDITS.txt").path), "lot vide → pas de fiche")
}
do {  // homonymes suffixés, extension réelle
    let d = TMP.appendingPathComponent("dest")
    let a = try! Downloader.destPath(d, SON, ext: ".mp3"); touch(a)
    let b = try! Downloader.destPath(d, SON, ext: ".mp3")
    check(a.lastPathComponent == "Pluie sur tôle.mp3", "extension réelle, pas .wav.mp3 : \(a.lastPathComponent)")
    check(b.lastPathComponent == "Pluie sur tôle (1).mp3", "homonyme suffixé : \(b.lastPathComponent)")
}
check(Downloader.safeName("../../.ssh/id") == "....sshid" || !Downloader.safeName("../../.ssh/id").contains("/"), "pas de séparateur dans un nom")
check(!Downloader.safeName(".cache").hasPrefix("."), "pas de point initial")
do {  // reprise locale : déjà dans le dossier → rien ; ailleurs → copie sans réseau
    let lotA = TMP.appendingPathComponent("reprise/A"), lotB = TMP.appendingPathComponent("reprise/B")
    let f = lotA.appendingPathComponent("archive.org/Coronet Instructional.mp4"); touch(f)
    Journal.note(FILM, dest: f, size: 1)
    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var pa = Downloader.Progress(), pb = Downloader.Progress()
    Task {
        pa = await Downloader.run([FILM], into: lotA) { _ in }
        pb = await Downloader.run([FILM], into: lotB) { _ in }
        sema.signal()
    }
    sema.wait()
    check(pa.reused.first?.contains("déjà dans ce dossier") == true && pa.errors.isEmpty, "déjà sous la destination → rien : \(pa.reused) \(pa.errors)")
    check(pb.reused.first?.contains("sans réseau") == true && fm.fileExists(atPath: lotB.appendingPathComponent("archive.org/Coronet Instructional.mp4").path), "ailleurs → copie locale : \(pb.reused) \(pb.errors)")
    check(Journal.live(FILM).1.count == 2, "les deux copies au journal")
    check(fm.fileExists(atPath: lotB.appendingPathComponent("CREDITS.txt").path), "fiche de crédits écrite")
}
do {  // une source sans fichier est écartée avec sa raison
    let wiki = Item(title: "Phare", creator: "x", year: "", type: "media", description: "", url: "https://commons.wikimedia.org/x",
                    thumbnail: "", source: "wikimedia", identifier: "File:Phare.jpg")
    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var p = Downloader.Progress()
    Task { p = await Downloader.run([wiki], into: TMP.appendingPathComponent("w")) { _ in }; sema.signal() }
    sema.wait()
    check(p.errors.first?.contains("page web") == true && p.done == 1, "wikimedia écarté : \(p.errors)")
}
check(Downloader.batchFolder(chosen: Downloader.defaultRoot).lastPathComponent.count == "2026-11-15_1930".count, "racine → sous-dossier horodaté")
check(Downloader.batchFolder(chosen: TMP).path == TMP.path, "dossier choisi → tel quel")


// ── Historique, nouveauté, veille ────────────────────────────────────────
func its(_ ids: [String]) -> [Item] {
    ids.map { Item(title: "t\($0)", creator: "", year: "", type: "", description: "", url: "", thumbnail: "",
                   source: "archive.org", identifier: $0) }
}
do {
    let q1 = SearchQuery(source: "archive.org", text: "Foghorn ", page: 1)
    check(History.record(q1, its(["a", "b"])).isEmpty, "recherche inédite : rien de nouveau")
    let fresh = History.record(q1, its(["a", "b", "c"]))
    check(fresh == ["c"], "deuxième passage : seul c est neuf (\(fresh))")
    // La page n'entre pas dans la clé, la casse non plus ; la page 2 ne touche
    // ni au compteur ni au nombre de passages.
    var q2 = SearchQuery(source: "archive.org", text: "foghorn", page: 2)
    q2.page = 2
    check(History.key(q1) == History.key(q2), "clé sans page ni casse")
    let f2 = History.record(q2, its(["d"]))
    let e = History.list().first { $0.key == History.key(q1) }?.entry
    check(f2 == ["d"] && e?.new_count == 1 && e?.runs == 2 && e?.seen.count == 4, "page 2 : d neuf mais compteur et passages inchangés (\(e?.new_count ?? -1), \(e?.runs ?? -1))")
    // Un autre type = une autre recherche.
    check(History.key(SearchQuery(source: "archive.org", text: "foghorn", type: .audio)) != History.key(q1), "le type entre dans la clé")
}
do {  // plafond du « déjà vu »
    let q = SearchQuery(source: "freesound", text: "rain")
    History.record(q, its((0..<450).map(String.init)))
    check(History.list().first { $0.key == History.key(q) }?.entry.seen.count == History.seenMax, "déjà vu plafonné à \(History.seenMax)")
}
do {  // oubli : le déjà-vu part avec, la relance repart de zéro
    let q = SearchQuery(source: "wikimedia", text: "phare")
    History.record(q, its(["x"]))
    History.forget(History.key(q))
    check(History.record(q, its(["x", "y"])).isEmpty, "oubliée puis relancée : rien de nouveau")
}
do {  // l'historique de la version web se relit
    let legacy = #"{"archive.org|fog|||":{"query":"fog","source":"archive.org","type":"","sort":"","collection":"","first_seen":"2026-10-11T10:00:00","last_run":"2026-10-12T10:00:00","runs":3,"seen":{"a":"2026-10-11T10:00:00"},"new_count":0,"watch":true}}"#
    let d = try? JSONDecoder().decode([String: History.Entry].self, from: Data(legacy.utf8))
    check(d?["archive.org|fog|||"]?.watch == true && d?["archive.org|fog|||"]?.searchQuery.text == "fog", "history.json Flask relu")
}
do {  // veille : une source en panne n'arrête pas les autres ; ne parle que s'il y a du neuf
    History.clear()
    let ok = SearchQuery(source: "archive.org", text: "fog"), down = SearchQuery(source: "freesound", text: "fog"),
        calm = SearchQuery(source: "wikimedia", text: "fog")
    for q in [ok, down, calm] { History.record(q, its(["a"])); History.setWatch(History.key(q), true) }
    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var rep = Watch.PassReport()
    Task {
        rep = await Watch.pass(spacing: 0) { q in
            if q.source == "freesound" { throw SourceError("panne") }
            return its(q.source == "archive.org" ? ["a", "neuf"] : ["a"])
        }
        sema.signal()
    }
    sema.wait()
    check(rep.checked == 2 && rep.failures.count == 1, "panne notée, les autres passent (\(rep.checked), \(rep.failures))")
    check(rep.findings.count == 1 && rep.findings.first?.fresh.map { $0.identifier } == ["neuf"], "seule la recherche avec du neuf parle")
    History.setWatch(History.key(ok), false)
    check(History.watched().count == 2, "veille désactivable")
}


// ── Fouille (port de test_hunt.py) ───────────────────────────────────────
check(Hunt.cleanTerms([" FogHorn ", "fog  bank", "foghorn"]) == ["foghorn", "fog bank"], "termes nettoyés")
check(Hunt.cleanTerms(["a"]).isEmpty && Hunt.cleanTerms([String(repeating: "x", count: 60)]).isEmpty, "bornes des termes")
check(Hunt.cleanTerms(["weatherphenomena"]) == ["weatherphenomena"], "mot collé accepté")
check(Hunt.cleanTerms((0..<40).map { "t\($0)" }).count == Hunt.termsMax, "plafond de termes")
check(abs(Hunt.cos([1, 0], [1, 0]) - 1) < 1e-9 && abs(Hunt.cos([1, 0], [0, 1])) < 1e-9 && Hunt.cos([0, 0], [1, 1]) == 0, "cosinus")
do {
    let fs = Item(title: "t", creator: "", year: "", type: "", description: "", url: "", thumbnail: "",
                  source: "freesound", identifier: "i", license: lic("c", true), preview: "p")
    // Le bug mesuré : « coast river » (0.514, deux termes) passait devant un foghorn (0.708, un terme).
    check(Hunt.score(item: fs, hits: 1, rel: 0.708, taken: false) > Hunt.score(item: fs, hits: 2, rel: 0.514, taken: false), "la proximité bat la centralité")
    check(Hunt.score(item: fs, hits: 2, rel: 0.6, taken: false) > Hunt.score(item: fs, hits: 1, rel: 0.6, taken: false), "à proximité égale, la centralité départage")
    check(Hunt.score(item: fs, hits: 1, rel: 0.6, taken: true) < Hunt.score(item: fs, hits: 1, rel: 0.6, taken: false) - 3, "déjà pris rétrogradé")
    var nd = fs; nd.license = lic("CC BY-NC-ND", false)
    check(Hunt.score(item: fs, hits: 1, rel: 0.5, taken: false) > Hunt.score(item: nd, hits: 1, rel: 0.5, taken: false), "licence restrictive derrière")
    var long = fs; long.description = String(repeating: "d", count: 500)
    check(Hunt.docTextPublic(long).count < 230, "texte du document borné")
}
do {  // le plongement local classe le foghorn devant le vaporisateur (sans réseau)
    let q = Embedder.shared.vector("fog and foghorns on a night coast")
    let horn = Embedder.shared.vector("Fog horn as heard from shore — foghorn blowing at night from the lighthouse")
    let spray = Embedder.shared.vector("Spray Bottle — spritzing a plastic spray bottle in the kitchen")
    if let q, let horn, let spray {
        let a = Hunt.cos(q, horn), b = Hunt.cos(q, spray)
        // Écart observé ~0.1 ; ×14 = 1,4 point, de quoi battre un terme de plus.
        check(a - b > 0.05, String(format: "foghorn (%.3f) nettement devant le vaporisateur (%.3f)", a, b))
    } else {
        check(false, "plongement NaturalLanguage indisponible")
    }
}

do {  // un terme du fonds n'achète pas de centralité (cas mesuré : vent sur la Meuse devant un foghorn)
    func fs(_ id: String, _ title: String, _ desc: String, _ kw: [String]) -> Item {
        Item(title: title, creator: "klankbeeld", year: "2025", type: "son", description: desc, url: "", thumbnail: "",
             source: "freesound", identifier: id, keywords: kw, license: lic("CC BY", true), preview: "p")
    }
    let wind = [fs("w1", "wind riverside Meuse Netherlands 749 PM", "Wind in trees and bushes on April day at the river Maas near Bokhoven in the south of the Netherlands. Birds and far the hum of an inland ship", ["netherlands"]),
                fs("w2", "wind riverside Meuse Netherlands 754 PM", "Wind in trees and bushes at the river Maas in the south of the Netherlands", ["netherlands"])]
    let horn = fs("h1", "Fog horn as heard from shore", "Down by the shore on a very foggy morning. Gentle waves from the wash of a passing ship with a couple of blasts from a distant foghorn", ["foghorn"])
    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var p = Hunt.Progress()
    Task {
        p = await Hunt.run(theme: "brume et cornes de brume", terms: ["fog bank", "foghorn blast"], sources: ["freesound"],
                           queryText: "Fog and foghorns on a night coast",
                           search: { _, term in
                               switch term {
                               case "fog bank": return wind
                               case "foghorn blast": return [horn]
                               case "netherlands": return wind
                               default: return []
                               }
                           }, spacing: 0) { _ in }
        sema.signal()
    }
    sema.wait()
    check(p.pass2.contains("netherlands"), "netherlands vient bien du fonds : \(p.pass2)")
    check(p.results.first?.item.identifier == "h1", "le foghorn devant le vent de la Meuse : \(p.results.map { "\($0.item.identifier) \(String(format: "%.2f", $0.score))" })")
}

// ── Toutes les sources : intercalage ─────────────────────────────────────
do {
    func it(_ src: String, _ id: String) -> Item {
        Item(title: id, creator: "", year: "", type: "", description: "", url: "", thumbnail: "", source: src, identifier: id)
    }
    let m = Sources.interleave([[it("a", "1"), it("a", "2"), it("a", "3")], [it("f", "x")], [it("w", "p"), it("a", "1")]])
    check(m.map(\.identifier) == ["1", "x", "p", "2", "3"], "intercalé source par source, doublon écarté : \(m.map(\.identifier))")
    check(Sources.all.first?.id == Sources.allID && !Sources.allSources.contains("loc.gov"), "« toutes » en tête, sans loc.gov")
}

// ── Paniers par projet ────────────────────────────────────────────────────
do {
    let legacyCart = [Item(title: "Ancien", creator: "", year: "", type: "", description: "", url: "u", thumbnail: "",
                           source: "archive.org", identifier: "old1")]
    try? Store.write(legacyCart, Store.List.cart.file)
    try? fm.removeItem(at: Projects.file)
    check(Projects.load().activeProject.name == Projects.defaultName && Store.readList(.cart).map(\.identifier) == ["old1"],
          "l'ancien cart.json devient le projet « Panier »")
    let ep = try! Projects.create("Épisode 12")
    check(ep == "Épisode 12" && Store.readList(.cart).isEmpty, "nouveau projet actif et vide")
    try? Store.writeList(.cart, [SON])
    check(Projects.load().projects.first { $0.name == "Épisode 12" }?.items.first?.key == SON.key, "le panier écrit dans le projet actif")
    check((try? Projects.create("Épisode 12")) == "Épisode 12 2", "nom de projet rendu unique")
    try? Projects.select(Projects.defaultName)
    check(Store.readList(.cart).map(\.identifier) == ["old1"], "changer de projet change le panier")
    check((try? Projects.rename("Épisode 12 2", to: "Épisode 12")) == "Épisode 12 2", "renommer ne fusionne pas deux projets")
    try? Projects.delete("Épisode 12 2"); try? Projects.delete("Épisode 12")
    try? Projects.delete(Projects.defaultName)
    check(Projects.load().projects.count == 1, "le dernier projet ne se supprime pas")
    let md = Projects.creditsMarkdown(Projects.Project(name: "Ép. 12", items: [SON, ND, FILM]))
    check(md.contains("## Crédits — Ép. 12") && md.contains("[CC BY]") && md.contains("⚠ restrictive") && md.contains("licence non déclarée"),
          "crédits Markdown avec licences et alertes")
}

// ── Freesound : fichiers d'origine (OAuth2), sans réseau ──────────────────
do {
    check(FreesoundAuth.extractCode("https://www.example.org/retour?code=AbC123&state=x") == "AbC123", "code tiré de l'adresse de retour")
    check(FreesoundAuth.extractCode("  AbC123 ") == "AbC123", "code seul")
    check(FreesoundAuth.extractCode("https://www.example.org/retour?error=access_denied") == nil, "refus d'autorisation : pas de code")
    var snd = SON; snd.preview = "https://cdn.freesound.org/previews/4242.mp3"; snd.format = "wav"
    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var before = Downloader.Resolved(request: nil, ext: ""), after = before
    let tok = #"{"access_token":"jeton-test","refresh_token":"r","expires_at":"2099-01-01T00:00:00Z"}"#
    Task {
        FreesoundAuth.signOut()
        before = await Downloader.resolve(snd)
        try? Data(tok.utf8).write(to: TMP.appendingPathComponent("freesound-oauth.json"))
        after = await Downloader.resolve(snd)
        FreesoundAuth.signOut()
        sema.signal()
    }
    sema.wait()
    check(before.isPreview && before.ext == ".mp3" && before.note?.contains("non connecté") == true, "sans compte : aperçu mp3, et le bilan le dit")
    check(!after.isPreview && after.ext == ".wav" && after.request?.url?.absoluteString == "https://freesound.org/apiv2/sounds/4242/download/"
          && after.request?.value(forHTTPHeaderField: "Authorization") == "Bearer jeton-test", "compte connecté : l'original, avec le jeton")
    let decoded = try? JSONDecoder().decode(Item.self, from: JSONEncoder().encode(snd))
    check(decoded?.format == "wav", "format d'origine conservé")
}

// ── Filtres côté source, BPM, clés d'historique ──────────────────────────
do {
    let none = SourceFilters()
    check(none.freesoundFilter == nil && none.archiveClause == nil && none.isEmpty, "sans filtre : rien d'envoyé")
    let f = SourceFilters(minDuration: 5, maxDuration: 30, cc0Only: true, minBPM: 110, maxBPM: nil, decade: 1950)
    check(f.freesoundFilter == "duration:[5.0 TO 30.0] license:\"Creative Commons 0\" bpm:[110 TO *]", "filtre Freesound en syntaxe Solr : \(f.freesoundFilter ?? "nil")")
    check(f.archiveClause == " AND year:[1950 TO 1959]", "décennie archive.org")
    let q = SearchQuery(source: "freesound", text: "rain")
    var qf = q; qf.filters = SourceFilters(cc0Only: true)
    check(History.key(q) == "freesound|rain|||", "clé d'historique inchangée sans filtre (compatible version web)")
    check(History.key(qf) != History.key(q), "un filtre fait une autre recherche")
    History.record(qf, its(["z"])); History.setWatch(History.key(qf), true)
    check(History.watched().first { $0.key == History.key(qf) }?.entry.searchQuery.filters.cc0Only == true, "la veille relance avec ses filtres")
    History.forget(History.key(qf))
    var it = SON; it.bpm = 108.4; it.tonality = "C minor"
    check(it.analysisLabel == "≈ 108 BPM · C minor", "BPM et tonalité marqués comme estimés : \(it.analysisLabel ?? "nil")")
    check(SON.analysisLabel == nil, "pas d'analyse : rien d'affiché")
}

// ── Glisser : un fichier pris part comme URL de fichier ──────────────────
do {
    let f = TMP.appendingPathComponent("drag/son.wav"); touch(f)
    var it = SON; it.identifier = "drag1"
    Journal.note(it, dest: f, size: 1)
    let p = Drag.provider(for: it)
    let types = p.registeredTypeIdentifiers
    check(types == ["com.microsoft.waveform-audio"] && !types.contains("public.url"), "fichier pris : un fichier WAV seulement, pas de lien (.webloc) : \(types)")
    var snd = SON; snd.identifier = "drag2"; snd.preview = "https://cdn.freesound.org/x.mp3"
    let promised = Drag.provider(for: snd).registeredTypeIdentifiers
    check(promised == ["public.mp3"], "son pas encore pris : un mp3 promis, pas de lien : \(promised)")
    let wiki = Item(title: "Phare", creator: "", year: "", type: "media", description: "", url: "https://commons.wikimedia.org/x",
                    thumbnail: "", source: "wikimedia", identifier: "File:Phare.jpg")
    check(Drag.provider(for: wiki).registeredTypeIdentifiers.contains("public.url"), "source sans fichier : le lien de la page")
}

// ── Original Freesound réel : archive-check --original ───────────────────
// Copie les identifiants et jetons du vrai dossier vers le dossier jetable :
// rien n'est écrit dans les vraies données (journal, crédits, paniers).
if CommandLine.arguments.contains("--original") {
    let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Archive Search")
    for f in ["freesound-token", "freesound-client-id", "freesound-oauth.json"] {
        try? fm.copyItem(at: real.appendingPathComponent(f), to: TMP.appendingPathComponent(f))
    }
    let sema = DispatchSemaphore(value: 0)
    Task {
        print("  compte connecté : \(FreesoundAuth.isConnected)")
        do {
            let page = try await Sources.search(SearchQuery(source: "freesound", text: "foghorn"))
            // Un original court : le plus petit à télécharger.
            let short = page.results.filter { ($0.format ?? "mp3") != "mp3" }
                .min { (Int($0.type.filter(\.isNumber)) ?? 999) < (Int($1.type.filter(\.isNumber)) ?? 999) }
            guard let it = short else { check(false, "aucun original non-mp3 dans la recherche"); sema.signal(); return }
            print("  son          « \(it.title) » (\(it.type), format \(it.format ?? "?"))")
            let dir = TMP.appendingPathComponent("original")
            let t0 = Date()
            let p = await Downloader.run([it], into: dir) { _ in }
            for e in p.errors { print("  ⚠ \(e)") }
            for e in p.previews { print("  ⚠ aperçu : \(e)") }
            guard let rel = p.written.first else { check(false, "original non téléchargé"); sema.signal(); return }
            let f = dir.appendingPathComponent(rel)
            let head = (try? FileHandle(forReadingFrom: f).read(upToCount: 4)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
            print(String(format: "  écrit        %@ — %@, en-tête « %@ », %.1f s", rel, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), head, Date().timeIntervalSince(t0)))
            let magic = ["wav": "RIFF", "aiff": "FORM", "aif": "FORM", "flac": "fLaC", "ogg": "OggS"][it.format ?? ""] ?? head
            check(p.previews.isEmpty && f.pathExtension == it.format && head == magic, "original au bon format, pas un aperçu")
            check(fm.fileExists(atPath: dir.appendingPathComponent("CREDITS.txt").path) && Journal.live(it).1.count == 1, "crédits et journal de l'original")
        } catch {
            check(false, "recherche Freesound : \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()
    print(failures == 0 ? "✓ original Freesound vérifié" : "✗ original Freesound : \(failures) échec(s)")
    exit(failures == 0 ? 0 : 1)
}

// ── Mesure de la fouille : archive-check --hunt "thème" ───────────────────
if let i = CommandLine.arguments.firstIndex(of: "--hunt"), i + 1 < CommandLine.arguments.count {
    let theme = CommandLine.arguments[i + 1]
    let sema = DispatchSemaphore(value: 0)
    Task {
        let field = await Hunt.expandField(theme)
        print("champ : \(field.terms.joined(separator: ", "))\n  « \(field.english) » — \(field.note)")
        let t0 = Date()
        let p = await Hunt.run(theme: theme, terms: field.terms, sources: Hunt.defaultSources, queryText: field.english) { _ in }
        print(String(format: "récolte : %d documents en %.0f s · passe 2 : %@", p.harvested, Date().timeIntervalSince(t0), p.pass2.joined(separator: ", ")))
        for y in p.report { print("  \(y.origin == "fonds" ? "↳" : "·") \(y.term): \(y.found) trouvés, \(y.new) neufs") }
        for e in p.errors { print("  ⚠ \(e)") }
        print("classement : \(p.ranking)")
        let docs = p.results.map(\.item)
        func show(_ label: String, _ q: String) {
            guard let qv = Embedder.shared.vector(q) else { print("\(label) : pas de vecteur"); return }
            let rs = docs.map { ($0, Hunt.cos(qv, Embedder.shared.vector(Hunt.docTextPublic($0)) ?? [])) }.sorted { $0.1 > $1.1 }
            let top = rs.first?.1 ?? 0, bottom = rs.last?.1 ?? 0
            let mean = rs.map(\.1).reduce(0, +) / Double(max(1, rs.count))
            print(String(format: "\n%@ — écart haut/bas %.3f (haut %.3f, moyenne %.3f)", label, top - bottom, top, mean))
            for (it, r) in rs.prefix(8) { print(String(format: "   %.3f  %@ [%@]", r, String(it.title.prefix(70)), it.source)) }
            let noise = rs.enumerated().filter { $0.element.0.title.lowercased().contains("spray") || $0.element.0.title.lowercased().contains("spritz") }
            if !noise.isEmpty { print("   vaporisateurs aux rangs : \(noise.map { $0.offset + 1 })") }
        }
        show("requête = champ anglais", field.terms.joined(separator: " "))
        show("requête = thème traduit", field.english)
        show("requête = thème français", theme)
        print("\nclassement final (score) :")
        for r in p.results.prefix(12) {
            print(String(format: "   %5.2f  rel %.3f  %d terme(s)  %@ [%@]", r.score, r.rel ?? -1, r.hits.count, String(r.item.title.prefix(60)), r.item.source))
        }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

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
        // Un vrai petit fichier, de bout en bout : .part, journal, crédits.
        do {
            let (d, _) = try await URLSession.shared.data(from: URL(string: "https://archive.org/advancedsearch.php?q=collection%3Aopensource_audio+AND+item_size%3A%5B100000+TO+600000%5D+AND+format%3AMP3&fl%5B%5D=identifier&fl%5B%5D=title&rows=1&output=json")!)
            let doc = (((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["response"] as? [String: Any])?["docs"] as? [[String: Any]])?.first ?? [:]
            let ident = doc["identifier"] as? String ?? ""
            let it = Item(title: (doc["title"] as? String) ?? ident, creator: "", year: "", type: "audio", description: "",
                          url: "https://archive.org/details/\(ident)", thumbnail: "", source: "archive.org", identifier: ident)
            let dl = TMP.appendingPathComponent("live")
            let p = await Downloader.run([it], into: dl) { _ in }
            let ok = p.errors.isEmpty && p.written.count == 1
            print("  téléchargé   \(ident) → \(p.written.first ?? "rien") \(p.errors.joined(separator: "; "))")
            check(ok && fm.fileExists(atPath: dl.appendingPathComponent("CREDITS.txt").path), "téléchargement réel")
            let parts = (fm.enumerator(atPath: dl.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".part") }
            check(parts.isEmpty, "aucun .part laissé")
        } catch { check(false, "téléchargement réel : \(error)") }
        // Toutes les sources d'un coup : chacune rend compte, Gutenberg n'empêche rien.
        let t0all = Date()
        let (allPage, outs) = await Sources.searchAll("foghorn", useCache: false)
        for o in outs { print(String(format: "  toutes       %@ : %@ (%.1f s)", o.source, o.error ?? "\(o.count) résultats", o.seconds)) }
        print(String(format: "  toutes       %d résultats fusionnés en %.1f s", allPage.results.count, Date().timeIntervalSince(t0all)))
        check(outs.count == Sources.allSources.count && allPage.results.count >= 40, "toutes les sources rendent compte")
        // Glisser un son pas encore pris : le fichier est livré au dépôt.
        do {
            let page = try await Sources.search(SearchQuery(source: "freesound", text: "foghorn"))
            if var it = page.results.first(where: { !($0.preview ?? "").isEmpty }) {
                it.identifier += "-glisser"   // pas « déjà pris »
                let prov = Drag.provider(for: it)
                let t = prov.registeredTypeIdentifiers.first ?? ""
                let got: URL? = await withCheckedContinuation { c in
                    _ = prov.loadFileRepresentation(forTypeIdentifier: t) { url, _ in
                        // L'URL n'est valable que dans le rappel : on la copie.
                        guard let url else { c.resume(returning: nil); return }
                        let keep = TMP.appendingPathComponent("depose-" + url.lastPathComponent)
                        try? fm.copyItem(at: url, to: keep)
                        c.resume(returning: keep)
                    }
                }
                let size = got.flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? nil } ?? 0
                print("  glisser      \(t) → \(got?.lastPathComponent ?? "rien") (\(size) octets)")
                check(size > 1000, "le son glissé arrive comme fichier")
            }
        } catch { check(false, "glisser : \(error.localizedDescription)") }
        // Filtres côté source et sons similaires, en réel.
        do {
            var fq = SearchQuery(source: "freesound", text: "drum loop")
            fq.filters = SourceFilters(minBPM: 118, maxBPM: 122)
            let fp = try await Sources.search(fq, useCache: false)
            let inRange = fp.results.allSatisfy { ($0.bpm ?? 0) >= 118 && ($0.bpm ?? 0) <= 122 }
            print("  filtre BPM   \(fp.results.count) boucles, BPM : \(fp.results.prefix(5).compactMap { $0.bpm.map { Int($0) } })")
            check(!fp.results.isEmpty && inRange, "Freesound filtre lui-même le tempo")
            var cq = SearchQuery(source: "freesound", text: "rain"); cq.filters = SourceFilters(maxDuration: 5, cc0Only: true)
            let cp = try await Sources.search(cq, useCache: false)
            check(!cp.results.isEmpty && cp.results.allSatisfy { $0.license?.code == "CC0" }, "CC0 seulement, filtré par Freesound")
            var aq = SearchQuery(source: "archive.org", text: "civil defense", type: .film); aq.filters = SourceFilters(decade: 1950)
            let ap = try await Sources.search(aq, useCache: false)
            let years = ap.results.compactMap { Int($0.year.prefix(4)) }
            print("  décennie     \(ap.results.count) films, années : \(Set(years).sorted())")
            check(!years.isEmpty && years.allSatisfy { (1950...1959).contains($0) }, "archive.org filtre la décennie")
            let sim = try await Sources.freesoundSimilar("4242")
            print("  similaires   \(sim.count) sons proches de 4242 : \(sim.prefix(3).map(\.title))")
            check(!sim.isEmpty && !sim.contains { $0.identifier == "4242" }, "sons similaires, sans le son lui-même")
        } catch { check(false, "filtres / similaires : \(error.localizedDescription)") }
        // Un item réservé (401) : écarté au premier essai, avec la raison en clair.
        let reserved = Item(title: "Réservé", creator: "", year: "", type: "audio", description: "", url: "",
                            thumbnail: "", source: "archive.org", identifier: "91zii2jfnnmmpcw7gxlt6fs4z9w82uq2sawnt81d")
        let t0 = Date()
        nonisolated(unsafe) var maxAttempt = 0
        let pr = await Downloader.run([reserved], into: TMP.appendingPathComponent("res")) { maxAttempt = max(maxAttempt, $0.attempt) }
        print("  réservé      \(pr.errors.first ?? "?") — \(maxAttempt) essai(s), \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        check(maxAttempt == 1 && pr.errors.first?.contains("réservé") == true, "4xx non retenté")
        sema.signal()
    }
    sema.wait()
}

print(failures == 0 ? "✓ archive-check : \(passed) vérifications" : "✗ archive-check : \(failures) échec(s) sur \(passed + failures)")
exit(failures == 0 ? 0 : 1)
