import ArchiveCore
import SwiftUI

@main
struct ArchiveSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var library = LibraryModel()
    @StateObject private var downloads = DownloadModel()
    @StateObject private var watch = WatchModel()

    init() {
        // Pas de restauration de fenêtres : après un arrêt brutal, macOS
        // relançait l'app SANS fenêtre (processus vivant, rien à l'écran,
        // constaté le 2026-11-15). Rouvrir l'ancienne fenêtre n'apporte rien
        // ici ; une fenêtre neuve à chaque lancement, toujours.
        UserDefaults.standard.register(defaults: [
            "ApplePersistenceIgnoreState": true,
            "NSQuitAlwaysKeepsWindows": false,
        ])
    }

    var body: some Scene {
        WindowGroup("Archive Search") {
            ContentView()
                .environmentObject(library)
                .environmentObject(downloads)
                .environmentObject(watch)
                .onAppear { watch.start(); delegate.watch = watch }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            SearchCommands()
            CommandGroup(after: .newItem) {
                Divider()
                Button("Importer les données de la version web…") { importLegacyData(library: library) }
                Button("Ouvrir le dossier des téléchargements") {
                    let root = Downloader.defaultRoot
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(root)
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var watch: WatchModel?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Lancé hors bundle (swift run), l'app n'aurait ni Dock ni focus clavier.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    /// Avec une veille active, fermer la fenêtre ne quitte pas : la veille
    /// continue, un clic sur l'icône du Dock rouvre la fenêtre. ⌘Q quitte.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        History.watched().isEmpty
    }
}

struct SearchCommands: Commands {
    @FocusedValue(\.searchModel) var model

    var body: some Commands {
        CommandMenu("Recherche") {
            Button("Page précédente") { model?.search(page: (model?.page ?? 2) - 1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled((model?.page ?? 1) <= 1)
            Button("Page suivante") { model?.search(page: (model?.page ?? 0) + 1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.hasMore ?? false))
            Divider()
            Button("Surprise-moi") { model?.surprise() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

struct SettingsView: View {
    @Local private var token = FreesoundToken.read()
    @Local private var saved: String?

    var body: some View {
        Form {
            Section {
                SecureField("Clé d'API Freesound", text: $token)
                HStack {
                    Button("Enregistrer") {
                        do {
                            try FreesoundToken.write(token)
                            Task { await SearchCache.shared.clear() }
                            saved = token.isEmpty ? "Clé retirée." : "Clé enregistrée."
                        } catch {
                            saved = "Échec : \(error.localizedDescription)"
                        }
                    }
                    Link("Créer une clé ↗", destination: URL(string: "https://freesound.org/apiv2/apply/")!)
                    if let saved { Text(saved).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Freesound")
            } footer: {
                Text("Leur API n'a aucun quota anonyme. La clé est rangée dans Application Support (fichier lisible par toi seul), pas dans le dépôt. Elle ne donne que la prévisualisation mp3 : le fichier d'origine exige de connecter un compte, ci-dessous.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            FreesoundOAuthSection()
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
        .padding(.vertical, 8)
    }
}

/// Connexion du compte Freesound (OAuth2), pour les fichiers d'origine.
/// La connexion se fait CHEZ Freesound, dans le navigateur : aucun mot de
/// passe ne passe par l'app.
struct FreesoundOAuthSection: View {
    @Local private var clientID = FreesoundAuth.clientID()
    @Local private var pasted = ""
    @Local private var status: String?
    @Local private var busy = false
    @Local private var connected = FreesoundAuth.tokens()

    var body: some View {
        Section {
            TextField("Identifiant client (Client id)", text: $clientID)
                .onSubmit { try? FreesoundAuth.setClientID(clientID) }
            if let t = connected {
                HStack {
                    Label("Compte connecté — fichiers d'origine", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Déconnecter") { FreesoundAuth.signOut(); connected = nil; status = "Déconnecté : retour aux aperçus mp3." }
                }
                Text("Jeton renouvelé seul ; le courant vaut jusqu'au \(t.expires_at.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("1. Autoriser chez Freesound ↗") {
                        try? FreesoundAuth.setClientID(clientID)
                        if let u = FreesoundAuth.authorizeURL(state: UUID().uuidString) { NSWorkspace.shared.open(u) }
                        else { status = "Renseigner d'abord l'identifiant client." }
                    }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("2. Coller le code, ou l'adresse de retour entière", text: $pasted)
                HStack {
                    Button("3. Valider") { validate() }
                        .disabled(busy || FreesoundAuth.extractCode(pasted) == nil)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Fichiers d'origine (WAV, FLAC, AIFF…)")
        } footer: {
            Text("Après l'autorisation, Freesound renvoie vers l'adresse de retour déclarée pour l'application (sur freesound.org/apiv2/apply), avec « ?code=… » dans l'adresse : copier cette adresse ou le code. Il ne vaut que 10 minutes. Le secret client est la clé d'API ci-dessus.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func validate() {
        guard let code = FreesoundAuth.extractCode(pasted) else { return }
        busy = true; status = nil
        try? FreesoundAuth.setClientID(clientID)
        Task {
            do {
                try await FreesoundAuth.exchange(code: code)
                connected = FreesoundAuth.tokens()
                pasted = ""
                status = "Connecté : les sons Freesound se téléchargent désormais en fichier d'origine."
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
    }
}
