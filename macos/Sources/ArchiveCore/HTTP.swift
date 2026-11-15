import Foundation

public enum Config {
    public static let rowsPerPage = 20
    public static let requestTimeout: TimeInterval = 10
    /// Gutendex répond en 20-30 s quand il est chargé (mesuré le 2026-10-10).
    /// À 10 s on le déclarait mort alors qu'il travaillait. Par source, parce
    /// qu'allonger le délai POUR TOUTES ferait patienter une minute sur une
    /// vraie coupure d'archive.org.
    public static let sourceTimeout: [String: TimeInterval] = ["gutenberg": 30]
    /// Wikimedia rejette les user-agents génériques (403 « Please set a
    /// user-agent ») : identifiant explicite sur tous les appels sortants.
    public static let userAgent = "archive-search/2.0 (macOS; outil personnel, usage local - olivier@robotariis.com)"

    public static func timeout(for source: String) -> TimeInterval {
        sourceTimeout[source] ?? requestTimeout
    }
}

/// Dossiers et secrets. Données de l'app dans Application Support ; la version
/// Flask écrivait dans ~/.local/share/archive-search (repris à l'étape 2).
public enum Paths {
    public static var dataDir: URL {
        if let d = ProcessInfo.processInfo.environment["DATA_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Archive Search", isDirectory: true)
    }
    public static var legacyDataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/archive-search", isDirectory: true)
    }
    static var freesoundTokenFile: URL { dataDir.appendingPathComponent("freesound-token") }
}

/// Clé Freesound. Ni dans le dépôt ni dans le Trousseau : avec une signature
/// ad hoc, chaque build change d'identité et le Trousseau redemanderait le mot
/// de passe de session à chaque lancement. Un fichier en 0600 dans Application
/// Support suffit pour une clé gratuite et révocable. $FREESOUND_TOKEN prime.
public enum FreesoundToken {
    public static func read() -> String {
        if let env = ProcessInfo.processInfo.environment["FREESOUND_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return (try? String(contentsOf: Paths.freesoundTokenFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    public static func write(_ token: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try? fm.removeItem(at: Paths.freesoundTokenFile); return }
        try Data(t.utf8).write(to: Paths.freesoundTokenFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.freesoundTokenFile.path)
    }
}

typealias JSON = [String: Any]

enum HTTP {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [TimeInterval: URLSession] = [:]

    /// Une session par délai : `timeoutIntervalForResource` borne la requête
    /// ENTIÈRE, là où `URLRequest.timeoutInterval` n'est qu'un délai d'inactivité.
    static func session(_ timeout: TimeInterval) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[timeout] { return s }
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.httpAdditionalHeaders = ["User-Agent": Config.userAgent]
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: c)
        sessions[timeout] = s
        return s
    }

    static func url(_ base: String, _ params: [(String, String)]) -> URL {
        var comps = URLComponents(string: base)!
        if !params.isEmpty { comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) } }
        // URLComponents laisse « + » tel quel, que les serveurs lisent comme une espace.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }

    static func get(_ url: URL, source: String) async throws -> (Data, Int) {
        let t = Config.timeout(for: source)
        do {
            let (data, resp) = try await session(t).data(from: url)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as URLError where e.code == .timedOut {
            throw SourceError("\(source) n'a pas répondu en \(Int(t)) s — leur service est lent ou indisponible, réessaie plus tard.")
        } catch let e as URLError where e.code == .notConnectedToInternet {
            throw SourceError("Pas de connexion réseau.")
        } catch let e as URLError {
            throw SourceError("\(source) injoignable : \(e.localizedDescription)")
        }
    }

    static func json(_ url: URL, source: String) async throws -> (JSON, Int) {
        let (data, status) = try await get(url, source: source)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            if status >= 500 {
                throw SourceError("\(source) est en difficulté (HTTP \(status)) — réessaie plus tard.")
            }
            throw SourceError("\(source) a renvoyé une réponse illisible (HTTP \(status), pas du JSON) — service instable.")
        }
        return (obj, status)
    }
}

// Accès tolérants : les APIs renvoient tantôt une liste, tantôt une valeur.
func str(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    case let a as [Any]: return a.first.map { str($0) } ?? ""
    default: return ""
    }
}
func strList(_ v: Any?) -> [String] {
    switch v {
    case let a as [Any]: return a.map { str($0) }.filter { !$0.isEmpty }
    case nil: return []
    default: let s = str(v); return s.isEmpty ? [] : [s]
    }
}
func or(_ s: String, _ d: String) -> String { s.isEmpty ? d : s }
