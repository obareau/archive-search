import Foundation

/// Téléchargement groupé du panier. Un lot à la fois ; c'est l'app qui
/// l'impose (le bouton est désactivé pendant un lot).
public enum Downloader {
    public static let retries = 3

    public static var defaultRoot: URL {
        if let d = ProcessInfo.processInfo.environment["DOWNLOAD_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("archive-search-downloads", isDirectory: true)
    }

    /// Choisir la racine sans sous-dossier range le lot dans `<AAAA-MM-JJ_HHMM>/`.
    public static func batchFolder(chosen: URL) -> URL {
        guard chosen.standardizedFileURL.path == defaultRoot.standardizedFileURL.path else { return chosen }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return chosen.appendingPathComponent(f.string(from: Date()), isDirectory: true)
    }

    // ── Noms ─────────────────────────────────────────────────────────────

    /// Nom de fichier sûr : pas de séparateur, pas de point initial, borné.
    public static func safeName(_ name: String, maxLen: Int = 90) -> String {
        var s = String(name.unicodeScalars.filter { u in
            let ch = Character(u)
            return ch.isLetter || ch.isNumber || ch == "_" || ch.isWhitespace || ".-()[]".contains(ch)
        })
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = String(s.prefix(maxLen)).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "sans-titre" : s
    }

    /// Chemin libre dans `<lot>/<source>/`, suffixé si le titre est déjà pris.
    public static func destPath(_ folder: URL, _ item: Item, ext: String) throws -> URL {
        let sub = folder.appendingPathComponent(safeName(item.source.isEmpty ? "divers" : item.source, maxLen: 40), isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // Beaucoup de titres Freesound finissent par « .wav » : sans ça on
        // écrirait « pluie.wav.mp3 », qui ment sur le format réel.
        let bare = item.title.replacingOccurrences(of: "\\.(wav|aiff?|flac|mp3|ogg|m4a)$", with: "",
                                                   options: [.regularExpression, .caseInsensitive])
        let base = safeName(bare.isEmpty ? "sans-titre" : bare)
        var dest = sub.appendingPathComponent(base + ext)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = sub.appendingPathComponent("\(base) (\(n))\(ext)")
            n += 1
        }
        return dest
    }

    static func ext(of url: URL) -> String {
        let e = url.pathExtension
        return e.isEmpty ? ".bin" : String(("." + e).prefix(8))
    }

    // ── Ce qui est téléchargeable ────────────────────────────────────────

    /// Ce qu'on va chercher pour un item.
    public struct Resolved: Sendable {
        public var request: URLRequest?
        public var ext: String
        /// Refus (pas de fichier), ou remarque (aperçu mp3 au lieu de l'original).
        public var note: String?
        public var isPreview = false
        public init(request: URLRequest?, ext: String, note: String? = nil, isPreview: Bool = false) {
            self.request = request; self.ext = ext; self.note = note; self.isPreview = isPreview
        }
    }

    /// Seules archive.org et Freesound donnent un VRAI fichier ; Gutenberg,
    /// Wikimedia et LibriVox ne renvoient qu'une page.
    public static func resolve(_ item: Item) async -> Resolved {
        switch item.source {
        case "archive.org":
            do {
                let r = try await Sources.resolveArchiveFile(item.identifier)
                guard let u = r.url else { return Resolved(request: nil, ext: "", note: "aucun fichier média trouvé") }
                return Resolved(request: URLRequest(url: u), ext: ext(of: u))
            } catch {
                return Resolved(request: nil, ext: "", note: "résolution impossible (\(error.localizedDescription))")
            }
        case "freesound":
            // L'original exige OAuth2 (compte connecté dans les Réglages) ;
            // sans lui, l'aperçu mp3, et le bilan le dit.
            var why = "compte Freesound non connecté"
            do {
                if let token = try await FreesoundAuth.validAccessToken() {
                    return Resolved(request: FreesoundAuth.originalRequest(soundID: item.identifier, token: token),
                                    ext: "." + (item.format ?? "wav"))
                }
            } catch {
                why = error.localizedDescription
            }
            if let p = item.preview, let u = URL(string: p), !p.isEmpty {
                return Resolved(request: URLRequest(url: u), ext: ".mp3", note: "aperçu mp3 — \(why)", isPreview: true)
            }
            return Resolved(request: nil, ext: "", note: "pas de prévisualisation")
        default:
            return Resolved(request: nil, ext: "", note: "cette source ne renvoie qu'une page web, pas un fichier")
        }
    }

    public static func isDownloadable(_ item: Item) -> Bool {
        item.source == "archive.org" || (item.source == "freesound" && (!(item.preview ?? "").isEmpty || FreesoundAuth.isConnected))
    }

    /// Un fichier déjà pris n'est réutilisé que s'il vaut ce qu'on irait
    /// chercher : un aperçu mp3 pris avant la connexion ne remplace pas l'original.
    static func reusable(_ item: Item, _ file: URL) -> Bool {
        guard item.source == "freesound", FreesoundAuth.isConnected, let f = item.format, f != "mp3" else { return true }
        return file.pathExtension.lowercased() != "mp3"
    }

    // ── Lien à partager : .torrent d'abord (fair-use), sinon fichier, sinon page

    public struct Link: Sendable { public let title: String; public let kind: String; public let url: String }

    public static func shareLink(_ item: Item) async -> Link {
        if item.source == "archive.org" {
            if let t = try? await Sources.resolveArchiveTorrent(item.identifier) {
                return Link(title: item.title, kind: "torrent", url: t.absoluteString)
            }
            if let f = try? await Sources.resolveArchiveFile(item.identifier), let u = f.url {
                return Link(title: item.title, kind: "fichier", url: u.absoluteString)
            }
        }
        if let p = item.preview, !p.isEmpty { return Link(title: item.title, kind: "mp3", url: p) }
        return Link(title: item.title, kind: "page", url: item.url)
    }

    // ── Le lot ───────────────────────────────────────────────────────────

    public struct Progress: Sendable {
        public var done = 0
        public var total = 0
        public var current = ""
        public var bytes: Int64 = 0
        public var bytesTotal: Int64 = 0
        public var attempt = 0
        public var errors: [String] = []
        public var written: [String] = []
        public var reused: [String] = []
        public var creditsFailed = false
        public var cancelled = false
        /// Freesound pris en aperçu mp3 faute d'original, avec la raison.
        public var previews: [String] = []
        public init() {}
    }

    public typealias Report = @Sendable (Progress) -> Void

    public static func run(_ items: [Item], into folder: URL, report: @escaping Report) async -> Progress {
        var p = Progress()
        p.total = items.count
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var credits: [(file: String, block: String)] = []
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"

        func rel(_ u: URL) -> String {
            let path = u.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : u.lastPathComponent
        }

        for item in items {
            if Task.isCancelled { p.cancelled = true; break }
            p.current = item.title; p.attempt = 0; p.bytes = 0; p.bytesTotal = 0
            report(p)

            // Déjà sur le disque : rien au réseau. C'est la DESTINATION qui
            // décide — pas de refus du doublon, le même son sert à deux projets.
            let (prior, live) = Journal.live(item)
            if let prior, live.contains(where: { reusable(item, $0) }) {
                do {
                    let src: URL, note: String
                    if let here = live.first(where: { $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) }) {
                        src = here
                        note = "déjà dans ce dossier (\(prior.at.prefix(10)))"
                    } else {
                        let dest = try destPath(folder, item, ext: live[0].pathExtension.isEmpty ? ".bin" : "." + live[0].pathExtension)
                        try fm.copyItem(at: live[0], to: dest)
                        Journal.note(item, dest: dest, size: fileSize(dest))
                        src = dest
                        note = "copié du lot du \(prior.at.prefix(10)), sans réseau"
                    }
                    credits.append((src.lastPathComponent, Credits.line(item, file: src.lastPathComponent)))
                    p.reused.append("\(item.title) — \(note)")
                    p.written.append(rel(src))
                    p.done += 1
                    report(p)
                    continue
                } catch {
                    // Copie impossible : on retombe sur le téléchargement normal.
                }
            }

            let res = await resolve(item)
            guard let request = res.request else {
                p.errors.append("\(item.title) — \(res.note ?? "?")")
                p.done += 1; report(p)
                continue
            }
            do {
                let dest = try destPath(folder, item, ext: res.ext)
                var last: Error?
                for attempt in 1...retries {
                    p.attempt = attempt; p.bytes = 0; p.bytesTotal = 0; report(p)
                    do {
                        // Le rappel vient du fil d'URLSession : il travaille
                        // sur une copie, jamais sur `p` lui-même.
                        let snapshot = p
                        try await fetch(request, to: dest) { got, total in
                            var q = snapshot
                            q.bytes = got; q.bytesTotal = total
                            report(q)
                        }
                        last = nil
                        break
                    } catch let e as Permanent {
                        // Une page web ou un accès réservé ne sont pas des
                        // pannes passagères : réessayer ne les changera pas.
                        last = e; break
                    } catch {
                        last = error
                        if Task.isCancelled { break }
                        if attempt < retries { try? await Task.sleep(for: .seconds(1 << attempt)) }
                    }
                }
                if let last { throw last }
                Journal.note(item, dest: dest, size: fileSize(dest))
                credits.append((dest.lastPathComponent, Credits.line(item, file: dest.lastPathComponent)))
                p.written.append(rel(dest))
                if res.isPreview, let n = res.note { p.previews.append("\(item.title) — \(n)") }
            } catch {
                if Task.isCancelled {
                    p.cancelled = true
                    p.errors.append("\(item.title) — arrêté en cours, rien d'incomplet n'a été gardé")
                } else {
                    p.errors.append("\(item.title) — \(error.localizedDescription)")
                }
            }
            p.done += 1
            report(p)
        }
        p.creditsFailed = !Credits.write(in: folder, credits)
        p.current = ""
        report(p)
        return p
    }

