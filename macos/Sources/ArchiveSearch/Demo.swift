import ArchiveCore
import Foundation

/// Mise en scène au lancement, pour les captures du README — sans simuler une
/// seule frappe ni un seul clic. Inactif sans variable ARCHIVE_DEMO_*.
///
///   ARCHIVE_DEMO_SEARCH="source|requête"   lance une recherche
///   ARCHIVE_DEMO_TYPE="film|audio|pdf"    type de document (archive.org)
///   ARCHIVE_DEMO_SELECT="2" | "movies"     sélectionne le n-ième résultat, ou le premier de ce type
///   ARCHIVE_DEMO_CART="3"                  met les n premiers résultats au panier
///   ARCHIVE_DEMO_PANE="cart|favorites|journal|history"
///   ARCHIVE_DEMO_HUNT="thème"              propose le champ et lance la fouille
///   ARCHIVE_DEMO_HUNT_SHEET="thème"        ouvre la feuille avec le champ proposé, sans lancer
///   ARCHIVE_DEMO_REPORT="12"               ouvre « Voir le rendement » 12 s après la fin de la fouille
///   ARCHIVE_DEMO_DONE="/chemin"            fichier témoin écrit quand la fouille est classée
@MainActor
enum Demo {
    static let env = ProcessInfo.processInfo.environment
    static var active: Bool { env.keys.contains { $0.hasPrefix("ARCHIVE_DEMO_") } }

    static func run(model: SearchModel, hunt: HuntModel, library: LibraryModel, setPane: @escaping (Pane) -> Void) async {
        guard active else { return }
        if let s = env["ARCHIVE_DEMO_SEARCH"] {
            let parts = s.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { model.source = parts[0]; model.text = parts[1] } else { model.text = s }
            if let t = env["ARCHIVE_DEMO_TYPE"].flatMap(SearchType.init(rawValue:)) { model.type = t }
            model.search()
            await waitWhile { model.loading }
            try? await Task.sleep(for: .seconds(2))   // vignettes
            if let n = env["ARCHIVE_DEMO_CART"].flatMap(Int.init) {
                library.add(.cart, Array(model.results.prefix(n)))
            }
            if let sel = env["ARCHIVE_DEMO_SELECT"] {
                let item = Int(sel).flatMap { model.results.indices.contains($0 - 1) ? model.results[$0 - 1] : nil }
                    ?? model.results.first { $0.type == sel }
                model.selection = item?.id
            }
        }
        if let theme = env["ARCHIVE_DEMO_HUNT_SHEET"] ?? env["ARCHIVE_DEMO_HUNT"] {
            hunt.open()
            hunt.theme = theme
            hunt.propose()
            await waitWhile { hunt.proposing }
            if env["ARCHIVE_DEMO_HUNT"] != nil {
                hunt.start(into: model)
                await waitWhile { hunt.running }
                try? await Task.sleep(for: .seconds(2))
                if let done = env["ARCHIVE_DEMO_DONE"] { FileManager.default.createFile(atPath: done, contents: nil) }
                if let delay = env["ARCHIVE_DEMO_REPORT"].flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(delay))
                    hunt.showReport = true
                }
            }
        }
        if let p = env["ARCHIVE_DEMO_PANE"].flatMap(Pane.init(rawValue:)) {
            try? await Task.sleep(for: .milliseconds(300))
            setPane(p)
        }
    }

    private static func waitWhile(_ cond: @MainActor () -> Bool) async {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<1200 where cond() { try? await Task.sleep(for: .milliseconds(250)) }
    }
}
