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
                Text("Leur API n'a aucun quota anonyme. La clé est rangée dans Application Support (fichier lisible par toi seul), pas dans le dépôt. Elle ne donne que la prévisualisation mp3 : le fichier d'origine exige OAuth2.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