    static func fileSize(_ u: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Écriture en `.part` renommé à la fin : rien d'incomplet ne porte le nom final.
    static func fetch(_ request: URLRequest, to dest: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        // La progression se lit sur la tâche, à intervalle : l'observation KVO de
        // `task.progress` ne remonte rien pour une tâche de téléchargement async
        // (barre figée à 0 Ko sur 127 Mo, constaté le 2026-11-15).
        let delegate = TaskGrabber()
        let poller = Task {
            while !Task.isCancelled {
                if let t = delegate.task {
                    progress(t.countOfBytesReceived, max(0, t.countOfBytesExpectedToReceive))
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poller.cancel() }
        let (tmp, resp) = try await downloadSession.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let h = resp as? HTTPURLResponse {
            switch h.statusCode {
            case 200..<300: break
            case 401, 403: throw Permanent("accès réservé par la source (HTTP \(h.statusCode))")
            case 404, 410: throw Permanent("fichier introuvable à la source (HTTP \(h.statusCode))")
            case 400..<500: throw Permanent("refusé par la source (HTTP \(h.statusCode))")
            default: throw SourceError("HTTP \(h.statusCode)")   // 5xx : passager, on réessaie
            }
            if (h.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html") {
                throw Permanent("le serveur renvoie une page web, pas un fichier")
            }
        }
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: tmp, to: part)
        try FileManager.default.moveItem(at: part, to: dest)
    }

    static let downloadSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60          // inactivité
        c.timeoutIntervalForResource = 6 * 3600   // un film d'archive.org se compte en Go
        c.httpAdditionalHeaders = ["User-Agent": Config.userAgent]
        return URLSession(configuration: c)
    }()

    /// Erreur qu'un nouvel essai ne changera pas.
    struct Permanent: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// Ne fait que retenir la tâche, pour en lire les octets reçus.
    final class TaskGrabber: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _task: URLSessionTask?
        var task: URLSessionTask? { lock.lock(); defer { lock.unlock() }; return _task }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            lock.lock(); _task = task; lock.unlock()
        }
    }
}
