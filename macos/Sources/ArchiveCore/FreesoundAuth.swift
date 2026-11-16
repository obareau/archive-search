import Foundation

/// Fichiers d'origine Freesound (WAV, FLAC, AIFF…). La clé d'API simple ne
/// donne que l'aperçu mp3 ; l'original exige OAuth2, au nom d'un compte.
///
/// Flux « authorization code » : l'app ouvre la page d'autorisation dans le
/// navigateur, l'usager se connecte CHEZ FREESOUND et autorise l'application ;
/// Freesound renvoie vers l'adresse de retour déclarée avec `?code=…`. On colle
/// ce code (ou l'adresse entière) dans les Réglages ; il vaut 10 minutes et
/// s'échange contre un jeton d'accès (24 h) et un jeton de renouvellement.
/// Aucun mot de passe ne passe par l'app.
public enum FreesoundAuth {
    public struct Tokens: Codable, Sendable {
        public var access_token: String
        public var refresh_token: String
        public var expires_at: Date
        public var scope: String?
    }

    static var tokensFile: URL { Paths.dataDir.appendingPathComponent("freesound-oauth.json") }
    static var clientIDFile: URL { Paths.dataDir.appendingPathComponent("freesound-client-id") }
    static let base = "https://freesound.org/apiv2/oauth2"

    // ── Identifiants de l'application ────────────────────────────────────

    /// L'identifiant client n'est pas secret ; le secret client est la clé
    /// d'API déjà rangée (Freesound les appelle « Client secret/Api key »).
    public static func clientID() -> String {
        if let e = ProcessInfo.processInfo.environment["FREESOUND_CLIENT_ID"], !e.isEmpty { return e }
        return (try? String(contentsOf: clientIDFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    public static func setClientID(_ id: String) throws {
        try FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)
        try Data(id.trimmingCharacters(in: .whitespacesAndNewlines).utf8).write(to: clientIDFile, options: .atomic)
    }

    public static func authorizeURL(state: String) -> URL? {
        let id = clientID()
        guard !id.isEmpty else { return nil }
        return HTTP.url("\(base)/authorize/", [("client_id", id), ("response_type", "code"), ("state", state)])
    }

    /// Accepte le code seul ou l'adresse de retour entière, collée depuis la
    /// barre du navigateur.
    public static func extractCode(_ pasted: String) -> String? {
        let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let c = URLComponents(string: t), let items = c.queryItems, c.scheme != nil {
            return items.first { $0.name == "code" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        return t.contains(" ") || t.contains("/") ? nil : t
    }

    // ── Jetons ───────────────────────────────────────────────────────────

    public static func tokens() -> Tokens? {
        guard let d = try? Data(contentsOf: tokensFile) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Tokens.self, from: d)
    }

    static func save(_ t: Tokens) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)
        try enc.encode(t).write(to: tokensFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokensFile.path)
    }

    public static func signOut() { try? FileManager.default.removeItem(at: tokensFile) }

    public static var isConnected: Bool { tokens() != nil }

    /// Échange le code contre des jetons.
    public static func exchange(code: String) async throws {
        try await tokenRequest([("grant_type", "authorization_code"), ("code", code)])
    }

    /// Un jeton valable, renouvelé s'il expire dans moins de 5 minutes.
    public static func validAccessToken() async throws -> String? {
        guard let t = tokens() else { return nil }
        if t.expires_at.timeIntervalSinceNow > 300 { return t.access_token }
        try await tokenRequest([("grant_type", "refresh_token"), ("refresh_token", t.refresh_token)])
        return tokens()?.access_token
    }

    static func tokenRequest(_ params: [(String, String)]) async throws {
        let id = clientID(), secret = FreesoundToken.read()
        guard !id.isEmpty else { throw SourceError("Identifiant client Freesound manquant (Réglages).") }
        guard !secret.isEmpty else { throw SourceError("Clé d'API Freesound manquante (Réglages) : c'est aussi le secret client.") }
        var req = URLRequest(url: URL(string: "\(base)/access_token/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = ([("client_id", id), ("client_secret", secret)] + params).map { URLQueryItem(name: $0.0, value: $0.1) }
        req.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (d, resp) = try await HTTP.session(20).data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        guard status == 200, let access = j["access_token"] as? String, let refresh = j["refresh_token"] as? String else {
            let why = (j["error_description"] as? String) ?? (j["error"] as? String) ?? (j["detail"] as? String) ?? "HTTP \(status)"
            if params.first?.1 == "refresh_token" { signOut() }
            throw SourceError("Freesound refuse : \(why)" + (params.first?.1 == "authorization_code"
                ? " — un code ne vaut que 10 minutes et ne sert qu'une fois." : " — reconnecter le compte dans les Réglages."))
        }
        let expires = (j["expires_in"] as? NSNumber)?.doubleValue ?? 86400
        try save(Tokens(access_token: access, refresh_token: refresh,
                        expires_at: Date().addingTimeInterval(expires), scope: j["scope"] as? String))
    }

    /// Le fichier d'origine d'un son. La requête porte le jeton ; Freesound
    /// redirige vers son stockage.
    public static func originalRequest(soundID: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://freesound.org/apiv2/sounds/\(soundID)/download/")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }
}
